# Collecteur de journaux central (rsyslog, non-root)
FROM alpine:3.24.4
RUN apk add --no-cache rsyslog=8.2608.0-r0
COPY --chmod=0644 rsyslog.conf /etc/rsyslog.conf
USER 1000:1000
ENTRYPOINT ["rsyslogd", "-n", "-f", "/etc/rsyslog.conf", "-i", "/tmp/rsyslogd.pid"]
