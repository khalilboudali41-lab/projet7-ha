#!/bin/sh
# =============================================================================
# Superviseur du conteneur LB (PID 1, root) :
#   1. génère keepalived.conf (mot de passe VRRP lu dans /run/secrets) ;
#   2. lance HAProxy en master-worker sous l'utilisateur haproxy (uid 99) ;
#   3. lance keepalived (root : netlink + sockets raw, capacités minimales) ;
#   4. si l'un meurt → arrêt propre de l'autre → sortie (Docker redémarre).
# Variables : LB_NAME, LB_IP, PEER_IP, VRRP_PRIORITY, VIP
#   P7_MULTI_VM (définie) : suit aussi chk_db_path (chaîne vers la base, poids −60)
# =============================================================================
set -eu
: "${LB_NAME:?}" "${LB_IP:?}" "${PEER_IP:?}" "${VRRP_PRIORITY:?}" "${VIP:?}"
log() { echo "[lb-entrypoint] $*"; }

# Mot de passe VRRP (auth PASS : 8 caractères max en VRRPv2)
VRRP_PASS=$(head -c 8 /run/secrets/vrrp_password)
umask 077
sed -e "s/@LB_NAME@/$LB_NAME/g" -e "s/@LB_IP@/$LB_IP/g" -e "s/@PEER_IP@/$PEER_IP/g" \
    -e "s/@PRIORITY@/$VRRP_PRIORITY/g" -e "s|@VIP@|$VIP|g" -e "s/@VRRP_PASS@/$VRRP_PASS/g" \
    -e "s/@TRACK_DB@/${P7_MULTI_VM:+chk_db_path}/" \
    /etc/keepalived/keepalived.conf.tmpl > /tmp/keepalived.conf

CFG="-f /usr/local/etc/haproxy/haproxy.cfg -f /run/secrets/haproxy_users_cfg"
su-exec haproxy haproxy -c -q $CFG || { log "configuration HAProxy invalide"; exit 1; }

log "$LB_NAME : démarrage HAProxy (uid 99) et keepalived (priorité $VRRP_PRIORITY, VIP $VIP)"
su-exec haproxy haproxy -W -db $CFG &
HP=$!
keepalived --dont-fork --log-console --log-detail --vrrp \
  --use-file /tmp/keepalived.conf \
  --pid /tmp/keepalived.pid --vrrp_pid /tmp/vrrp.pid &
KP=$!

stop() {
  log "arrêt : keepalived d'abord (libère la VIP, annonce priorité 0), puis HAProxy"
  kill -TERM "$KP" 2>/dev/null || true; wait "$KP" 2>/dev/null || true
  kill -USR1 "$HP" 2>/dev/null || true     # HAProxy : arrêt doux (soft-stop)
  sleep 1; kill -TERM "$HP" 2>/dev/null || true; wait "$HP" 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT

# Surveillance : la mort d'un des deux processus arrête le conteneur
while kill -0 "$HP" 2>/dev/null && kill -0 "$KP" 2>/dev/null; do sleep 1; done
kill -0 "$HP" 2>/dev/null || log "HAProxy s'est arrêté"
kill -0 "$KP" 2>/dev/null || log "keepalived s'est arrêté"
stop
exit 1
