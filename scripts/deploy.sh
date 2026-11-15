#!/usr/bin/env bash
# =============================================================================
# Projet 7 – déploiement (sans sudo)
#
#   scripts/deploy.sh init-env   # crée .env (600) depuis .env.example, mots de passe aléatoires
#   scripts/deploy.sh secrets    # exporte les secrets de .env vers secrets/ (700, SELinux)
#   scripts/deploy.sh db         # tier données : Galera (bootstrap intelligent) + dbproxy + backup
#   scripts/deploy.sh web        # tiers app (php-fpm ×3) + web (nginx ×3)
#   scripts/deploy.sh lb         # journaux centralisés + lb1/lb2 (HAProxy + keepalived, VIP)
#   scripts/deploy.sh dns        # bind9 sur 192.168.89.53 (zone projet7.local)
#   scripts/deploy.sh all        # toutes les étapes disponibles
#   scripts/deploy.sh status     # état des conteneurs et du cluster
#   scripts/deploy.sh down       # arrête tout (les volumes/données sont CONSERVÉS)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib_secrets.sh"

# Topologie multi-VM (branche multi-vm) : ce script mono-VM ne doit plus être lancé.
# Il pourrait refonder les anciens nœuds galera2/galera3 de VM1 en SECOND cluster,
# avec des données périmées. Utiliser scripts/deploy-multi.sh.
if [[ -f "$P7_ROOT/docker-compose.node1.yml" && "${P7_FORCE_MONO:-0}" != 1 ]]; then
  die "topologie multi-VM : utiliser scripts/deploy-multi.sh (P7_FORCE_MONO=1 pour forcer l'ancien mode, en connaissance de cause)"
fi

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
    ok "Cluster actif (via $synced) : mise à jour/démarrage nœud par nœud (quorum préservé)"
    for n in "${GALERA_NODES[@]}"; do compose up -d --no-deps "$n"; wait_healthy "$n" 300; done
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
  ROLL_OPTS=--force-recreate rolling dbproxy1 dbproxy2   # haproxy.cfg monté (cf. deploy_web)
  compose up -d --no-deps backup
  status_db
}

# -----------------------------------------------------------------------------
deploy_web() {
  render_secrets
  log "Construction de l'image applicative"
  compose build -q app1
  rolling app1 app2 app3
  # nginx.conf est monté (bind mount de fichier) : un éditeur qui remplace le fichier
  # (nouvel inode) n'est pas vu par le conteneur → recréation systématique, un par un
  ROLL_OPTS=--force-recreate rolling web1 web2 web3
}

# Mise à jour sans interruption : un conteneur à la fois, en attendant qu'il soit sain
rolling() { local n; for n in "$@"; do compose up -d --no-deps ${ROLL_OPTS:-} "$n"; wait_healthy "$n" 120; done; }

# -----------------------------------------------------------------------------
deploy_lb() {
  render_secrets
  install -d -m 750 logs
  if ! ip -br link show p7-shim >/dev/null 2>&1; then
    warn "interface p7-shim absente : la VM ne pourra pas joindre la VIP (le LAN/Windows, si) – voir docs/phase5-lb.md"
  fi
  log "Construction des images LB et collecteur de journaux"
  compose build -q lb1 logcollector
  compose up -d --no-deps logcollector
  # lb2 d'abord : lb1 (prioritaire) reprend ensuite la VIP après preempt_delay
  rolling lb2 lb1
  sleep 2; status_lb
}

status_lb() {
  log "VRRP / VIP 192.168.89.100"
  local n
  for n in lb1 lb2; do
    if docker exec "$n" ip -4 -o addr show dev lan0 2>/dev/null | grep -q '192.168.89.100/'; then
      printf '    %-4s MASTER (détient la VIP)\n' "$n"
    elif docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null | grep -q true; then
      printf '    %-4s BACKUP\n' "$n"
    else printf '    %-4s arrêté\n' "$n"; fi
  done
  log "Serveurs web vus par chaque LB"
  for n in lb1 lb2; do
    docker exec -u haproxy "$n" sh -c "echo 'show stat' | socat stdio unix-connect:/tmp/admin.sock" 2>/dev/null \
      | awk -F, -v p="$n" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next}
          $1=="be_web" && $2!="FRONTEND" && $2!="BACKEND" { printf "    %-4s %-5s %-6s check=%s\n", p, $2, $h["status"], $h["check_status"] }'
  done
}

# -----------------------------------------------------------------------------
deploy_dns() {
  log "Construction de l'image DNS (contrôle de la zone au build)"
  compose build -q dns
  compose up -d --no-deps dns
  wait_healthy dns 60
  status_dns
}

status_dns() {
  log "DNS 192.168.89.53 (bind9, faisant autorité pour projet7.local)"
  local r
  r=$(docker exec dns dig +short @127.0.0.1 www.projet7.local A 2>/dev/null) \
    && printf '    www.projet7.local → %s\n' "${r:-?}" || printf '    dns arrêté\n'
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
  status_lb
  status_dns
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  init-env) init_env ;;
  secrets)  render_secrets ;;
  db)       deploy_db ;;
  web)      deploy_web ;;
  lb)       deploy_lb ;;
  dns)      deploy_dns ;;
  all)      init_env; deploy_db; deploy_web; deploy_lb; deploy_dns ;;
  status)   status ;;
  down)     compose down; ok "Arrêté (volumes conservés : docker volume ls | grep projet7)" ;;
  *)        sed -n '3,13p' "$0"; exit 1 ;;
esac
