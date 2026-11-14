#!/bin/bash
# =============================================================================
# NE PAS rendre exécutable : l'entrypoint doit le SOURCER (docker_process_sql).
# Exécuté UNE seule fois, à l'initialisation du nœud fondateur (datadir vide),
# par l'entrypoint officiel (sourcé : docker_process_sql est disponible).
# Les nœuds suivants reçoivent ces comptes par SST.
# Principe du moindre privilège : un compte par usage.
# =============================================================================
APP_PW=$(< /run/secrets/db_app_password)
SST_PW=$(< /run/secrets/db_sst_password)
MON_PW=$(< /run/secrets/db_monitor_password)
BKP_PW=$(< /run/secrets/db_backup_password)
DB_NET='172.30.30.%'   # réseau db_net (dbproxy, backup) – jamais '%'

docker_process_sql <<SQL
CREATE DATABASE IF NOT EXISTS vitrine CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;

-- Application : DML sur sa seule base, uniquement depuis db_net (via dbproxy)
CREATE USER 'vitrine'@'${DB_NET}' IDENTIFIED BY '${APP_PW}';
GRANT SELECT, INSERT, UPDATE, DELETE ON vitrine.* TO 'vitrine'@'${DB_NET}';

-- SST mariabackup : local au nœud
CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY '${SST_PW}';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';

-- Supervision (healthcheck Docker + checks dbproxy) : lecture des statuts seulement
CREATE USER 'monitor'@'localhost'  IDENTIFIED BY '${MON_PW}';
CREATE USER 'monitor'@'${DB_NET}'  IDENTIFIED BY '${MON_PW}';
GRANT USAGE ON *.* TO 'monitor'@'localhost', 'monitor'@'${DB_NET}';

-- Sauvegarde logique (mariadb-dump --single-transaction)
CREATE USER 'backup'@'${DB_NET}' IDENTIFIED BY '${BKP_PW}';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS ON *.* TO 'backup'@'${DB_NET}';
SQL
