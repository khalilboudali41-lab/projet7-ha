#!/usr/bin/env bash
# =============================================================================
# Projet 7 – P2 multi-VM : pare-feu de VM3 novyra-arbitre (192.168.89.137)
#   sudo bash ~/p2_firewall_vm3.sh
#
# Zone public (ens160) :
#   depuis VM1 .136 et VM2 .138 : 4567 (gcomm, garbd). garbd ne fait jamais
#   de SST/IST ni de SQL : 3306/4568/4444 restent fermés.
#   ferme cockpit (9090) ; ssh reste ouvert
# Pas de policy de sortie : VM3 n'a pas Docker (pas de réseau db_uplink).
# Idempotent : peut être relancé.
# =============================================================================
set -euo pipefail

EXPECTED_HOST=novyra-arbitre
EXPECTED_IP=192.168.89.137
NODES=(192.168.89.136 192.168.89.138)   # galera1 (VM1), galera2 (VM2)

die() { echo "ERREUR : $*" >&2; exit 1; }

# --- Garde-fous ----------------------------------------------------------------
[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || die "ce script est pour $EXPECTED_HOST (VM3), pas pour $(hostname -s)"
ip -4 -o addr show dev ens160 | grep -q " $EXPECTED_IP/" || die "ens160 ne porte pas $EXPECTED_IP : mauvaise VM ?"
[[ $EUID -eq 0 ]] || die "à lancer avec sudo"
firewall-cmd --state >/dev/null 2>&1 || die "firewalld n'est pas actif"
echo "== $(hostname -s) ($EXPECTED_IP) : configuration du pare-feu"

fw() { firewall-cmd --permanent "$@"; }

# --- gcomm depuis les nœuds Galera ---------------------------------------------
for n in "${NODES[@]}"; do
  fw --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$n/32\" port port=\"4567\" protocol=\"tcp\" accept"
done

# --- SSH uniquement : fermeture de cockpit -------------------------------------
fw --zone=public --remove-service=cockpit

# --- Application ---------------------------------------------------------------
firewall-cmd --reload

echo; echo "== Services ouverts (zone public)"
firewall-cmd --zone=public --list-services
echo; echo "== Règles riches (zone public)"
firewall-cmd --zone=public --list-rich-rules
echo; echo "== Policies"
echo "Aucune policy projet7 sur VM3 (pas de Docker, donc pas de réseau db_uplink à filtrer)."
echo "Policies présentes : $(firewall-cmd --get-policies)"
