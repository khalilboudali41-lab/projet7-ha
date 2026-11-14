#!/usr/bin/env bash
# =============================================================================
# Projet 7 – test de bascule automatique : perte du nœud Galera écrivain
#   scripts/test_failover_db.sh      (FAULT_HOLD=20 PROBE_INTERVAL=0.2 par défaut)
# Sonde HTTPS en boucle sur la VIP → mesure de l'indisponibilité, contrôle du
# compteur, retour à l'état initial vérifié, rapport dans docs/resultats-tests/.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$P7_ROOT/scripts/failover_lib.sh"

FT_ID=db
FT_TITLE="perte du nœud Galera écrivain (galera1)"
FT_FAULT="docker kill galera1 (arrêt brutal du nœud qui reçoit les écritures)"
FT_MAX_OUTAGE=5
FT_EXPECT_DURING="db!=galera1"
FT_EXPECT_AFTER="db=galera1"

ft_fault()  { docker kill galera1 >/dev/null; }
g1_down_on()  { [[ "$(haproxy_srv "$1" galera_writer galera1)" == DOWN* ]]; }
quorum_2()    { [[ "$(galera_state galera2)|$(galera_state galera3)" == "Synced Primary 2|Synced Primary 2" ]]; }
g1_synced()   { [[ "$(galera_state galera1)" == "Synced Primary 3" ]]; }
ft_during() {
  local p
  for p in dbproxy1 dbproxy2; do
    wait_until "$p marque galera1 DOWN et bascule sur un nœud de secours" 15 g1_down_on "$p"
  done
  wait_until "galera2 et galera3 forment le composant primaire à 2 nœuds (quorum 2/3)" 15 quorum_2
}
ft_restore() {
  docker start galera1 >/dev/null
  wait_until "galera1 rejoint le cluster et se resynchronise (IST)" 180 g1_synced
}
node_cpt() { APP_SQL_HOST=$1 app_sql -e "SELECT valeur FROM compteur WHERE id=1"; }
ft_final() {   # sonde arrêtée : plus aucune écriture, les 3 nœuds doivent être identiques
  local c1 c2 c3; c1=$(node_cpt galera1); c2=$(node_cpt galera2); c3=$(node_cpt galera3)
  check "Les 3 nœuds ont le même compteur, galera1 a rattrapé la panne (${c1}/${c2}/${c3})" \
    test "$c1|$c2" = "$c3|$c3"
}

ft_run
