#!/usr/bin/env bash
# =============================================================================
# Sonde HTTPS – boucle de requêtes sur la VIP, une ligne CSV par requête :
#   t_ms,code,lb,web,app,db,compteur,time_s
# Arrêt : créer le fichier <OUT>.stop.  Le certificat est VALIDÉ (Root CA).
# Usage : probe.sh OUT.csv [intervalle_s] [VIP] [ca.crt] [count]
#   count > 0 : n requêtes puis sortie (mode « une fois » de healthcheck.sh)
# =============================================================================
set -u
out=$1; iv=${2:-0.2}; vip=${3:-192.168.89.100}; ca=${4:-/ca.crt}; count=${5:-0}
url=https://www.projet7.local/api
echo "t_ms,code,lb,web,app,db,compteur,time_s" > "$out"
n=0
while [[ ! -e "$out.stop" ]]; do
  t=${EPOCHREALTIME//[.,]/}; t=${t:0:13}
  resp=$(curl -sS -m 2 --connect-timeout 1 --cacert "$ca" \
         --resolve "www.projet7.local:443:$vip" -D - \
         -w $'\n__W__ %{http_code} %{time_total}' "$url" 2>/dev/null)
  code=000 tt=0 lb=- web=- app=- db=- cpt=-
  [[ $resp =~ __W__\ ([0-9]{3})\ ([0-9.,]+) ]] && { code=${BASH_REMATCH[1]}; tt=${BASH_REMATCH[2]/,/.}; }
  [[ $resp =~ [Xx]-[Ll][Bb]-[Nn]ode:\ ([A-Za-z0-9]+) ]] && lb=${BASH_REMATCH[1]}
  [[ $resp =~ \"web\":\"([^\"]*)\" ]]     && web=${BASH_REMATCH[1]}
  [[ $resp =~ \"app\":\"([^\"]*)\" ]]     && app=${BASH_REMATCH[1]}
  [[ $resp =~ \"db_node\":\"([^\"]*)\" ]] && db=${BASH_REMATCH[1]}
  [[ $resp =~ \"compteur\":([0-9]+) ]]    && cpt=${BASH_REMATCH[1]}
  echo "$t,$code,$lb,$web,$app,$db,$cpt,$tt" >> "$out"
  (( count > 0 && ++n >= count )) && break
  sleep "$iv"
done
