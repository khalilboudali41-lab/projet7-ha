#!/bin/bash
# =============================================================================
# Wrapper de l'entrypoint officiel MariaDB pour un nœud Galera.
#  - génère les fichiers d'authentification à partir de /run/secrets
#    (aucun mot de passe en variable d'environnement ni en ligne de commande) ;
#  - GALERA_BOOTSTRAP=1 : démarre ce nœud en fondateur du cluster
#    (--wsrep-new-cluster). Choisi par scripts/deploy.sh, jamais en dur.
# =============================================================================
set -euo pipefail
umask 027

SST_PW=$(< /run/secrets/db_sst_password)
MON_PW=$(< /run/secrets/db_monitor_password)

# Authentification SST (mariabackup) – lu par mariadbd via !includedir conf.d
cat > /etc/mysql/conf.d/90-sst-auth.cnf <<EOF
[mysqld]
wsrep_sst_auth = mariabackup:${SST_PW}
EOF
chown root:mysql /etc/mysql/conf.d/90-sst-auth.cnf
chmod 0640 /etc/mysql/conf.d/90-sst-auth.cnf

# Identifiants du healthcheck (utilisateur 'monitor', droits USAGE uniquement)
cat > /etc/mysql/healthcheck-auth.cnf <<EOF
[mariadb-client]
user     = monitor
password = ${MON_PW}
protocol = socket
EOF
chmod 0600 /etc/mysql/healthcheck-auth.cnf

if [[ "${GALERA_BOOTSTRAP:-0}" == "1" ]]; then
  echo "[galera-entrypoint] Démarrage en BOOTSTRAP (--wsrep-new-cluster) de ${HOSTNAME}"
  # Le nœud a été désigné par deploy.sh (safe_to_bootstrap ou seqno le plus élevé)
  if [[ -f /var/lib/mysql/grastate.dat ]]; then
    sed -i 's/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat
  fi
  set -- "$@" --wsrep-new-cluster
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
