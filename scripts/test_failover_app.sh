#!/usr/bin/env bash
# =============================================================================
# Projet 7 – test de bascule automatique : perte de 2 serveurs applicatifs sur 3
#   scripts/test_failover_app.sh      (FAULT_HOLD=20 PROBE_INTERVAL=0.2 par défaut)
# Sonde HTTPS en boucle sur la VIP → mesure de l'indisponibilité, contrôle du
# compteur, retour à l'état initial vérifié, rapport dans docs/resultats-tests/.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

FT_ID=app
FT_TITLE="perte de 2 serveurs applicatifs sur 3 (php-fpm)"
FT_FAULT="docker kill app1 app2 (arrêt brutal, SIGKILL)"
FT_MAX_OUTAGE=3
FT_EXPECT_DURING="app=app3"

ft_fault()  { docker kill app1 app2 >/dev/null; }
ft_during() {
  check "app3 toujours sain" container_ok app3
  check "les 3 nginx restent dans le pool HAProxy (panne app ≠ panne web)" \
    test "$(haproxy_srv lb1 be_web web1)$(haproxy_srv lb1 be_web web2)$(haproxy_srv lb1 be_web web3)" = UPUPUP
}
ft_restore() { docker start app1 app2 >/dev/null; wait_healthy app1 60; wait_healthy app2 60; }

ft_run
