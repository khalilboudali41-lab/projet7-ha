#!/usr/bin/env bash
# =============================================================================
# Projet 7 – contrôle de l'état NOMINAL de toute la plateforme (sans sudo)
#
#   scripts/healthcheck.sh        # rapport détaillé, code retour 0 si tout est nominal
#   scripts/healthcheck.sh -q     # silencieux (utilisé avant/après chaque test de bascule)
#
# État nominal : 16 conteneurs actifs et sains · Galera 3 nœuds Synced/Primary ·
# écrivain galera1 vu UP par dbproxy1/2 · 3 web UP sur lb1 et lb2 · VIP sur lb1 ·
# DNS → VIP · requête HTTPS de bout en bout (certificat validé) via la VIP.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

QUIET=0; [[ "${1:-}" == -q ]] && QUIET=1
errors=0
chk() {   # chk "description" commande…
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then (( QUIET )) || ok "$d"
  else (( QUIET )) || fail "$d"; errors=$((errors+1)); fi
}
section() { (( QUIET )) || log "$*"; }

section "Conteneurs"
for c in "${ALL_CONTAINERS[@]}"; do chk "$c : $(container_state "$c")" container_ok "$c"; done

section "Données"
for n in "${GALERA_NODES[@]}"; do chk "$n : $(galera_state "$n")" test "$(galera_state "$n")" = "Synced Primary 3"; done
for p in dbproxy1 dbproxy2; do
  chk "$p : écrivain galera1 UP, secours galera2/3 UP" \
    test "$(haproxy_srv "$p" galera_writer galera1)$(haproxy_srv "$p" galera_writer galera2)$(haproxy_srv "$p" galera_writer galera3)" = UPUPUP
done

section "Load balancers"
chk "VIP 192.168.89.100 portée par lb1 (prioritaire)" test "$(vip_holder)" = lb1
for l in lb1 lb2; do
  chk "$l : web1/web2/web3 UP" \
    test "$(haproxy_srv "$l" be_web web1)$(haproxy_srv "$l" be_web web2)$(haproxy_srv "$l" be_web web3)" = UPUPUP
done

section "DNS et bout en bout"
chk "dns : www.projet7.local → 192.168.89.100" test "$(docker exec dns dig +short +time=2 @127.0.0.1 www.projet7.local A)" = 192.168.89.100
e2e=$(probe_once)
chk "HTTPS via la VIP ($PROBE_MODE) : $e2e" grep -Eq '^[0-9]+,200,' <<<"$e2e"

if (( errors )); then (( QUIET )) || fail "$errors contrôle(s) en échec – état NON nominal"; exit 1; fi
(( QUIET )) || ok "Plateforme dans l'état nominal"
