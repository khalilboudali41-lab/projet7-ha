#!/usr/bin/env bash
# =============================================================================
# Projet 7 – exploitation des sauvegardes Galera
#   scripts/backup_db.sh now            # sauvegarde immédiate (service db-backup)
#   scripts/backup_db.sh list           # liste + contrôle des empreintes SHA-256
#   scripts/backup_db.sh verify [FICH]  # restauration d'essai dans une instance jetable
#   scripts/backup_db.sh restore FICH   # restauration DANS LE CLUSTER (confirmation demandée)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

latest() { ls -1 backups/vitrine-*.sql.gz 2>/dev/null | tail -1; }

case "${1:-}" in
  now)  docker exec db-backup backup.sh once ;;
  list) ls -lh backups/ ; (cd backups && sha256sum -c ./*.sha256) ;;
  verify)
    f=${2:-$(latest)}; [[ -f "$f" ]] || die "aucune sauvegarde"
    (cd backups && sha256sum -c "$(basename "$f").sha256") || die "empreinte invalide"
    log "Restauration d'essai de $(basename "$f") (instance jetable, sans réseau)"
    docker rm -f p7-restore-test >/dev/null 2>&1 || true
    docker run -d --name p7-restore-test --network none -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
      -v "$P7_ROOT/secrets/db_root_password:/pw:ro" "$GALERA_IMAGE" >/dev/null
    trap 'docker rm -f p7-restore-test >/dev/null 2>&1' EXIT
    for _ in $(seq 1 30); do docker exec p7-restore-test mariadb -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
    zcat "$f" | docker exec -i p7-restore-test mariadb || die "import en échec"
    docker exec p7-restore-test sh -c 'MYSQL_PWD=$(cat /pw) mariadb -uroot -t -e "
      SELECT (SELECT COUNT(*) FROM vitrine.visites) AS visites,
             (SELECT valeur FROM vitrine.compteur WHERE id=1) AS compteur,
             (SELECT COUNT(*) FROM mysql.user WHERE User IN (\"vitrine\",\"monitor\",\"backup\",\"mariabackup\")) AS comptes"'
    ok "Sauvegarde restaurable" ;;
  restore)
    f=${2:?fichier requis}; [[ -f "$f" ]] || die "$f introuvable"
    (cd backups && sha256sum -c "$(basename "$f").sha256") || die "empreinte invalide"
    read -r -p "Restaurer $(basename "$f") dans le cluster (écrase vitrine) ? Taper RESTAURER : " a
    [[ "$a" == RESTAURER ]] || die "annulé"
    # Restauration sur un seul nœud : Galera réplique les instructions aux autres
    zcat "$f" | docker exec -i galera1 sh -c 'MYSQL_PWD=$(cat /run/secrets/db_root_password) mariadb -uroot'
    ok "Restauré via galera1 (répliqué sur le cluster)" ;;
  *) sed -n '3,8p' "$0"; exit 1 ;;
esac
