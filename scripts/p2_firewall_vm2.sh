#!/usr/bin/env bash
# =============================================================================
# Projet 7 – P2 multi-VM : pare-feu de VM2 novyra-node2 (192.168.89.138)
#   sudo bash ~/p2_firewall_vm2.sh
#
# Zone public (ens160) – n'ouvre que le nécessaire, par IP source :
#   depuis VM1 .136 : 3306 (dbproxy1/backup → galera2), 4567 (gcomm),
#                     4568 (IST), 4444 (SST)
#   depuis VM3 .137 : 4567 (gcomm garbd)
#   ferme cockpit (9090) ; ssh reste ouvert
# Policy p7-uplink-egress : le réseau Docker db_uplink (172.30.50.0/24) ne peut
#   sortir que vers galera1 (192.168.89.136:3306) ; le reste est rejeté.
#   (vers galera2 local : zone docker, target ACCEPT – non concerné)
# Idempotent : peut être relancé.
# =============================================================================
set -euo pipefail

EXPECTED_HOST=novyra-node2
EXPECTED_IP=192.168.89.138
PEER_VM=192.168.89.136     # VM1
ARBITER=192.168.89.137     # VM3
UPLINK=172.30.50.0/24
POLICY=p7-uplink-egress

die() { echo "ERREUR : $*" >&2; exit 1; }

# --- Garde-fous ----------------------------------------------------------------
[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || die "ce script est pour $EXPECTED_HOST (VM2), pas pour $(hostname -s)"
ip -4 -o addr show dev ens160 | grep -q " $EXPECTED_IP/" || die "ens160 ne porte pas $EXPECTED_IP : mauvaise VM ?"
[[ $EUID -eq 0 ]] || die "à lancer avec sudo"
firewall-cmd --state >/dev/null 2>&1 || die "firewalld n'est pas actif"
echo "== $(hostname -s) ($EXPECTED_IP) : configuration du pare-feu"

fw() { firewall-cmd --permanent "$@"; }
rich_port() {   # rich_port <ip source> <port>
  fw --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$1/32\" port port=\"$2\" protocol=\"tcp\" accept"
}

# --- Galera entre VMs ----------------------------------------------------------
for p in 3306 4567 4568 4444; do rich_port "$PEER_VM" "$p"; done
rich_port "$ARBITER" 4567

# --- SSH uniquement : fermeture de cockpit -------------------------------------
fw --zone=public --remove-service=cockpit

# --- Sortie de db_uplink -------------------------------------------------------
# La zone docker n'existe sur une VM qu'une fois Docker démarré avec firewalld
fw --get-zones | tr ' ' '\n' | grep -qx docker || die "zone firewalld 'docker' absente : démarrer Docker puis relancer"
fw --get-policies | tr ' ' '\n' | grep -qx "$POLICY" || fw --new-policy="$POLICY"
fw --policy="$POLICY" --set-priority=-10
fw --policy="$POLICY" --add-ingress-zone=docker
fw --policy="$POLICY" --add-egress-zone=public
# Priorités explicites : sans elles, firewalld évalue les rejets AVANT les acceptations
fw --policy="$POLICY" --add-rich-rule="rule priority=\"-2\" family=\"ipv4\" source address=\"$UPLINK\" destination address=\"$PEER_VM/32\" port port=\"3306\" protocol=\"tcp\" accept"
fw --policy="$POLICY" --add-rich-rule="rule priority=\"-1\" family=\"ipv4\" source address=\"$UPLINK\" reject"
# Tout AUTRE conteneur (docker0, log_net…) sort masqué en $EXPECTED_IP, adresse que
# les règles de l'autre VM et de l'arbitre autorisent : on le rejette ici.
fw --policy="$POLICY" --add-rich-rule="rule priority=\"-1\" family=\"ipv4\" destination address=\"$PEER_VM/32\" reject"
fw --policy="$POLICY" --add-rich-rule="rule priority=\"-1\" family=\"ipv4\" destination address=\"$ARBITER/32\" reject"

# --- Conteneurs → Galera de CETTE VM (réseau hôte) ------------------------------
# La zone docker est en target ACCEPT : sans cette policy, tout conteneur joindrait
# galera2 (dont gcomm 4567, non authentifié). Seul db_uplink → 3306 est accepté.
HPOL=p7-docker-to-host
fw --get-policies | tr ' ' '\n' | grep -qx "$HPOL" || fw --new-policy="$HPOL"
fw --policy="$HPOL" --set-priority=-10
fw --policy="$HPOL" --add-ingress-zone=docker
fw --policy="$HPOL" --add-egress-zone=HOST
fw --policy="$HPOL" --add-rich-rule="rule priority=\"-2\" family=\"ipv4\" source address=\"$UPLINK\" destination address=\"$EXPECTED_IP/32\" port port=\"3306\" protocol=\"tcp\" accept"
for p in 3306 4567 4568 4444; do
  fw --policy="$HPOL" --add-rich-rule="rule priority=\"-1\" family=\"ipv4\" port port=\"$p\" protocol=\"tcp\" reject"
done

# --- Application ---------------------------------------------------------------
firewall-cmd --reload

echo; echo "== Services ouverts (zone public)"
firewall-cmd --zone=public --list-services
echo; echo "== Règles riches (zone public)"
firewall-cmd --zone=public --list-rich-rules
echo; echo "== Policy $POLICY"
firewall-cmd --info-policy="$POLICY"
echo; echo "== Policy $HPOL"
firewall-cmd --info-policy="$HPOL"
