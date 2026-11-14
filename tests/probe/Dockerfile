# Sonde de test : client HTTPS sur le LAN (192.168.89.97), comme le poste Windows
FROM alpine:3.24.4
RUN apk add --no-cache curl=8.23.0-r0 bash=5.3.9-r1
COPY --chmod=0755 probe.sh /usr/local/bin/probe.sh
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/probe.sh"]
