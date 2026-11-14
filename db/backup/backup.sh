#!/bin/bash
# =============================================================================
# Sauvegarde logique cohérente du cluster Galera
#   usage : backup.sh loop   (service : toutes les BACKUP_INTERVAL_SECONDS)
#           backup.sh once   (sauvegarde immédiate)
# - interroge de préférence un nœud de secours (galera3, galera2) pour ne pas
#   charger l'écrivain ; ne sauvegarde que depuis un nœud Synced/Primary ;
# - mariadb-dump --single-transaction : instantané cohérent sans verrou global ;
# - base applicative + comptes (--system=users, --insert-ignore → restauration
#   idempotente : CREATE USER IF NOT EXISTS) ; gzip + empreinte SHA-256 ;
# - rotation : suppression au-delà de BACKUP_RETENTION_DAYS jours.
# =============================================================================
set -uo pipefail
umask 077   # les dumps contiennent des empreintes de mots de passe
DEST=/backups
NODES=(172.30.30.13 172.30.30.12 172.30.30.11)
export MYSQL_PWD; MYSQL_PWD=$(< /run/secrets/db_backup_password)
CLIENT=(--no-defaults --skip-ssl -u backup --connect-timeout=3)   # client mariadb
DUMP=(--no-defaults --skip-ssl -u backup)                          # mariadb-dump

log() { echo "$(date '+%F %T') [backup] $*"; }

pick_node() {
  local n st
  for n in "${NODES[@]}"; do
    st=$(mariadb "${CLIENT[@]}" -h "$n" -N -B -e \
      "SELECT CONCAT(MAX(IF(VARIABLE_NAME='WSREP_LOCAL_STATE',VARIABLE_VALUE,NULL)),'/',MAX(IF(VARIABLE_NAME='WSREP_CLUSTER_STATUS',VARIABLE_VALUE,NULL))) FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME IN ('WSREP_LOCAL_STATE','WSREP_CLUSTER_STATUS')" 2>/dev/null)
    [[ "$st" == "4/Primary" ]] && { echo "$n"; return 0; }
  done
  return 1
}

backup_once() {
  local node ts f
  node=$(pick_node) || { log "ERREUR : aucun nœud Synced/Primary joignable"; return 1; }
  ts=$(date +%Y%m%d-%H%M%S)
  f="$DEST/vitrine-$ts.sql.gz"
  log "Sauvegarde depuis $node → $(basename "$f")"
  if mariadb-dump "${DUMP[@]}" -h "$node" --single-transaction --routines --triggers --events \
        --insert-ignore --databases vitrine --system=users 2>"$DEST/.last-error" | gzip -6 > "$f.part"; then
    mv "$f.part" "$f"
    (cd "$DEST" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256")
    log "OK : $(du -h "$f" | cut -f1)"
  else
    log "ERREUR : $(cat "$DEST/.last-error")"; rm -f "$f.part"; return 1
  fi
  find "$DEST" -maxdepth 1 -name 'vitrine-*.sql.gz*' -mtime +"${BACKUP_RETENTION_DAYS:-7}" -print -delete \
    | sed 's/^/  rotation : supprimé /'
}

case "${1:-loop}" in
  once) backup_once ;;
  loop)
    log "Service démarré (intervalle ${BACKUP_INTERVAL_SECONDS:-21600}s, rétention ${BACKUP_RETENTION_DAYS:-7}j)"
    sleep 60   # laisse le cluster se stabiliser au démarrage
    while true; do backup_once; sleep "${BACKUP_INTERVAL_SECONDS:-21600}"; done ;;
  *) echo "usage: $0 once|loop"; exit 1 ;;
esac
