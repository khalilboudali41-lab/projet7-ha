#!/usr/bin/env bash
# =============================================================================
# Projet 7 – test de bascule automatique : perte de 2 serveurs web sur 3
#   scripts/test_failover_web.sh      (FAULT_HOLD=20 PROBE_INTERVAL=0.2 par défaut)
# Sonde HTTPS en boucle sur la VIP → mesure de l'indisponibilité, contrôle du
# compteur, retour à l'état initial vérifié, rapport dans docs/resultats-tests/.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

FT_ID=web
FT_TITLE="perte de 2 serveurs web sur 3 (nginx)"
FT_FAULT="docker kill web1 web2 (arrêt brutal, SIGKILL)"
FT_MAX_OUTAGE=3
FT_EXPECT_DURING="web=web3"

ft_fault()  { docker kill web1 web2 >/dev/null; }
web12_down() { [[ "$(haproxy_srv "$1" be_web web1)|$(haproxy_srv "$1" be_web web2)" == DOWN*\|DOWN* ]]; }
ft_during() {
  local l
  for l in lb1 lb2; do
    wait_until "$l retire web1 et web2 du pool (health check HTTP)" 15 web12_down "$l"
  done
  check "web3 reste UP sur lb1 et lb2" test "$(haproxy_srv lb1 be_web web3)$(haproxy_srv lb2 be_web web3)" = UPUP
}
ft_restore() { docker start web1 web2 >/dev/null; wait_healthy web1 60; wait_healthy web2 60; }

ft_run
