#!/bin/sh
# =============================================================================
# Appelé par vrrp-notify.sh sur MASTER (root) – garantit que la VIP est posée.
# Particularité ipvlan : le noyau refuse qu'une même adresse soit portée par
# deux interfaces ipvlan du même parent (EADDRINUSE). Lors d'une préemption,
# le nouveau MASTER tente d'ajouter la VIP quelques millisecondes AVANT que
# l'ancien ne la retire → keepalived échoue sans réessayer. Ce script réessaie
# toutes les 100 ms pendant 5 s au maximum.
# Usage : vip-ensure.sh <VIP> <interface>
# =============================================================================
VIP=$1; IFACE=$2
i=0
while [ $i -lt 50 ]; do
  ip -4 -o addr show dev "$IFACE" | grep -q " $VIP/" && { echo "[vip-ensure] VIP $VIP présente sur $IFACE (essai $i)"; exit 0; }
  ip addr add "$VIP/24" dev "$IFACE" label "$IFACE:vip" 2>/dev/null && { echo "[vip-ensure] VIP $VIP posée sur $IFACE (essai $i)"; exit 0; }
  i=$((i+1)); sleep 0.1
done
echo "[vip-ensure] ÉCHEC : VIP $VIP non posée après 5 s" >&2
exit 1
