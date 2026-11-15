#!/usr/bin/env bash
# =============================================================================
# Projet 7 – P3 multi-VM : installation et démarrage de garbd sur VM3
#   (novyra-arbitre, 192.168.89.137)
#   sudo bash ~/p3_garbd_vm3.sh
#
# Attend dans ~ (copiés par scp depuis VM1) :
#   garb.sysconfig  → /etc/sysconfig/garb            (copie d'origine : .rpm-orig)
#   10-projet7.conf → /etc/systemd/system/garb.service.d/10-projet7.conf
# Puis : daemon-reload, enable --now garb, état + versions de protocole négociées.
# Idempotent : peut être relancé (redémarre garbd si la configuration a changé).
# =============================================================================
set -euo pipefail

EXPECTED_HOST=novyra-arbitre
EXPECTED_IP=192.168.89.137
NODES=(192.168.89.136 192.168.89.138)
SRC=$(dirname "$(readlink -f "$0")")

die() { echo "ERREUR : $*" >&2; exit 1; }

# --- Garde-fous ----------------------------------------------------------------
[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || die "ce script est pour $EXPECTED_HOST (VM3), pas pour $(hostname -s)"
ip -4 -o addr show dev ens160 | grep -q " $EXPECTED_IP/" || die "ens160 ne porte pas $EXPECTED_IP : mauvaise VM ?"
[[ $EUID -eq 0 ]] || die "à lancer avec sudo"
[[ -x /usr/sbin/garbd ]] || die "garbd absent (paquet galera)"
for f in garb.sysconfig 10-projet7.conf; do [[ -f "$SRC/$f" ]] || die "$SRC/$f absent (scp depuis VM1)"; done

echo "== garbd : $(/usr/sbin/garbd --version 2>&1 | tr -d '\n') / $(rpm -q galera)"

# Au moins un nœud Galera doit répondre sur 4567, sinon garbd s'arrêterait aussitôt
up=0
for n in "${NODES[@]}"; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/$n/4567" 2>/dev/null; then echo "   nœud $n:4567 joignable"; up=1
  else echo "   nœud $n:4567 INJOIGNABLE"; fi
done
[[ $up -eq 1 ]] || die "aucun nœud Galera joignable : démarrer galera1/galera2 d'abord"

# --- Installation --------------------------------------------------------------
[[ -f /etc/sysconfig/garb.rpm-orig ]] || cp -a /etc/sysconfig/garb /etc/sysconfig/garb.rpm-orig
install -o root -g root -m 0644 "$SRC/garb.sysconfig" /etc/sysconfig/garb
install -d -o root -g root -m 0755 /etc/systemd/system/garb.service.d
install -o root -g root -m 0644 "$SRC/10-projet7.conf" /etc/systemd/system/garb.service.d/10-projet7.conf
restorecon -R /etc/sysconfig/garb /etc/systemd/system/garb.service.d
systemctl daemon-reload

# --- Démarrage -----------------------------------------------------------------
systemctl enable garb
systemctl restart garb
sleep 5

echo; echo "== État"
systemctl --no-pager --lines=0 status garb || true
echo; echo "== Drop-in pris en compte"
systemctl show garb -p DropInPaths -p Restart -p User -p NoNewPrivileges -p ProtectSystem
echo; echo "== Contexte SELinux du processus"
ps -eZ | grep -w garbd || true
echo; echo "== Écoute"
ss -tlnH | grep ':4567 ' || echo "(4567 non en écoute)"
echo; echo "== Journal : connexion et versions de protocole négociées"
journalctl -u garb -b --no-pager -o short-iso \
  | grep -E 'protocol version|proto_max|Quorum results|members|CONNECTED|SYNCED|Synchronized|ERROR|refused|failed' \
  | tail -25
