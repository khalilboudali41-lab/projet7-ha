#!/bin/sh
# =============================================================================
# Check externe HAProxy (option external-check) : un nœud n'est « UP » que s'il
# est réellement utilisable par l'application, pas seulement joignable en TCP :
#   wsrep_local_state = 4 (Synced) · wsrep_cluster_status = Primary · wsrep_ready = ON
# Arguments HAProxy : $1 proxy_addr $2 proxy_port $3 server_addr $4 server_port
# =============================================================================
PW=$(cat /run/secrets/db_monitor_password) || exit 2
out=$(MYSQL_PWD="$PW" mariadb --no-defaults --skip-ssl -h "$3" -P "$4" -u monitor \
        --connect-timeout=2 -N -B -e \
        "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_local_state','wsrep_cluster_status','wsrep_ready')" 2>/dev/null) || exit 1
echo "$out" | grep -q "^wsrep_local_state	4$"        || exit 1
echo "$out" | grep -q "^wsrep_cluster_status	Primary$" || exit 1
echo "$out" | grep -q "^wsrep_ready	ON$"              || exit 1
exit 0
