#!/usr/bin/env bash
# =============================================================================
# Projet 7 – test de bascule automatique : perte du load balancer MASTER (VIP)
#   scripts/test_failover_lb.sh      (FAULT_HOLD=20 PROBE_INTERVAL=0.2 par défaut)
# Sonde HTTPS en boucle sur la VIP → mesure de l'indisponibilité, contrôle du
# compteur, retour à l'état initial vérifié, rapport dans docs/resultats-tests/.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

FT_ID=lb
FT_TITLE="perte du load balancer MASTER (lb1, VIP)"
FT_FAULT="docker kill lb1 (HAProxy + keepalived du MASTER tués, sans libération propre de la VIP)"
FT_MAX_OUTAGE=5
FT_EXPECT_DURING="lb=lb2"
FT_EXPECT_AFTER="lb=lb1"

ft_fault()  { docker kill lb1 >/dev/null; }
vip_on() { [[ "$(vip_holder)" == "$1" ]]; }
ft_during() {
  wait_until "lb2 devient MASTER et porte la VIP (VRRP, advert 1 s)" 10 vip_on lb2
}
ft_restore() {
  docker start lb1 >/dev/null; wait_healthy lb1 60
  wait_until "lb1 reprend la VIP (préemption après preempt_delay 10 s)" 40 vip_on lb1
}

ft_run
