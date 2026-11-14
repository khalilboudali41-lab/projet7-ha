#!/usr/bin/env bash
# =============================================================================
# Projet 7 – déploiement (sans sudo)
#
#   scripts/deploy.sh init-env   # crée .env (600) depuis .env.example, mots de passe aléatoires
#   scripts/deploy.sh secrets    # exporte les secrets de .env vers secrets/ (700, SELinux)
#   scripts/deploy.sh db         # tier données : Galera (bootstrap intelligent) + dbproxy + backup
#   scripts/deploy.sh all        # toutes les étapes disponibles
#   scripts/deploy.sh status     # état des conteneurs et du cluster
#   scripts/deploy.sh down       # arrête tout (les volumes/données sont CONSERVÉS)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# -----------------------------------------------------------------------------
init_env() {
  if [[ -f .env ]]; then ok ".env déjà présent (conservé)"; else cp .env.example .env; ok ".env créé"; fi
  chmod 600 .env
  local line k n=0
  # 1. clés apparues dans .env.example depuis la création du .env
  while IFS= read -r line; do
    k=${line%%=*}; grep -q "^${k}=" .env || { echo "$line" >> .env; warn "clé ajoutée : $k"; }
  done < <(grep -E '^[A-Z0-9_]+=' .env.example)
  # 2. mots de passe vides → 32 caractères alphanumériques aléatoires
  while IFS= read -r k; do
    sed -i "s|^${k}=\$|${k}=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)|" .env
    n=$((n+1))
  done < <(grep -E '^[A-Z0-9_]+_(PASSWORD|PASS)=$' .env | cut -d= -f1)
  ok "$n mot(s) de passe généré(s)"
}

# -----------------------------------------------------------------------------
render_secrets() {
  [[ -f .env ]] || die ".env absent : lance 'deploy.sh init-env'"
  [[ "$(stat -c %a .env)" == 600 ]] || { chmod 600 .env; warn ".env remis en 600"; }
  install -d -m 700 secrets
  local map=(db_root_password:DB_ROOT_PASSWORD db_sst_password:DB_SST_PASSWORD
             db_monitor_password:DB_MONITOR_PASSWORD db_app_password:DB_APP_PASSWORD
             db_backup_password:DB_BACKUP_PASSWORD)
  local m f v
  for m in "${map[@]}"; do
    f=${m%%:*}; v=$(grep -E "^${m#*:}=" .env | cut -d= -f2-)
    [[ -n "$v" ]] || die "${m#*:} vide dans .env"
    printf '%s' "$v" > "secrets/$f.tmp" && mv "secrets/$f.tmp" "secrets/$f"
    # 644 : lisible par l'utilisateur non-root du conteneur ; le dossier parent en 700
    # empêche les autres comptes de l'hôte d'y accéder.
    chmod 644 "secrets/$f"
  done
  # SELinux : sans ce label, container_t ne peut pas lire les fichiers (testé : EACCES)
  chcon -R -t container_file_t secrets
  ok "secrets/ à jour (${#map[@]} fichiers, label container_file_t)"
}

# -----------------------------------------------------------------------------
# Lit grastate.dat d'un nœud arrêté → "uuid seqno safe_to_bootstrap" ou "NEW"
grastate() {
  local vol="projet7_$1_data"
  docker volume inspect "$vol" >/dev/null 2>&1 || { echo NEW; return; }
  docker run --rm --network none -v "$vol:/var/lib/mysql:ro" --entrypoint cat "$GALERA_IMAGE" \
    /var/lib/mysql/grastate.dat 2>/dev/null \
    | awk '/^uuid:/{u=$2} /^seqno:/{s=$2} /^safe_to_bootstrap:/{b=$2} END{ if(u=="") print "NEW"; else print u, s, b }'
}

# Position réelle après un arrêt brutal (seqno = -1) : mariadbd --wsrep-recover
wsrep_recover() {
  docker run --rm --network none -v "projet7_$1_data:/var/lib/mysql" \
    -v "$P7_ROOT/db/conf/galera.cnf:/etc/mysql/conf.d/60-projet7-galera.cnf:ro,z" \
    "$GALERA_IMAGE" mariadbd --user=mysql --wsrep-recover 2>&1 \
    | sed -n 's/.*WSREP: Recovered position: *[0-9a-f-]*:\(-\?[0-9]*\).*/\1/p' | tail -1
}

galera_up() {
  local n running=() synced=""
  for n in "${GALERA_NODES[@]}"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" == true ]]; then
      running+=("$n"); [[ "$(galera_state "$n")" == Synced\ Primary* ]] && synced=$n
    fi
  done

  # Cas 1 : un cluster vivant existe → les nœuds manquants le rejoignent (IST/SST)
  if [[ -n "$synced" ]]; then
    ok "Cluster actif (via $synced) : démarrage des nœuds manquants"
    compose up -d "${GALERA_NODES[@]}"
    for n in "${GALERA_NODES[@]}"; do wait_healthy "$n" 300; done
    return
  fi
  [[ ${#running[@]} -eq 0 ]] || die "nœuds lancés mais aucun Synced/Primary (${running[*]}) : intervention manuelle (voir README, reprise Galera)"

  # Cas 2 : cluster entièrement arrêté → choix du nœud fondateur
  local boot="" best=-2 st seq safe
  declare -A state
  for n in "${GALERA_NODES[@]}"; do state[$n]=$(grastate "$n"); log "grastate $n : ${state[$n]}"; done

  if [[ "${state[galera1]}" == NEW && "${state[galera2]}" == NEW && "${state[galera3]}" == NEW ]]; then
    boot=galera1; log "Premier déploiement : galera1 initialise le cluster"
  else
    for n in "${GALERA_NODES[@]}"; do                       # arrêt propre : safe_to_bootstrap: 1
      read -r _ seq safe <<<"${state[$n]}"; [[ "$safe" == 1 ]] && { boot=$n; break; }
    done
    if [[ -z "$boot" ]]; then                                # sinon : seqno le plus élevé
      for n in "${GALERA_NODES[@]}"; do
        [[ "${state[$n]}" == NEW ]] && continue
        read -r _ seq _ <<<"${state[$n]}"
        if [[ "$seq" == -1 ]]; then seq=$(wsrep_recover "$n"); log "wsrep-recover $n → seqno $seq"; fi
        [[ "$seq" =~ ^-?[0-9]+$ ]] && (( seq > best )) && { best=$seq; boot=$n; }
      done
    fi
    [[ -n "$boot" ]] || die "impossible de déterminer le nœud fondateur"
    log "Reprise : $boot est le nœud le plus à jour → bootstrap"
  fi

  local var="${boot^^}_BOOTSTRAP"
  env "$var=1" docker compose up -d "$boot"
  wait_healthy "$boot" 300
  local others=(); for n in "${GALERA_NODES[@]}"; do [[ $n != "$boot" ]] && others+=("$n"); done
  log "Jonction de ${others[*]} (SST/IST depuis $boot)"
  compose up -d "${others[@]}"
  for n in "${others[@]}"; do wait_healthy "$n" 300; done
  # Le fondateur est recréé SANS --wsrep-new-cluster : il redevient un membre ordinaire
  # (un redémarrage ultérieur ne pourra jamais créer un 2e cluster → pas de split-brain)
  log "Redémarrage de $boot en membre ordinaire"
  compose up -d "$boot"
  wait_healthy "$boot" 300
}

deploy_db() {
  render_secrets
  install -d -m 700 backups
  log "Construction de l'image dbproxy"
  compose build -q dbproxy1
  galera_up
  compose up -d dbproxy1 dbproxy2 backup
  wait_healthy dbproxy1 60; wait_healthy dbproxy2 60
  status_db
}

# -----------------------------------------------------------------------------
status_db() {
  log "Cluster Galera"
  local n
  for n in "${GALERA_NODES[@]}"; do printf '    %-8s %s\n' "$n" "$(galera_state "$n")"; done
  log "dbproxy : état des serveurs vus par chaque proxy"
  for n in dbproxy1 dbproxy2; do
    docker exec "$n" sh -c "echo 'show stat' | socat stdio unix-connect:/tmp/admin.sock" 2>/dev/null \
      | awk -F, -v p="$n" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next}
          $1=="galera_writer" && $2!="FRONTEND" && $2!="BACKEND" {
            role=($h["bck"]==1?"secours":"écrivain");
            printf "    %-9s %-8s %-6s %-9s sessions=%s\n", p, $2, $h["status"], role, $h["stot"] }'
  done
}

status() {
  compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
  status_db
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  init-env) init_env ;;
  secrets)  render_secrets ;;
  db)       deploy_db ;;
  all)      init_env; deploy_db ;;
  status)   status ;;
  down)     compose down; ok "Arrêté (volumes conservés : docker volume ls | grep projet7)" ;;
  *)        sed -n '3,12p' "$0"; exit 1 ;;
esac
