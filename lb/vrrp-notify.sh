#!/bin/sh
# =============================================================================
# keepalived notify_fifo_script (root) – SEUL gestionnaire des transitions VRRP.
# keepalived écrit chaque transition, DANS L'ORDRE, dans une FIFO lue ici par un
# processus unique : un BACKUP est toujours traité après le MASTER qui le précède.
#
# Pourquoi (incident du 17/11) : avec notify_master, le script de pose de la VIP
# était lancé en asynchrone. Sur un MASTER→BACKUP dans la même milliseconde
# (VMs figées 13 s puis reprise), il s'exécutait APRÈS le retrait de la VIP par
# keepalived et la reposait : VIP orpheline sur le BACKUP, ARP en conflit.
#
#   MASTER        → pose la VIP (vip-ensure.sh : réessai ipvlan EADDRINUSE)
#   autre état    → retire la VIP si elle est encore là (BACKUP, FAULT, STOP)
# L'état courant est écrit dans /run/keepalived/state (lu par deploy-multi.sh status).
# Usage (keepalived ajoute la FIFO en dernier argument) : vrrp-notify.sh <VIP> <iface> <fifo>
# =============================================================================
VIP=$1; IFACE=$2; FIFO=$3
STATE=/run/keepalived/state
log() { echo "[vrrp-notify] $*" > /proc/1/fd/1 2>/dev/null || true; }
has_vip() { ip -4 -o addr show dev "$IFACE" | grep -q " $VIP/"; }

echo INIT > "$STATE"
# Format keepalived : INSTANCE "VI_PROJET7" MASTER 150
while read -r type name state prio; do
  [ "$type" = INSTANCE ] || continue
  echo "$state $prio $(date +%s)" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  case $state in
    MASTER)
      log "$name → MASTER (priorité $prio)"
      /usr/local/bin/vip-ensure.sh "$VIP" "$IFACE" > /proc/1/fd/1 2>&1 ;;
    *)
      if has_vip; then
        ip addr del "$VIP/24" dev "$IFACE" 2>/dev/null \
          && log "$name → $state : VIP $VIP retirée (laissée en place après la transition)" \
          || log "$name → $state : ÉCHEC du retrait de la VIP $VIP"
      else
        log "$name → $state (priorité $prio)"
      fi ;;
  esac
done < "$FIFO"
log "FIFO fermée (arrêt de keepalived)"
