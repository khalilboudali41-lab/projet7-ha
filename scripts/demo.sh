#!/usr/bin/env bash
# =============================================================================
# Projet 7 – étapes de la démonstration (voir DEMO.md). Chaque étape AFFICHE la
# commande réellement exécutée, puis montre l'effet observé côté infrastructure.
#
#   scripts/demo.sh prep      # vérification complète avant de commencer
#   scripts/demo.sh etat      # VIP, web vus par lb1/lb2, cluster Galera, écrivain
#   scripts/demo.sh web    | web-ok     # tue web1+web2      | les redémarre
#   scripts/demo.sh db     | db-ok      # tue galera1        | le redémarre (IST)
#   scripts/demo.sh lb     | lb-ok      # tue lb1 (MASTER)   | le redémarre (préemption)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

run() { printf '\n\033[1;35m$ %s\033[0m\n' "$*"; "$@"; }
t0=$(now_ms)
elapsed() { awk -v a="$t0" -v b="$(now_ms)" 'BEGIN{printf "%.1f s", (b-a)/1000}'; }

etat() {
  printf '  VIP 192.168.89.100 → \033[1m%s\033[0m\n' "$(vip_holder)"
  local l
  for l in lb1 lb2; do
    container_ok "$l" || { printf '  %-4s arrêté\n' "$l"; continue; }
    printf '  %-4s voit : web1 %-6s web2 %-6s web3 %s\n' "$l" \
      "$(haproxy_srv "$l" be_web web1)" "$(haproxy_srv "$l" be_web web2)" "$(haproxy_srv "$l" be_web web3)"
  done
  local n
  for n in "${GALERA_NODES[@]}"; do printf '  %-8s %s\n' "$n" "$(galera_state "$n")"; done
  printf '  écrivain vu par dbproxy1 : galera1 %s · galera2 %s\n' \
    "$(haproxy_srv dbproxy1 galera_writer galera1)" "$(haproxy_srv dbproxy1 galera_writer galera2)"
}

case "${1:-}" in
  prep)
    "$P7_ROOT/scripts/healthcheck.sh" || die "plateforme NON nominale : scripts/deploy.sh all, puis recommencer"
    echo; log "Prêt. Côté Windows : page https://www.projet7.local/?refresh=2, stats :8404, boucle PowerShell (DEMO.md)." ;;
  etat) etat ;;

  web)
    run docker kill web1 web2
    log "HAProxy retire les serveurs morts…"
    for _ in $(seq 20); do [[ "$(haproxy_srv lb1 be_web web1)$(haproxy_srv lb1 be_web web2)" == DOWN*DOWN* ]] && break; sleep 0.5; done
    ok "web1 et web2 DOWN sur lb1 après $(elapsed) – le site est servi par web3 seul"; etat ;;
  web-ok)
    run docker start web1 web2; wait_healthy web1 60; wait_healthy web2 60; sleep 4; etat ;;

  db)
    run docker kill galera1
    log "dbproxy bascule l'écrivain, Galera recalcule le quorum…"
    for _ in $(seq 30); do [[ "$(galera_state galera2)" == "Synced Primary 2" ]] && break; sleep 0.5; done
    ok "cluster à 2 nœuds (quorum 2/3) après $(elapsed) – écrivain galera2"; etat ;;
  db-ok)
    run docker start galera1
    log "galera1 rattrape les transactions manquées (IST)…"
    for _ in $(seq 180); do [[ "$(galera_state galera1)" == "Synced Primary 3" ]] && break; sleep 1; done
    ok "galera1 de nouveau Synced après $(elapsed)"
    log "Même compteur sur les 3 nœuds (compte applicatif, nœud par nœud) :"
    for n in "${GALERA_NODES[@]}"; do printf '  %-8s %s\n' "$n" "$(APP_SQL_HOST=$n app_sql -e 'SELECT valeur FROM compteur WHERE id=1')"; done ;;

  lb)
    run docker kill lb1
    log "lb2 attend 3 annonces VRRP manquées puis prend la VIP…"
    for _ in $(seq 30); do [[ "$(vip_holder)" == lb2 ]] && break; sleep 0.2; done
    ok "VIP sur lb2 après $(elapsed)"; etat ;;
  lb-ok)
    run docker start lb1; wait_healthy lb1 60
    log "lb1 (priorité 150) reprend la VIP après preempt_delay 10 s…"
    for _ in $(seq 60); do [[ "$(vip_holder)" == lb1 ]] && break; sleep 0.5; done
    ok "VIP de retour sur lb1 après $(elapsed)"; etat ;;

  *) sed -n '3,11p' "$0"; exit 1 ;;
esac
