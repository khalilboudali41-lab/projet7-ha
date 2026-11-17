#!/usr/bin/env bash
# =============================================================================
# Test unitaire : choix du fondateur Galera par scripts/deploy-multi.sh (galera_up)
# Aucun conteneur, aucune VM touchés : Docker/SSH sont simulés, seule la DÉCISION
# est testée (quel nœud est fondé, ou arrêt pour ambiguïté).
#   bash tests/unit/test_deploy_multi_bootstrap.sh
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/deploy-multi.sh"
set +e

Z=00000000-0000-0000-0000-000000000000
U=98aa2a13-e122-11f1-bf46-7ad5f8c5a60d
V=11111111-2222-3333-4444-555555555555
LOG=$(mktemp)
declare -A GS RC RUN GST
ANSWER=yes             # réponse simulée de l'opérateur à la confirmation

# --- Simulations ----------------------------------------------------------------
log() { :; }; ok() { :; }; warn() { :; }
garbd_check() { :; }
gstate()      { echo "${GST[$1]:-DOWN}"; }
show_positions() { :; }
confirm_founder() { echo "CONFIRM $1" >>"$LOG"; [[ $ANSWER == yes ]] || exit 1; }
dc()          { [[ "$2" == stop* ]] && { echo "STOP ${2#stop }" >>"$LOG"; RUN[${2#stop }]=false; }; :; }
wait_on()     { :; }
cold_copy()   { echo "COPY $1" >>"$LOG"; }
start_member(){ echo "MEMBER $1" >>"$LOG"; }
grastate_of() { echo "${GS[$1]}"; }
recover_of()  { echo "COPY_BEFORE_RECOVER_CHECK" >>"$LOG"; echo "${RC[$1]:-}"; }
on() {
  case "$2" in
    *"{{.State.Running}}"*) [[ "$2" =~ (galera[12]) ]]; echo "${RUN[${BASH_REMATCH[1]}]:-false}" ;;
    *RestartCount*)         echo 42 ;;
    *GALERA_BOOTSTRAP=1*)   echo "BOOT ${2##* }" >>"$LOG" ;;
    *) : ;;
  esac
}

pass=0; failn=0
# scenario <nom> <attendu : galeraN|AMBIGU|REFUS> <grastate1> <grastate2> [recover1] [recover2] [--bootstrap X]
# Variables d'appel : RUNNING="galera1 galera2" (lancés), GSTATE1/2 (wsrep), ANSWER,
# CONFIRM=1|0 (confirmation attendue ou non), STOPPED="galera1 galera2" (arrêts attendus)
scenario() {
  local name=$1 want=$2 got out rc g
  GS=([galera1]="$3" [galera2]="$4"); RC=([galera1]="${5:-}" [galera2]="${6:-}")
  RUN=(); for g in ${RUNNING:-}; do RUN[$g]=true; done
  GST=([galera1]="${GSTATE1:-DOWN}" [galera2]="${GSTATE2:-DOWN}")
  : >"$LOG"
  out=$( (galera_up "${7:-}") 2>&1 ); rc=$?
  if grep -q '^BOOT ' "$LOG"; then got=$(awk '/^BOOT /{print $2; exit}' "$LOG")
  elif [[ $rc -ne 0 && "$out" == *AMBIGU* ]]; then got=AMBIGU
  elif [[ $rc -ne 0 ]]; then got=REFUS
  else got="?"; fi
  # Invariants : copie à froid avant tout recover ; le non-fondateur rejoint en membre
  local inv=ok
  if grep -q COPY_BEFORE_RECOVER_CHECK "$LOG" && [[ "$(grep -m1 -nE '^COPY (galera|_)' "$LOG" | cut -d: -f1)" -gt "$(grep -m1 -n COPY_BEFORE_RECOVER_CHECK "$LOG" | cut -d: -f1)" ]]; then inv="copie APRÈS recover"; fi
  if [[ $got == galera? ]]; then local o; [[ $got == galera1 ]] && o=galera2 || o=galera1
    grep -q "^MEMBER $o" "$LOG" || inv="$o ne rejoint pas"; fi
  # Confirmation demandée exactement quand attendu, et AVANT tout démarrage
  if [[ -n "${CONFIRM:-}" ]]; then
    if [[ $CONFIRM == 1 ]]; then grep -q "^CONFIRM" "$LOG" || inv="pas de confirmation"
      local fb fc; fb=$(grep -m1 -nE '^(BOOT|MEMBER)' "$LOG" | cut -d: -f1); fc=$(grep -m1 -n '^CONFIRM' "$LOG" | cut -d: -f1)
      [[ -n "$fb" && -n "$fc" && $fb -lt $fc ]] && inv="démarrage AVANT confirmation"
    else ! grep -q "^CONFIRM" "$LOG" || inv="confirmation inattendue"; fi
  fi
  # Arrêts : exactement ceux attendus, avant toute copie à froid / tout démarrage
  local stops; stops=$(awk '/^STOP /{printf "%s ", $2}' "$LOG"); stops=${stops% }
  [[ "$stops" == "${STOPPED:-}" ]] || inv="arrêts [$stops] (attendu [${STOPPED:-}])"
  if [[ -n "$stops" ]] && grep -qE '^(COPY|BOOT|MEMBER)' "$LOG" \
     && [[ "$(grep -m1 -nE '^(COPY|BOOT|MEMBER)' "$LOG" | cut -d: -f1)" -lt "$(grep -m1 -n '^STOP' "$LOG" | cut -d: -f1)" ]]; then inv="copie/démarrage AVANT l'arrêt"; fi
  if [[ "$got" == "$want" && $inv == ok ]]; then pass=$((pass+1)); printf '  ok   %-58s → %s\n' "$name" "$got"
  else failn=$((failn+1)); printf '  ÉCHEC %-57s → %s (attendu %s, invariant : %s)\n' "$name" "$got" "$want" "$inv"; fi
}

echo "== Choix du fondateur (cluster entièrement arrêté)"
scenario "premier déploiement (2 volumes vides)"              galera1 NEW NEW
scenario "galera1 safe_to_bootstrap 1"                        galera1 "$U 14 1" "$U 13 0"
scenario "galera2 safe_to_bootstrap 1"                        galera2 "$U 13 0" "$U 14 1"
CONFIRM=0 scenario "safe_to_bootstrap : pas de confirmation"   galera1 "$U 14 1" "$U 13 0"
CONFIRM=1 scenario "même UUID, seqno 14 > 13"                 galera1 "$U 14 0" "$U 13 0"
CONFIRM=1 scenario "même UUID, seqno 13 < 20"                 galera2 "$U 13 0" "$U 20 0"
CONFIRM=1 scenario "même UUID, seqno égaux (même historique)" galera1 "$U 17 0" "$U 17 0"
CONFIRM=1 scenario "arrêt brutal : recover 30 > 25"           galera1 "$U -1 0" "$U -1 0" "$U:30" "$U:25"
ANSWER=no CONFIRM=1 scenario "opérateur refuse la proposition" REFUS "$U -1 0" "$U -1 0" "$U:30" "$U:25"
scenario "incident 15/11 : recover UUID nul des deux côtés"   AMBIGU  "$Z -1 0" "$Z -1 0" "$Z:1" "$Z:1"
scenario "UUID différents (deux historiques)"                 AMBIGU  "$U 14 0" "$V 99 0"
scenario "recover sans position exploitable"                  AMBIGU  "$U -1 0" "$U 13 0" "$U:-1" ""
scenario "galera1 vide, galera2 a des données"                galera2 NEW "$U 13 0"
scenario "--bootstrap galera2 sur un cas ambigu"              galera2 "$Z -1 0" "$Z -1 0" "$Z:1" "$Z:1" galera2
scenario "--bootstrap galera1 dont le volume est vide"        REFUS   NEW "$U 13 0" "" "" galera1

echo "== Nœuds lancés sans composant primaire (reprise après arrêt des 2 VMs)"
RUNNING="galera1 galera2" STOPPED="galera1 galera2" CONFIRM=1 \
  scenario "incident 17/11 : 2 nœuds en boucle, recover 1200 < 1406" galera2 "$U -1 0" "$U -1 0" "$U:1200" "$U:1406"
RUNNING="galera2" STOPPED="galera2" CONFIRM=1 \
  scenario "galera2 seul en boucle, recover 50 > 40"           galera1 "$U -1 0" "$U -1 0" "$U:50" "$U:40"
RUNNING="galera1 galera2" STOPPED="galera1 galera2" CONFIRM=1 ANSWER=no \
  scenario "2 nœuds en boucle, opérateur refuse"               REFUS   "$U -1 0" "$U -1 0" "$U:1200" "$U:1406"
RUNNING="galera1 galera2" STOPPED="galera1 galera2" CONFIRM=0 \
  scenario "2 nœuds en boucle, --bootstrap galera2"            galera2 "$U -1 0" "$U -1 0" "" "" galera2
RUNNING="galera1 galera2" STOPPED="galera1 galera2" \
  scenario "2 nœuds en boucle, UUID nul → ambigu"              AMBIGU  "$Z -1 0" "$Z -1 0" "$Z:1" "$Z:1"
RUNNING="galera1 galera2" GSTATE2="Donor/Desynced Primary 3" STOPPED="" \
  scenario "galera2 Primary non Synced (SST) : rien n'est arrêté" REFUS "$U -1 0" "$U -1 0"

rm -f "$LOG"
echo "== $pass réussi(s), $failn échec(s)"
[[ $failn -eq 0 ]]
