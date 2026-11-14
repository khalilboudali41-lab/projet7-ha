# Proxy SQL interne (tier données) : HAProxy + check Galera-aware
FROM haproxy:3.2.26-alpine
USER root
# mariadb-client : interrogation de l'état wsrep ; socat : socket d'admin (tests/healthcheck)
RUN apk add --no-cache mariadb-client socat
COPY --chmod=0755 galera-check.sh /usr/local/bin/galera-check.sh
USER haproxy
