# Tier LB : HAProxy (non-root) + keepalived (VRRP) dans un même conteneur.
# Si l'un des deux processus meurt, le conteneur s'arrête : son namespace
# réseau (et donc la VIP) disparaît proprement et le pair prend le relais.
FROM haproxy:3.2.26-alpine
USER root
RUN apk add --no-cache keepalived=2.3.4-r2 su-exec=0.3-r0 socat
COPY entrypoint.sh        /usr/local/bin/lb-entrypoint.sh
COPY vip-ensure.sh        /usr/local/bin/vip-ensure.sh
COPY keepalived.conf.tmpl /etc/keepalived/keepalived.conf.tmpl
COPY haproxy.cfg          /usr/local/etc/haproxy/haproxy.cfg
COPY errors/429.http      /usr/local/etc/haproxy/errors/429.http
# Permissions explicites (les répertoires doivent rester traversables : le
# conteneur tourne sans CAP_DAC_OVERRIDE, même root n'outrepasse pas les droits)
RUN chmod 0755 /usr/local/bin/lb-entrypoint.sh /usr/local/bin/vip-ensure.sh /etc/keepalived /usr/local/etc/haproxy/errors \
 && chmod 0644 /etc/keepalived/keepalived.conf.tmpl /usr/local/etc/haproxy/haproxy.cfg /usr/local/etc/haproxy/errors/429.http
ENTRYPOINT ["/usr/local/bin/lb-entrypoint.sh"]
