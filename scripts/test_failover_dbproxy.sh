#!/usr/bin/env bash
# =============================================================================
# Projet 7 – test de bascule automatique : perte d'un proxy de base de données
#   scripts/test_failover_dbproxy.sh      (FAULT_HOLD=20 PROBE_INTERVAL=0.2 par défaut)
# Sonde HTTPS en boucle sur la VIP → mesure de l'indisponibilité, contrôle du
# compteur, retour à l'état initial vérifié, rapport dans docs/resultats-tests/.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

FT_ID=dbproxy
FT_TITLE="perte d'un proxy de base de données (dbproxy1)"
FT_FAULT="docker kill dbproxy1 (l'alias « db » ne pointe plus que sur dbproxy2)"
FT_MAX_OUTAGE=3
FT_EXPECT_DURING="db=galera1"

ft_fault()  { docker kill dbproxy1 >/dev/null; }
ft_during() {
  check "dbproxy2 sain et écrivain galera1 UP" \
    test "$(container_state dbproxy2)|$(haproxy_srv dbproxy2 galera_writer galera1)" = "running/healthy|UP"
  check "le cluster Galera n'est pas affecté (3 nœuds)" test "$(galera_state galera2)" = "Synced Primary 3"
}
ft_restore() { docker start dbproxy1 >/dev/null; wait_healthy dbproxy1 60; }

ft_run
