#!/usr/bin/env bash
# =============================================================================
# Projet 7 – déploiement MULTI-VM (sans sudo), lancé depuis VM1 (novyra-agent)
#   VM1 192.168.89.136 : docker-compose.node1.yml (galera1, lb1 MASTER…)
#   VM2 192.168.89.138 : docker-compose.node2.yml (galera2, lb2 BACKUP…), par SSH
#   VM3 192.168.89.137 : garbd (systemd, installé par scripts/p3_garbd_vm3.sh)
#
#   scripts/deploy-multi.sh sync              # code (git, avance rapide) + secrets (scp) → VM2
#   scripts/deploy-multi.sh build             # images sur VM1 et VM2
#   scripts/deploy-multi.sh galera [--bootstrap galeraN]
#                                             # démarrage/mise à jour sûrs du cluster Galera
#   scripts/deploy-multi.sh services          # dbproxy, app, web, dns, lb (un à un, VM2 puis VM1)
#   scripts/deploy-multi.sh up [--bootstrap galeraN]   # sync + build + galera + services
#   scripts/deploy-multi.sh status            # état des 3 VMs, du cluster, de la VIP
#   scripts/deploy-multi.sh down              # arrêt ordonné (galera1 en DERNIER), volumes conservés
#
# Options : --force-recreate (services : recrée même sans changement de config,
#           utile après modification d'un fichier monté : nginx-multi.conf…)
# Galera n'est JAMAIS fondé automatiquement en cas de doute (voir
# docs/reprise-cluster-galera.md) : le script s'arrête et demande --bootstrap.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib_secrets.sh"

VM1_IP=${VM1_IP:-192.168.89.136}
VM2_IP=${VM2_IP:-192.168.89.138}
VM3_IP=${VM3_IP:-192.168.89.137}
SSH_USER=${SSH_USER:-dr-khalil}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519_nodes}
REMOTE_DIR=${REMOTE_DIR:-projet7-ha}          # relatif au $HOME distant
BRANCH=multi-vm
VIP=192.168.89.100
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_KEY")

# --- Exécution locale / distante ------------------------------------------------
node_ip()   { [[ $1 == node1 ]] && echo "$VM1_IP" || echo "$VM2_IP"; }
galera_of() { [[ $1 == node1 ]] && echo galera1 || echo galera2; }
node_of()   { [[ $1 == galera1 ]] && echo node1 || echo node2; }

# on <node1|node2|vm3> <commande shell> : exécutée dans le dépôt (VM1/VM2) ou dans ~ (VM3)
on() {
  local n=$1; shift
  case $n in
    node1) bash -c "cd '$P7_ROOT' && $*" ;;
    node2) ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM2_IP" "cd ~/$REMOTE_DIR && $*" ;;
    vm3)   ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM3_IP" "$*" ;;
  esac
}
# dc <node> <args compose> : docker compose avec le fichier du rôle
dc() { local n=$1; shift; on "$n" "HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose -f docker-compose.$n.yml $*"; }

state_of()  { on "$1" "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $2 2>/dev/null || echo absent"; }

# wait_on <node> <conteneur> [timeout s] : attend « healthy » (ou running sans healthcheck)
wait_on() {
  local n=$1 c=$2 t=${3:-300} s i
  for ((i=0; i<t; i+=3)); do
    s=$(state_of "$n" "$c")
    [[ $s == healthy ]] && { ok "$c ($n) healthy (${i}s)"; return 0; }
    [[ $s == running && -z "$(on "$n" "docker inspect -f '{{.State.Health}}' $c" | grep -v '<nil>')" ]] && { ok "$c ($n) running (${i}s)"; return 0; }
    [[ $s == exited || $s == dead ]] && { on "$n" "docker logs --tail 30 $c" >&2; die "$c ($n) s'est arrêté"; }
    sleep 3
  done
  on "$n" "docker logs --tail 30 $c" >&2; die "$c ($n) pas healthy après ${t}s (état : $s)"
}

# État wsrep d'un nœud lancé → "Synced Primary 3" ou DOWN
gstate() {
  on "$(node_of "$1")" "docker exec $1 mariadb --defaults-extra-file=/etc/mysql/healthcheck-auth.cnf -N -B -e \"SELECT GROUP_CONCAT(VARIABLE_VALUE ORDER BY FIELD(VARIABLE_NAME,'WSREP_LOCAL_STATE_COMMENT','WSREP_CLUSTER_STATUS','WSREP_CLUSTER_SIZE') SEPARATOR ' ') FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME IN ('WSREP_LOCAL_STATE_COMMENT','WSREP_CLUSTER_STATUS','WSREP_CLUSTER_SIZE')\"" 2>/dev/null || echo DOWN
}

# =============================================================================
# sync : code (git) et secrets vers VM2
# =============================================================================
sync_vm2() {
  [[ "$(git -C "$P7_ROOT" rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "VM1 n'est pas sur la branche $BRANCH"
  [[ -z "$(git -C "$P7_ROOT" status --porcelain)" ]] \
    || die "modifications non commitées sur VM1 : VM2 reçoit le code par git (commiter d'abord)"
  log "Code → VM2 (git, avance rapide uniquement)"
  [[ "$(on node2 "git rev-parse --abbrev-ref HEAD")" == "$BRANCH" ]] || die "VM2 n'est pas sur la branche $BRANCH"
  [[ -z "$(on node2 "git status --porcelain")" ]] || die "modifications locales sur VM2 : à examiner avant toute synchronisation"
  GIT_SSH_COMMAND="ssh ${SSH_OPTS[*]}" git -C "$P7_ROOT" push -q \
    "ssh://$SSH_USER@$VM2_IP/home/$SSH_USER/$REMOTE_DIR" "$BRANCH:refs/remotes/vm1/$BRANCH"
  on node2 "git merge -q --ff-only vm1/$BRANCH" || die "VM2 a divergé de VM1 (avance rapide impossible)"
  ok "VM2 à $(on node2 "git log --oneline -1")"

  log "Secrets → VM2 (scp, jamais par git)"
  render_secrets
  local R="$SSH_USER@$VM2_IP:$REMOTE_DIR" pk=pki/server/www.projet7.local/private
  on node2 "install -d -m 700 secrets $pk"
  scp -q -p "${SSH_OPTS[@]}" .env "$R/.env"
  scp -q -p "${SSH_OPTS[@]}" secrets/* "$R/secrets/"
  scp -q -p "${SSH_OPTS[@]}" "$pk"/* "$R/$pk/"
  on node2 "chmod 600 .env && chmod 700 secrets $pk && chcon -R -t container_file_t secrets"
  local f='.env secrets/* pki/server/www.projet7.local/private/*' a b
  a=$(on node1 "sha256sum $f | sha256sum | cut -c1-16"); b=$(on node2 "sha256sum $f | sha256sum | cut -c1-16")
  [[ "$a" == "$b" ]] || die "secrets différents entre VM1 et VM2 après copie ($a / $b)"
  ok "Secrets identiques sur VM1 et VM2 (empreinte $a)"
}

# =============================================================================
# build
# =============================================================================
build_all() {
  local n
  for n in node1 node2; do
    log "Images ($n)"
    dc "$n" "build -q" 2>&1 | grep -vE '^\s*(Image .* (Building|Built))?\s*$' || true
    ok "Images à jour ($n)"
  done
}

# =============================================================================
# galera : démarrage / mise à jour sûrs
# =============================================================================
# grastate d'un nœud arrêté → "uuid seqno safe" ou NEW (volume absent ou vide)
grastate_of() {
  local g=$1 n; n=$(node_of "$1")
  on "$n" "docker volume inspect projet7_${g}_data >/dev/null 2>&1 || { echo NEW; exit 0; }; \
    docker run --rm --network none -v projet7_${g}_data:/var/lib/mysql:ro --entrypoint cat $GALERA_IMAGE \
      /var/lib/mysql/grastate.dat 2>/dev/null \
    | awk '/^uuid:/{u=\$2} /^seqno:/{s=\$2} /^safe_to_bootstrap:/{b=\$2} END{ if(u==\"\") print \"NEW\"; else print u, s, b }'"
}

# Position réelle après arrêt brutal (seqno -1) → "uuid:seqno"
recover_of() {
  local g=$1 n; n=$(node_of "$1")
  on "$n" "docker run --rm --network none -v projet7_${g}_data:/var/lib/mysql \
    -v \$PWD/db/conf/galera.cnf:/etc/mysql/conf.d/60-projet7-galera.cnf:ro,z \
    $GALERA_IMAGE mariadbd --user=mysql --wsrep-recover 2>&1 \
    | sed -n 's/.*WSREP: Recovered position: *\([0-9a-f-]*:-\?[0-9]*\).*/\1/p' | tail -1"
}

# Copie à froid d'un volume, sur sa VM (avant toute écriture de reprise)
cold_copy() {
  local g=$1 n ts; n=$(node_of "$1"); ts=$(date +%Y%m%d-%H%M%S)
  on "$n" "install -d -m 700 backups && docker run --rm --network none -v projet7_${g}_data:/src:ro alpine:3.24.4 \
    tar czf - -C /src . > backups/${g}-vol-avant-bootstrap-$ts.tgz && chmod 600 backups/${g}-vol-avant-bootstrap-$ts.tgz"
  ok "Copie à froid : $n:backups/${g}-vol-avant-bootstrap-$ts.tgz"
}

garbd_check() {
  local s; s=$(on vm3 "systemctl is-active garb" 2>/dev/null || true)
  if [[ $s == active ]]; then ok "garbd (VM3) actif"
  else warn "garbd (VM3) : ${s:-injoignable} – quorum à 2 nœuds seulement. Sur VM3 : sudo systemctl restart garb (ou sudo bash ~/p3_garbd_vm3.sh)"; fi
}

start_member() {   # nœud ordinaire (jamais --wsrep-new-cluster)
  local g=$1 n; n=$(node_of "$g")
  dc "$n" "up -d --no-deps $g" | grep -E 'Recreate|Started|Running' || true
  wait_on "$n" "$g" 300
}

galera_up() {
  local forced=${1:-} g running=() synced=""
  garbd_check
  for g in galera1 galera2; do
    if [[ "$(on "$(node_of $g)" "docker inspect -f '{{.State.Running}}' $g 2>/dev/null")" == true ]]; then
      running+=("$g"); [[ "$(gstate $g)" == "Synced Primary"* ]] && synced=$g
    fi
  done

  # --- Cas 1 : cluster vivant → les autres le (re)joignent un par un --------------
  if [[ -n "$synced" ]]; then
    [[ -z "$forced" ]] || die "--bootstrap refusé : le cluster est vivant (via $synced)"
    ok "Cluster actif (via $synced) : mise à jour nœud par nœud, quorum préservé"
    for g in galera1 galera2; do
      [[ $g == "$synced" ]] && continue
      start_member "$g"
    done
    start_member "$synced"     # recréé seulement si sa configuration a changé
    return
  fi
  [[ ${#running[@]} -eq 0 ]] || die "nœud(s) lancé(s) mais aucun Synced/Primary (${running[*]}) : intervention manuelle (docs/reprise-cluster-galera.md)"

  # --- Cas 2 : cluster entièrement arrêté → choix du fondateur ---------------------
  declare -A st pos
  local boot="" u1 s1 b1 u2 s2 b2 z=00000000-0000-0000-0000-000000000000
  for g in galera1 galera2; do st[$g]=$(grastate_of $g); log "grastate $g : ${st[$g]}"; done
  # Copie à froid AVANT toute écriture (wsrep-recover ouvre InnoDB, le bootstrap écrit)
  for g in galera1 galera2; do [[ "${st[$g]}" == NEW ]] || cold_copy "$g"; done

  if [[ "${st[galera1]}" == NEW && "${st[galera2]}" == NEW ]]; then
    boot=galera1; log "Premier déploiement : galera1 fonde le cluster (initdb)"
  elif [[ -n "$forced" ]]; then
    [[ $forced == galera1 || $forced == galera2 ]] || die "--bootstrap galera1|galera2"
    [[ "${st[$forced]}" != NEW ]] || die "--bootstrap $forced : son volume est vide"
    boot=$forced; warn "Fondateur imposé par l'opérateur : $boot"
  else
    for g in galera1 galera2; do
      [[ "${st[$g]}" == NEW ]] && continue
      read -r _ _ b1 <<<"${st[$g]}"
      [[ "$b1" == 1 ]] && { boot=$g; log "$g : safe_to_bootstrap 1 (dernier nœud arrêté proprement)"; break; }
    done
    if [[ -z "$boot" ]]; then
      for g in galera1 galera2; do
        [[ "${st[$g]}" == NEW ]] && { pos[$g]=NEW; continue; }
        read -r u1 s1 _ <<<"${st[$g]}"
        if [[ "$s1" == -1 ]]; then pos[$g]=$(recover_of $g); log "wsrep-recover $g → ${pos[$g]}"
        else pos[$g]="$u1:$s1"; fi
      done
      # Un seul nœud a des données → c'est lui
      if   [[ "${pos[galera1]}" == NEW ]]; then boot=galera2
      elif [[ "${pos[galera2]}" == NEW ]]; then boot=galera1
      else
        u1=${pos[galera1]%:*}; s1=${pos[galera1]##*:}; u2=${pos[galera2]%:*}; s2=${pos[galera2]##*:}
        if [[ -z "$u1" || -z "$u2" || "$u1" == "$z" || "$u2" == "$z" || "$u1" != "$u2" \
              || ! "$s1" =~ ^[0-9]+$ || ! "$s2" =~ ^[0-9]+$ ]]; then
          fail "Choix du fondateur AMBIGU : galera1=${pos[galera1]} galera2=${pos[galera2]}"
          echo "    (UUID nul ou différents, ou position inconnue). Comparer les données (docs/reprise-cluster-galera.md §6)"
          echo "    puis relancer : scripts/deploy-multi.sh galera --bootstrap galera1|galera2"
          exit 1
        fi
        if   (( s1 > s2 )); then boot=galera1
        elif (( s2 > s1 )); then boot=galera2
        else boot=galera1; log "Positions identiques ($u1:$s1) : même historique, galera1 retenu"; fi
      fi
    fi
    log "Fondateur : $boot"
  fi

  local bn other; bn=$(node_of "$boot"); [[ $boot == galera1 ]] && other=galera2 || other=galera1
  log "Bootstrap de $boot ($bn)"
  # JAMAIS de démarrage en membre ordinaire ici : sans cluster, le nœud bouclerait
  # et réécrirait grastate.dat (incident du 15/11). --force-recreate crée si absent.
  on "$bn" "GALERA_BOOTSTRAP=1 HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose -f docker-compose.$bn.yml up -d --no-deps --force-recreate $boot" | grep -E 'Recreate|Started' || true
  wait_on "$bn" "$boot" 300
  log "Jonction de $other (SST/IST depuis $boot)"
  start_member "$other"
  # Le fondateur est recréé SANS --wsrep-new-cluster : un redémarrage ultérieur ne
  # pourra jamais fonder un 2e cluster
  log "Redémarrage de $boot en membre ordinaire"
  on "$bn" "HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose -f docker-compose.$bn.yml up -d --no-deps --force-recreate $boot" | grep -E 'Recreate|Started' || true
  wait_on "$bn" "$boot" 300
}

# =============================================================================
# services : un conteneur à la fois, VM2 puis VM1 (lb1 reprend la VIP en dernier)
# =============================================================================
services_up() {
  local opt=${FORCE:+--force-recreate} n c
  for n in node2 node1; do
    log "Services ($n)"
    dc "$n" "up -d --no-deps logcollector" >/dev/null 2>&1; wait_on "$n" logcollector 60
    local list=(dbproxy app web dns lb); local i=${n#node}
    [[ $n == node1 ]] && list=(dbproxy backup app web dns lb)
    for c in "${list[@]}"; do
      local name="$c$i"; [[ $c == backup ]] && name=backup
      dc "$n" "up -d --no-deps $opt $name" | grep -E 'Recreate|Started' || true
      [[ $c == backup ]] && c=db-backup || c=$name
      wait_on "$n" "$c" 180
    done
  done
}

# =============================================================================
# status
# =============================================================================
status_all() {
  local n g c
  for n in node1 node2; do
    log "Conteneurs ($n – $(node_ip $n))"
    { on "$n" "docker ps -a --filter label=com.docker.compose.project=projet7 --format '{{.Names}}|{{.Status}}'" || echo "(injoignable)"; } \
      | sort | awk -F'|' '{printf "    %-13s %s\n", $1, $2}'
  done
  log "Galera"
  for g in galera1 galera2; do printf '    %-8s %s\n' "$g" "$(gstate $g)"; done
  printf '    %-8s %s\n' garbd "$(on vm3 'systemctl is-active garb' 2>/dev/null || echo injoignable)"
  # (taille 3 = galera1 + galera2 + garbd ; le compte monitor ne lit pas mysql.wsrep_cluster_members)
  log "VIP $VIP"
  for n in node1 node2; do
    c=lb${n#node}
    if on "$n" "docker exec $c ip -4 -o addr show dev lan0" 2>/dev/null | grep -q " $VIP/"; then
      printf '    %-4s (%s) MASTER – détient la VIP\n' "$c" "$n"
    else printf '    %-4s (%s) %s\n' "$c" "$n" "$(state_of $n $c | sed 's/healthy/BACKUP/')"; fi
  done
  log "LB : serveurs web / dbproxy : nœuds Galera"
  for n in node1 node2; do
    on "$n" "docker exec -u haproxy lb${n#node} sh -c \"echo 'show stat' | socat stdio unix-connect:/tmp/admin.sock\"" 2>/dev/null \
      | awk -F, -v p="lb${n#node}" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1=="be_web" && $2!="BACKEND"{printf "    %-9s %-9s %-5s %s\n", p, $2, $h["status"], ($h["bck"]==1?"(secours, autre VM)":"(local)")}' \
      || echo "    lb${n#node} : injoignable"
    on "$n" "docker exec dbproxy${n#node} sh -c \"echo 'show stat' | socat stdio unix-connect:/tmp/admin.sock\"" 2>/dev/null \
      | awk -F, -v p="dbproxy${n#node}" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1=="galera_writer" && $2!="FRONTEND" && $2!="BACKEND"{printf "    %-9s %-9s %-5s %s\n", p, $2, $h["status"], ($h["bck"]==1?"secours":"écrivain")}' \
      || echo "    dbproxy${n#node} : injoignable"
  done
}

# =============================================================================
# down : arrêt ordonné, galera1 en dernier (safe_to_bootstrap 1 → reprise simple)
# =============================================================================
down_all() {
  warn "Arrêt complet : la page sera indisponible ; volumes conservés"
  dc node2 "stop lb2 dns2 web2 app2 dbproxy2" >/dev/null 2>&1 || true
  dc node1 "stop lb1 dns1 web1 app1 backup dbproxy1" >/dev/null 2>&1 || true
  log "Arrêt de galera2 puis galera1 (le dernier arrêté pourra fonder le cluster)"
  dc node2 "stop galera2" >/dev/null; dc node1 "stop galera1" >/dev/null
  log "grastate galera1 : $(grastate_of galera1) / galera2 : $(grastate_of galera2)"
  ok "Arrêté. Reprise : scripts/deploy-multi.sh up (garbd reste actif sur VM3 et se reconnectera)"
}

# =============================================================================
main() {
  # Garde-fou : uniquement depuis VM1
  ip -4 -o addr show dev ens160 2>/dev/null | grep -q " $VM1_IP/" \
    || die "deploy-multi.sh se lance depuis VM1 ($VM1_IP)"
  local cmd=${1:-}; shift || true
  BOOT=""; FORCE=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --bootstrap) BOOT=${2:?--bootstrap galera1|galera2}; shift 2 ;;
      --force-recreate) FORCE=1; shift ;;
      *) die "option inconnue : $1" ;;
    esac
  done
  case "$cmd" in
    sync)     sync_vm2 ;;
    build)    build_all ;;
    galera)   galera_up "$BOOT" ;;
    services) services_up ;;
    up)       sync_vm2; build_all; galera_up "$BOOT"; services_up; status_all ;;
    status)   status_all ;;
    down)     down_all ;;
    *)        sed -n '3,21p' "$0"; exit 1 ;;
  esac
}

# Exécuté directement → main ; sourcé (tests) → fonctions seulement
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
