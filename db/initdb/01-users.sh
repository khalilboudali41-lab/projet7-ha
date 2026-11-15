#!/bin/bash
# =============================================================================
# NE PAS rendre exécutable : l'entrypoint doit le SOURCER (docker_process_sql).
# Exécuté UNE seule fois, à l'initialisation du nœud fondateur (datadir vide),
# par l'entrypoint officiel (sourcé : docker_process_sql est disponible).
# Les nœuds suivants reçoivent ces comptes par SST.
# Principe du moindre privilège : un compte par usage, jamais d'hôte '%'.
#
# Origines autorisées pour les comptes réseau (vitrine, monitor, backup) :
#   172.30.30.%      db_net – version mono-VM (Galera sur le bridge db_net)
#   172.30.50.%      db_uplink – multi-VM, dbproxy/backup → Galera de LEUR VM
#                    (destination = IP de l'hôte : pas de NAT)
#   192.168.89.136   VM1 – multi-VM, dbproxy1/backup → galera2 (NAT vers l'IP de VM1)
#   192.168.89.138   VM2 – multi-VM, dbproxy2 → galera1 (NAT vers l'IP de VM2)
# =============================================================================
APP_PW=$(< /run/secrets/db_app_password)
SST_PW=$(< /run/secrets/db_sst_password)
MON_PW=$(< /run/secrets/db_monitor_password)
BKP_PW=$(< /run/secrets/db_backup_password)
HOSTS=('172.30.30.%' '172.30.50.%' '192.168.89.136' '192.168.89.138')

sql="CREATE DATABASE IF NOT EXISTS vitrine CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;

-- SST mariabackup : local au nœud
CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY '${SST_PW}';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';

-- Supervision (healthcheck Docker) : lecture des statuts seulement
CREATE USER 'monitor'@'localhost' IDENTIFIED BY '${MON_PW}';
GRANT USAGE ON *.* TO 'monitor'@'localhost';
"
for h in "${HOSTS[@]}"; do
  sql+="
-- Origine ${h}
-- Application : DML sur sa seule base (via dbproxy)
CREATE USER 'vitrine'@'${h}' IDENTIFIED BY '${APP_PW}';
GRANT SELECT, INSERT, UPDATE, DELETE ON vitrine.* TO 'vitrine'@'${h}';
-- Supervision (checks dbproxy)
CREATE USER 'monitor'@'${h}' IDENTIFIED BY '${MON_PW}';
GRANT USAGE ON *.* TO 'monitor'@'${h}';
-- Sauvegarde logique (mariadb-dump --single-transaction)
CREATE USER 'backup'@'${h}' IDENTIFIED BY '${BKP_PW}';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS ON *.* TO 'backup'@'${h}';
"
done

docker_process_sql <<<"$sql"
