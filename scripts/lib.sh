#!/usr/bin/env bash
# Fonctions communes aux scripts du projet 7 (à sourcer)
set -euo pipefail

P7_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P7_ROOT"

# Sessions ouvertes avant l'installation de Docker CE : DOCKER_HOST peut encore
# pointer vers la socket Podman (ancien podman-docker) → on l'ignore.
if [[ "${DOCKER_HOST:-}" == *podman* ]]; then unset DOCKER_HOST; fi

export HOST_UID HOST_GID
HOST_UID=$(id -u); HOST_GID=$(id -g)

GALERA_IMAGE="mariadb:11.4.13-noble"
GALERA_NODES=(galera1 galera2 galera3)

c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'; c_off=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$c_blue" "$(date +%T)" "$c_off" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_yel" "$c_off" "$*"; }
fail() { printf '%s  ✘%s %s\n' "$c_red" "$c_off" "$*"; }
die()  { fail "$*"; exit 1; }

compose() { docker compose "$@"; }

# Attend qu'un conteneur soit « healthy » (timeout en secondes)
wait_healthy() {
  local c=$1 t=${2:-300} s
  for ((i=0; i<t; i+=3)); do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo absent)
    [[ "$s" == healthy ]] && { ok "$c healthy (${i}s)"; return 0; }
    [[ "$s" == exited || "$s" == dead ]] && { docker logs --tail 30 "$c" >&2; die "$c s'est arrêté"; }
    sleep 3
  done
  docker logs --tail 30 "$c" >&2; die "$c pas healthy après ${t}s (état : $s)"
}

# Requête SQL sur un nœud Galera avec le compte de supervision (lecture seule)
galera_q() { docker exec "$1" mariadb --defaults-extra-file=/etc/mysql/healthcheck-auth.cnf -N -B -e "$2"; }

galera_state() {   # → "Synced Primary 3"  (ou "DOWN")
  galera_q "$1" "SELECT GROUP_CONCAT(VARIABLE_VALUE ORDER BY FIELD(VARIABLE_NAME,'WSREP_LOCAL_STATE_COMMENT','WSREP_CLUSTER_STATUS','WSREP_CLUSTER_SIZE') SEPARATOR ' ') FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME IN ('WSREP_LOCAL_STATE_COMMENT','WSREP_CLUSTER_STATUS','WSREP_CLUSTER_SIZE')" 2>/dev/null || echo DOWN
}

# Requête SQL applicative à travers dbproxy (chemin réel de l'application) ;
# APP_SQL_HOST=galeraN pour interroger un nœud précis (compte applicatif, moindre privilège)
app_sql() {
  docker run --rm -i --network projet7_db_net --security-opt no-new-privileges:true --cap-drop ALL \
    -v "$P7_ROOT/secrets/db_app_password:/run/secrets/pw:ro" \
    -e "DBHOST=${APP_SQL_HOST:-db}" \
    --entrypoint bash "$GALERA_IMAGE" -c 'MYSQL_PWD=$(< /run/secrets/pw) exec mariadb --no-defaults --skip-ssl -h "$DBHOST" -u vitrine vitrine -N -B "$@"' _ "$@"
}
