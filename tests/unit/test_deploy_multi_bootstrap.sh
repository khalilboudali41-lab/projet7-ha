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
declare -A GS RC

# --- Simulations ----------------------------------------------------------------
log() { :; }; ok() { :; }; warn() { :; }
garbd_check() { :; }
gstate()      { echo DOWN; }                  # cluster entièrement arrêté
wait_on()     { :; }
cold_copy()   { echo "COPY $1" >>"$LOG"; }
start_member(){ echo "MEMBER $1" >>"$LOG"; }
grastate_of() { echo "${GS[$1]}"; }
recover_of()  { echo "COPY_BEFORE_RECOVER_CHECK" >>"$LOG"; echo "${RC[$1]:-}"; }
on() {
  case "$2" in
    *"{{.State.Running}}"*) echo false ;;
    *GALERA_BOOTSTRAP=1*)   echo "BOOT ${2##* }" >>"$LOG" ;;
    *) : ;;
  esac
}

pass=0; failn=0
# scenario <nom> <attendu : galeraN|AMBIGU|REFUS> <grastate1> <grastate2> [recover1] [recover2] [--bootstrap X]
scenario() {
  local name=$1 want=$2 got out rc
  GS=([galera1]="$3" [galera2]="$4"); RC=([galera1]="${5:-}" [galera2]="${6:-}")
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
  if [[ "$got" == "$want" && $inv == ok ]]; then pass=$((pass+1)); printf '  ok   %-58s → %s\n' "$name" "$got"
  else failn=$((failn+1)); printf '  ÉCHEC %-57s → %s (attendu %s, invariant : %s)\n' "$name" "$got" "$want" "$inv"; fi
}

echo "== Choix du fondateur (cluster entièrement arrêté)"
scenario "premier déploiement (2 volumes vides)"              galera1 NEW NEW
scenario "galera1 safe_to_bootstrap 1"                        galera1 "$U 14 1" "$U 13 0"
scenario "galera2 safe_to_bootstrap 1"                        galera2 "$U 13 0" "$U 14 1"
scenario "même UUID, seqno 14 > 13"                           galera1 "$U 14 0" "$U 13 0"
scenario "même UUID, seqno 13 < 20"                           galera2 "$U 13 0" "$U 20 0"
scenario "même UUID, seqno égaux (même historique)"           galera1 "$U 17 0" "$U 17 0"
scenario "arrêt brutal : recover 30 > 25"                     galera1 "$U -1 0" "$U -1 0" "$U:30" "$U:25"
scenario "incident 15/11 : recover UUID nul des deux côtés"   AMBIGU  "$Z -1 0" "$Z -1 0" "$Z:1" "$Z:1"
scenario "UUID différents (deux historiques)"                 AMBIGU  "$U 14 0" "$V 99 0"
scenario "recover sans position exploitable"                  AMBIGU  "$U -1 0" "$U 13 0" "$U:-1" ""
scenario "galera1 vide, galera2 a des données"                galera2 NEW "$U 13 0"
scenario "--bootstrap galera2 sur un cas ambigu"              galera2 "$Z -1 0" "$Z -1 0" "$Z:1" "$Z:1" galera2
scenario "--bootstrap galera1 dont le volume est vide"        REFUS   NEW "$U 13 0" "" "" galera1

rm -f "$LOG"
echo "== $pass réussi(s), $failn échec(s)"
[[ $failn -eq 0 ]]
