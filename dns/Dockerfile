# Projet 7 – DNS faisant autorité pour projet7.local (bind9, non-root)
FROM alpine:3.24.4
RUN apk add --no-cache bind=9.20.30-r0 bind-tools=9.20.30-r0
COPY named.conf          /etc/bind/named.conf
COPY db.projet7.local    /etc/bind/zones/db.projet7.local
# Contrôle syntaxique au build : une zone invalide ne produit pas d'image
RUN chmod 0755 /etc/bind /etc/bind/zones \
 && chmod 0644 /etc/bind/named.conf /etc/bind/zones/db.projet7.local \
 && named-checkconf -z /etc/bind/named.conf
USER named
# -g : premier plan, journal sur stderr (collecté par le pilote syslog)
ENTRYPOINT ["named", "-g", "-c", "/etc/bind/named.conf"]
