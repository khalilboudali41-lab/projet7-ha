#!/usr/bin/env bash
# =============================================================================
# Projet 7 – bibliothèque des tests de bascule (à sourcer après lib.sh)
#
# Un test définit : FT_ID, FT_TITLE, FT_FAULT (texte), FT_MAX_OUTAGE (s),
#   FT_EXPECT_DURING / FT_EXPECT_AFTER  (« dim=valeur » ou « dim!=valeur »,
#                                        dim ∈ lb web app db – réponses réussies)
# et les fonctions : ft_fault, ft_during, ft_restore, ft_after (facultative)
# puis appelle ft_run.
#
# Déroulé : état nominal vérifié → sonde HTTPS en boucle sur la VIP (5 req/s)
#   → 5 s de référence → panne → maintien FAULT_HOLD s (défaut 20) → restauration
#   → attente de l'état nominal → 8 s d'observation → analyse → rapport
#   horodaté dans docs/resultats-tests/ (+ CSV brut dans docs/resultats-tests/raw/).
# =============================================================================

VIP=192.168.89.100
ALL_CONTAINERS=(galera1 galera2 galera3 dbproxy1 dbproxy2 db-backup app1 app2 app3
                web1 web2 web3 lb1 lb2 dns logcollector)
PROBE_IMAGE=projet7/probe:1.0
PROBE_CA="$P7_ROOT/pki/root-ca/certs/root-ca.crt"
RESULTS_TMP="$P7_ROOT/tests/results"
RESULTS_DIR="$P7_ROOT/docs/resultats-tests"
FAULT_HOLD=${FAULT_HOLD:-20}
PROBE_INTERVAL=${PROBE_INTERVAL:-0.2}

# Sonde : depuis la VM si le shim existe, sinon depuis un conteneur sur le LAN
if ip -br link show p7-shim >/dev/null 2>&1; then
  PROBE_MODE="VM via p7-shim"
else
  PROBE_MODE="conteneur sonde 192.168.89.97 (LAN)"
fi

now_ms() { local t=${EPOCHREALTIME//[.,]/}; echo "${t:0:13}"; }

# --- État des composants ---------------------------------------------------------
container_state() {
  docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo absent
}
container_ok() { [[ "$(container_state "$1")" =~ ^running(/healthy)?$ ]]; }

# Statut d'un serveur dans un backend HAProxy (UP, DOWN, « UP 1/2 »…), via le socket admin
haproxy_srv() {   # haproxy_srv <conteneur> <backend> <serveur>
  local u=(); [[ $1 == lb* ]] && u=(-u haproxy)
  docker exec "${u[@]}" "$1" sh -c "echo 'show stat' | socat stdio unix-connect:/tmp/admin.sock" 2>/dev/null \
    | awk -F, -v b="$2" -v s="$3" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next} $1==b && $2==s {print $h["status"]}'
}

vip_holder() {
  local n
  for n in lb1 lb2; do
    docker exec "$n" ip -4 -o addr show dev lan0 2>/dev/null | grep -q "$VIP/" && { echo "$n"; return; }
  done
  echo aucun
}

# --- Sonde -------------------------------------------------------------------------
probe_docker() {   # probe_docker <ip> <args probe.sh…>
  local ip=$1; shift
  docker run --rm --network projet7_lan --ip "$ip" --user "$(id -u):$(id -g)" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -v "$RESULTS_TMP:/out:z" -v "$PROBE_CA:/ca.crt:ro,z" "$PROBE_IMAGE" "$@"
}

probe_image() {
  docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || docker build -q -t "$PROBE_IMAGE" "$P7_ROOT/tests/probe" >/dev/null
}

probe_once() {   # → ligne CSV d'une requête HTTPS unique
  install -d -m 700 "$RESULTS_TMP"; rm -f "$RESULTS_TMP/once.csv"
  if [[ $PROBE_MODE == VM* ]]; then
    "$P7_ROOT/tests/probe/probe.sh" "$RESULTS_TMP/once.csv" 0 "$VIP" "$PROBE_CA" 1
  else
    probe_image; probe_docker 192.168.89.96 /out/once.csv 0 "$VIP" /ca.crt 1 >/dev/null 2>&1
  fi
  tail -n 1 "$RESULTS_TMP/once.csv" 2>/dev/null || echo "000,erreur sonde"
  return 0
}

probe_start() {   # probe_start <nom.csv>
  install -d -m 700 "$RESULTS_TMP"; rm -f "$RESULTS_TMP/$1" "$RESULTS_TMP/$1.stop"
  PROBE_FILE="$RESULTS_TMP/$1"
  if [[ $PROBE_MODE == VM* ]]; then
    "$P7_ROOT/tests/probe/probe.sh" "$PROBE_FILE" "$PROBE_INTERVAL" "$VIP" "$PROBE_CA" &
    PROBE_PID=$!
  else
    probe_image
    docker rm -f p7-probe >/dev/null 2>&1 || true
    docker run -d --name p7-probe --network projet7_lan --ip 192.168.89.97 --user "$(id -u):$(id -g)" \
      --read-only --cap-drop ALL --security-opt no-new-privileges:true \
      -v "$RESULTS_TMP:/out:z" -v "$PROBE_CA:/ca.crt:ro,z" \
      "$PROBE_IMAGE" "/out/$1" "$PROBE_INTERVAL" "$VIP" /ca.crt >/dev/null
  fi
  trap probe_stop EXIT
}

probe_stop() {
  [[ -n "${PROBE_FILE:-}" ]] || return 0
  touch "$PROBE_FILE.stop"
  if [[ -n "${PROBE_PID:-}" ]]; then wait "$PROBE_PID" 2>/dev/null || true
  else docker wait p7-probe >/dev/null 2>&1 || true; docker rm -f p7-probe >/dev/null 2>&1 || true; fi
  rm -f "$PROBE_FILE.stop"; trap - EXIT
}

# --- Événements, contrôles, attentes --------------------------------------------------
EVENTS=(); CHECKS=(); CHECK_FAIL=0
event() { EVENTS+=("$(now_ms)|$*"); log "▶ $*"; }
check() {   # check "description" commande…
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then CHECKS+=("✅ $d"); ok "$d"
  else CHECKS+=("❌ $d"); CHECK_FAIL=$((CHECK_FAIL+1)); fail "$d"; fi
}
# Attend qu'une condition soit vraie (pas de 0,5 s) et enregistre le délai mesuré
wait_until() {   # wait_until "description" <timeout_s> commande…
  local d=$1 to=$2 t0; shift 2; t0=$(now_ms)
  while :; do
    if "$@" >/dev/null 2>&1; then
      local dt; dt=$(awk -v a="$t0" -v b="$(now_ms)" 'BEGIN{printf "%.1f",(b-a)/1000}')
      CHECKS+=("✅ $d – en ${dt} s"); ok "$d – en ${dt} s"; return 0
    fi
    (( $(now_ms) - t0 > to*1000 )) && break
    sleep 0.5
  done
  # échec enregistré (verdict) sans interrompre le test : la restauration doit toujours avoir lieu
  CHECKS+=("❌ $d – pas obtenu en ${to} s"); CHECK_FAIL=$((CHECK_FAIL+1)); fail "$d – pas obtenu en ${to} s"; return 0
}
nominal() { "$P7_ROOT/scripts/healthcheck.sh" -q; }

# --- Analyse du CSV de la sonde --------------------------------------------------------
# Écrit les tableaux Markdown dans $1.md et les variables de synthèse dans $1.vars
analyse() {   # analyse <prefixe> <csv> <t_panne> <t_restauration> <t_retabli>
  awk -F, -v tf="$3" -v tr="$4" -v tok="$5" -v md="$1.md" -v vars="$1.vars" '
    function ph(t) { return t < tf ? "1" : t < tr ? "2" : t < tok ? "3" : "4" }
    BEGIN { name["1"]="avant la panne"; name["2"]="pendant la panne"; name["3"]="restauration"; name["4"]="après retour nominal" }
    NR==1 { next }
    {
      t=$1; p=ph(t); if (!t0) t0=t; tl=t; n++; N[p]++
      okr = ($2 == 200)
      if (okr) {
        good++; G[p]++; okl[n]=1
        if ($8+0 > LAT[p]) LAT[p]=$8+0
        D[p, "lb", $3]++; D[p, "web", $4]++; D[p, "app", $5]++; D[p, "db", $6]++
        V[p, "lb", $3]; V[p, "web", $4]; V[p, "app", $5]; V[p, "db", $6]
        if ($7 != "-") { if (c1 == "") c1=$7; if (cl != "" && $7+0 <= cl+0) viol++; cl=$7 }
        if (inw) { d=(t-ws)/1000; W[++nw]=sprintf("| +%.1f s | %s | **%.1f s** | %d |", (ws-t0)/1000, name[wp], d, wn); tot+=d; if (d>mx) mx=d; inw=0 }
      } else {
        bad++; B[p]++; codes[$2]++
        if (!inw) { inw=1; ws=t; wp=p; wn=0 } wn++
      }
    }
    END {
      if (inw) { d=(tl-ws)/1000; W[++nw]=sprintf("| +%.1f s | %s | **%.1f s (non rétabli)** | %d |", (ws-t0)/1000, name[wp], d, wn); tot+=d; if (d>mx) mx=d; open=1 }
      last_ok=1; for (i=n; i>n-5 && i>0; i--) if (!okl[i]) last_ok=0
      PROCINFO["sorted_in"]="@ind_str_asc"
      print "| Phase | Requêtes | Réussies | Échecs | Latence max | LB | Web | App | Galera |" > md
      print "|---|---|---|---|---|---|---|---|---|" > md
      for (p=1; p<=4; p++) { p=p""; if (!N[p]) continue
        row=sprintf("| %s | %d | %d | %d | %.2f s", name[p], N[p], G[p], B[p], LAT[p])
        split("lb web app db", dims, " ")
        for (k=1; k<=4; k++) { s=""
          for (key in D) { split(key, a, SUBSEP); if (a[1]==p && a[2]==dims[k]) s=s (s?" ":"") a[3] "×" D[key] }
          row=row " | " (s?s:"—") }
        print row " |" > md
      }
      print "" > md
      if (nw) { print "| Début | Phase | Indisponibilité | Requêtes en échec |" > md; print "|---|---|---|---|" > md
                for (i=1; i<=nw; i++) print W[i] > md }
      else print "_Aucune requête en échec : indisponibilité nulle à la résolution de la sonde._" > md
      cs=""; for (c in codes) cs=cs (cs?", ":"") (c=="000" ? "timeout/connexion" : "HTTP " c) "×" codes[c]
      printf "R_TOTAL=%d\nR_OK=%d\nR_FAIL=%d\nR_WINDOWS=%d\nR_MAX=%.1f\nR_SUM=%.1f\nR_C1=%s\nR_CL=%s\nR_VIOL=%d\nR_LAST_OK=%d\nR_OPEN=%d\nR_CODES=\"%s\"\nR_DURATION=%.1f\n",
        n, good, bad, nw, mx, tot, c1, cl, viol, last_ok, open, cs, (tl-t0)/1000 > vars
      # valeurs observées par phase/dimension (pour FT_EXPECT_*)
      for (key in V) { split(key, a, SUBSEP); S[a[1] "_" a[2]] = S[a[1] "_" a[2]] " " a[3] }
      for (k in S) printf "R_SEEN_%s=\"%s\"\n", k, substr(S[k],2) > vars
    }' "$2"
}

# Vérifie une attente « dim=val » (toutes les réponses) ou « dim!=val » (aucune) sur une phase
expect() {   # expect <phase 1-4> <libellé> <expr>
  local ph=$1 label=$2 e=$3 dim val seen
  [[ -n $e ]] || return 0
  if [[ $e == *'!='* ]]; then dim=${e%%!=*}; val=${e#*!=}; else dim=${e%%=*}; val=${e#*=}; fi
  seen=$(eval "echo \"\${R_SEEN_${ph}_${dim}:-}\"")
  if [[ $e == *'!='* ]]; then
    check "$label : aucune réponse servie par $val (vu : ${seen:-rien})" bash -c "[[ -n '$seen' && ' $seen ' != *' $val '* ]]"
  else
    check "$label : toutes les réponses servies par $val (vu : ${seen:-rien})" test "$seen" = "$val"
  fi
}

# --- Déroulé complet --------------------------------------------------------------------
ft_run() {
  local stamp human csv md base t_fault t_restore t_ok
  stamp=$(date +%Y%m%d-%H%M%S); human=$(date '+%d/%m/%Y %H:%M:%S')
  base="${stamp}_${FT_ID}"; csv="$base.csv"
  install -d -m 755 "$RESULTS_DIR" "$RESULTS_DIR/raw"
  log "Test de bascule « $FT_TITLE » – sonde : $PROBE_MODE"

  log "Précondition : état nominal"
  nominal || { "$P7_ROOT/scripts/healthcheck.sh" || true; die "état initial non nominal – test annulé (rien n'a été modifié)"; }
  ok "état initial nominal"

  probe_start "$csv"; T_PROBE=$(now_ms)
  sleep 5
  event "Panne : $FT_FAULT"
  ft_fault
  t_fault=$(now_ms)   # la phase « panne » commence quand le kill est effectif
  event "Panne effective"
  ft_during
  local left=$(( FAULT_HOLD*1000 - ($(now_ms) - t_fault) ))
  (( left > 0 )) && { log "maintien de la panne ($(( left/1000 )) s)"; sleep "$(( left/1000 ))"; }

  event "Restauration"; t_restore=$(now_ms)
  ft_restore
  wait_until "Retour à l'état nominal complet (healthcheck.sh)" 180 nominal
  event "État nominal retrouvé"; t_ok=$(now_ms)
  declare -F ft_after >/dev/null && ft_after
  sleep 8
  probe_stop
  declare -F ft_final >/dev/null && ft_final   # contrôles à faire sans trafic (sonde arrêtée)

  mv "$RESULTS_TMP/$csv" "$RESULTS_DIR/raw/$csv"
  analyse "$RESULTS_TMP/$base" "$RESULTS_DIR/raw/$csv" "$t_fault" "$t_restore" "$t_ok"
  # shellcheck disable=SC1090
  source "$RESULTS_TMP/$base.vars"

  local cpt_db; cpt_db=$(app_sql -e "SELECT valeur FROM compteur WHERE id=1" 2>/dev/null || echo "?")
  expect 2 "Pendant la panne" "${FT_EXPECT_DURING:-}"
  expect 4 "Après retour"     "${FT_EXPECT_AFTER:-}"
  check "Compteur strictement croissant sur toutes les réponses (${R_C1} → ${R_CL}, ${R_VIOL} anomalie)" test "$R_VIOL" -eq 0
  check "Aucune écriture perdue : compteur en base (${cpt_db}) ≥ dernière valeur servie (${R_CL})" test "${cpt_db:-0}" -ge "${R_CL:-0}"
  check "Indisponibilité max ${R_MAX} s ≤ objectif ${FT_MAX_OUTAGE} s" awk -v a="$R_MAX" -v b="$FT_MAX_OUTAGE" 'BEGIN{exit !(a<=b)}'
  check "Service rétabli : 5 dernières requêtes réussies" test "$R_LAST_OK" -eq 1

  local verdict="✅ RÉUSSI"; (( CHECK_FAIL )) && verdict="❌ ÉCHEC ($CHECK_FAIL contrôle(s))"
  md="$RESULTS_DIR/$base.md"
  {
    echo "# Test de bascule – $FT_TITLE"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Date | $human |"
    echo "| Script | \`scripts/test_failover_${FT_ID}.sh\` |"
    echo "| Panne | $FT_FAULT (maintenue ${FAULT_HOLD} s) |"
    echo "| Sonde | $PROBE_MODE · \`GET https://www.projet7.local/api\` via la VIP $VIP · toutes les ${PROBE_INTERVAL} s · timeout 2 s · certificat validé par la Root CA |"
    echo "| **Verdict** | **$verdict** |"
    echo
    echo "## Mesures"
    echo "| Indicateur | Valeur |"
    echo "|---|---|"
    echo "| Requêtes envoyées (durée ${R_DURATION} s) | $R_TOTAL |"
    echo "| Réussies / en échec | $R_OK / $R_FAIL ${R_CODES:+($R_CODES)} |"
    echo "| **Indisponibilité maximale** | **${R_MAX} s** (objectif ≤ ${FT_MAX_OUTAGE} s) |"
    echo "| Indisponibilité cumulée | ${R_SUM} s sur ${R_WINDOWS} fenêtre(s) |"
    echo "| Compteur (première → dernière réponse) | ${R_C1} → ${R_CL} (base : ${cpt_db}) |"
    echo
    echo "> Indisponibilité = temps entre l'envoi de la première requête en échec et celui de la"
    echo "> première requête réussie suivante (résolution ≈ ${PROBE_INTERVAL} s + timeout de la requête)."
    echo
    echo "## Chronologie"
    echo "| Instant | Événement |"
    echo "|---|---|"
    local e t0=$T_PROBE
    echo "| +0.0 s | Démarrage de la sonde (état nominal vérifié) |"
    for e in "${EVENTS[@]}"; do
      printf '| +%s s | %s |\n' "$(awk -v a="${e%%|*}" -v b="$t0" 'BEGIN{printf "%.1f",(a-b)/1000}')" "${e#*|}"
    done
    echo
    echo "## Répartition des réponses et fenêtres d'indisponibilité"
    cat "$RESULTS_TMP/$base.md"
    echo
    echo "## Contrôles"
    printf -- '- %s\n' "${CHECKS[@]}"
    echo
    echo "Données brutes : [\`raw/$csv\`](raw/$csv) (une ligne par requête : horodatage ms, code HTTP, LB, web, app, nœud Galera, compteur, durée)."
  } > "$md"
  rm -f "$RESULTS_TMP/$base.md" "$RESULTS_TMP/$base.vars"

  # Index des résultats
  local idx="$RESULTS_DIR/README.md"
  [[ -f $idx ]] || printf '# Résultats des tests de bascule\n\nGénéré automatiquement par `scripts/test_failover_*.sh` (le plus récent en bas).\n\n| Date | Test | Panne | Indispo. max | Requêtes en échec | Verdict | Rapport |\n|---|---|---|---|---|---|---|\n' > "$idx"
  printf '| %s | %s | %s | %s s | %s / %s | %s | [%s](%s) |\n' "$human" "$FT_ID" "$FT_FAULT" "$R_MAX" "$R_FAIL" "$R_TOTAL" "$verdict" "$base.md" "$base.md" >> "$idx"

  echo
  log "Résultat : $verdict – indisponibilité max ${R_MAX} s, ${R_FAIL}/${R_TOTAL} requêtes en échec, compteur ${R_C1} → ${R_CL}"
  log "Rapport : docs/resultats-tests/$base.md"
  (( CHECK_FAIL == 0 ))
}
