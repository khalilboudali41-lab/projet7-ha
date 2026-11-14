-- =============================================================================
-- Schéma de l'application « vitrine HA »
-- (clés primaires obligatoires : innodb_force_primary_key / Galera)
-- =============================================================================
USE vitrine;

-- Compteur global de visites (une seule ligne, incrément atomique)
CREATE TABLE IF NOT EXISTS compteur (
  id      TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  valeur  BIGINT UNSIGNED  NOT NULL DEFAULT 0
) ENGINE=InnoDB;
INSERT IGNORE INTO compteur (id, valeur) VALUES (1, 0);

-- Journal des visites : qui a servi la requête (preuve de répartition / bascule)
CREATE TABLE IF NOT EXISTS visites (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  horodatage DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  web        VARCHAR(64)     NOT NULL,
  app        VARCHAR(64)     NOT NULL,
  db_node    VARCHAR(64)     NOT NULL,
  KEY idx_horodatage (horodatage)
) ENGINE=InnoDB;

-- Table utilisée par les tests de bascule DB (intégrité des écritures)
CREATE TABLE IF NOT EXISTS test_failover (
  id       BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  run_id   VARCHAR(32)     NOT NULL,
  ecrit_le DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_run (run_id)
) ENGINE=InnoDB;
