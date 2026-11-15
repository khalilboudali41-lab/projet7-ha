#!/usr/bin/env bash
# =============================================================================
# Projet 7 – P6 : tests de bascule MULTI-VM, exécutés sur VM3 (novyra-arbitre)
#
# Tourne sur l'arbitre, INDÉPENDAMMENT de VM1 et VM2 (seul accès : la VIP) : il
# survit à l'extinction de l'une ou l'autre. Sonde HTTPS en boucle sur la VIP
# (GET /api, toutes les 0,2 s, certificat vérifié par la Root CA), guide
# l'opérateur (« ▶▶ ACTION … » : appuyer sur Entrée au moment du clic), détecte
# les états attendus, puis écrit un rapport Markdown + CSV brut.
#
#   bash ~/p6/test_failover_vm.sh vm1      # Power Off VM1 dans VMware, puis Power On
#   bash ~/p6/test_failover_vm.sh vm2      # Power Off VM2, puis Power On
#   bash ~/p6/test_failover_vm.sh garbd    # sudo systemctl stop/start garb (2e terminal VM3)
#   bash ~/p6/test_failover_vm.sh downup   # deploy-multi.sh down puis up (sur VM1)
#   bash ~/p6/test_failover_vm.sh smoke    # aucune panne : valide la sonde et le rapport
#
# Rapports : ~/p6/resultats/<horodatage>_vm-<scénario>.md (+ raw/*.csv, index.md)
# à copier dans docs/resultats-tests/ du dépôt (depuis VM1).
# Prérequis VM3 : curl, jq, python3, ~/p6/root-ca.crt (certificat PUBLIC de la CA).
# =============================================================================
set -euo pipefail
export LC_ALL=C.UTF-8

SCEN=${1:-}
VIP=192.168.89.100
HOST=www.projet7.local
BASE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CA=${CA:-$BASE/root-ca.crt}
OUT=${OUT:-$BASE/resultats}
INTERVAL=${INTERVAL:-0.2}
declare -A MAC_OF=([00:0c:29:f7:30:e8]=VM1 [00:0c:29:94:8e:2a]=VM2)

die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }

case "$SCEN" in
  vm1)    TITLE="Power Off de VM1 (novyra-agent : lb1 MASTER, galera1 écrivain)"; FAULT="VMware : Power Off de VM1 (coupure brutale, sans arrêt du système)"; MAX_OUT=15 ;;
  vm2)    TITLE="Power Off de VM2 (novyra-node2 : lb2 BACKUP, galera2)";           FAULT="VMware : Power Off de VM2 (coupure brutale, sans arrêt du système)"; MAX_OUT=15 ;;
  garbd)  TITLE="Arrêt puis redémarrage de l'arbitre garbd (VM3)";                  FAULT="sudo systemctl stop garb, puis start (VM3)";                          MAX_OUT=2 ;;
  downup) TITLE="Arrêt complet puis redéploiement (deploy-multi.sh down / up)";    FAULT="scripts/deploy-multi.sh down, puis up (VM1)";                         MAX_OUT=0 ;;
  smoke)  TITLE="Contrôle de la sonde (aucune panne)";                             FAULT="aucune (validation de la mesure)";                                    MAX_OUT=1 ;;
  *) sed -n '3,20p' "$0"; exit 1 ;;
esac
[[ "$(hostname -s)" == novyra-arbitre ]] || die "à lancer sur VM3 (novyra-arbitre) : il doit survivre à l'extinction de VM1/VM2"
for c in curl jq python3; do command -v $c >/dev/null || die "$c absent"; done
[[ -s "$CA" ]] || die "$CA absent (certificat public de la Root CA, copié depuis VM1)"
{ : </dev/tty; } 2>/dev/null || die "terminal interactif requis (l'opérateur valide chaque action)"

TS=$(date +%Y%m%d-%H%M%S)
RUN=$(mktemp -d); CSV=$RUN/probe.csv; EV=$RUN/events.csv
echo "t_ms,phase,code,lb,web,app,db,compteur,cluster_size,cluster,time_s,vip_mac,curl_rc" > "$CSV"
echo "t_ms,evenement" > "$EV"
echo avant > "$RUN/phase"
T_START=$(date +%s%3N); START_ISO=$(date '+%Y-%m-%d %H:%M:%S')
cleanup() { rm -f "$RUN/running"; [[ -n "${PROBE_PID:-}" ]] && wait "$PROBE_PID" 2>/dev/null || true; }
trap cleanup EXIT

mark()  { echo "$(date +%s%3N),$1" >> "$EV"; }
phase() { echo "$1" > "$RUN/phase"; mark "phase : $1"; }

# --- Sonde (arrière-plan) -------------------------------------------------------
probe() {
  local t0 out rc body tail code tt f mac
  while [[ -f "$RUN/running" ]]; do
    t0=$(date +%s%3N)
    rc=0; out=$(curl -s --cacert "$CA" --resolve "$HOST:443:$VIP" --connect-timeout 1 --max-time 2 \
                  -w $'\n%{http_code} %{time_total}' "https://$HOST/api" 2>/dev/null) || rc=$?
    body=${out%$'\n'*}; tail=${out##*$'\n'}; code=${tail% *}; tt=${tail#* }
    [[ "$out" == *$'\n'* ]] || body=""
    f=$(jq -r '[.lb//"", .web//"", .app//"", .db_node//"", (.compteur//"" |tostring), (.cluster_size//""|tostring), .cluster//""] | @csv' <<<"$body" 2>/dev/null) \
      || f='"","","","","","",""'
    mac=$(ip neigh show "$VIP" 2>/dev/null | awk '{print $5; exit}')
    echo "$t0,$(<"$RUN/phase"),${code:-000},$f,${tt:-0},${mac:-},$rc" >> "$CSV"
    sleep "$INTERVAL"
  done
}

# --- Conditions sur les N dernières réponses ---------------------------------------
# ok_last N [lb] [taille] [lb_exclu] : N dernières requêtes en 200 (et LB / taille du cluster)
ok_last() {
  local n=$1 lb=${2:-} sz=${3:-}
  tail -n "$n" "$CSV" | awk -F, -v n="$n" -v lb="$lb" -v sz="$sz" '
    { gsub(/"/,""); c++; if ($3!=200 || (lb!="" && $4!=lb) || (sz!="" && $9!=sz)) bad=1 }
    END { exit (c<n || bad) }'
}
status_line() {
  tail -n 1 "$CSV" | awk -F, -v t0="$T_START" '$1 ~ /^[0-9]+$/ { gsub(/"/,"");
    printf "\r   +%5.1f s | HTTP %s | LB %-3s | web %-4s app %-4s | %-7s | cluster %s | compteur %s      ",
           ($1-t0)/1000, $3, ($4==""?"-":$4), ($5==""?"-":$5), ($6==""?"-":$6), ($7==""?"-":$7), ($9==""?"-":$9), ($8==""?"-":$8) }' >/dev/tty
}
# wait_for <description> <timeout s> <commande de test…>
wait_for() {
  local d=$1 to=$2 t=$SECONDS; shift 2
  info "Attente : $d (max $to s)"
  while ! "$@"; do
    (( SECONDS - t < to )) || { printf '\n' >/dev/tty; mark "DÉLAI DÉPASSÉ : $d"; info "⚠ délai dépassé ($to s) : $d"; return 1; }
    status_line; sleep 1
  done
  printf '\n' >/dev/tty; mark "atteint : $d"; info "✔ $d (après $((SECONDS - t)) s)"
}
hold() { local s=$1 t=$SECONDS; info "Observation $s s – ne touche à rien"; while (( SECONDS - t < s )); do status_line; sleep 1; done; printf '\n' >/dev/tty; }

# act <message> <événement> : l'opérateur valide l'action avec Entrée
act() {
  printf '\n\a\033[1;33m▶▶ ACTION : %s\033[0m\n' "$1" >/dev/tty
  read -r -p "   Appuie sur Entrée AU MOMENT où tu le fais (ou juste après) … " _ </dev/tty
  mark "$2"; info "Noté : $2"
}

# --- État nominal ---------------------------------------------------------------
info "Scénario $SCEN : $TITLE"
touch "$RUN/running"; probe & PROBE_PID=$!
wait_for "état nominal (10 × 200, lb1, cluster 3)" 60 ok_last 10 lb1 3 \
  || die "état nominal non atteint : vérifier la stack avant le test (deploy-multi.sh status)"
mark "état nominal vérifié"
hold 8

# --- Scénarios ------------------------------------------------------------------
case "$SCEN" in
  smoke)
    hold 10
    ;;
  vm1)
    phase panne
    act "VMware → VM1 « novyra-agent » → Power Off (bouton ■ / VM → Power → Power Off, PAS « Shut Down Guest »)" "Power Off VM1"
    wait_for "VIP sur lb2 et cluster à 2 nœuds (10 × 200)" 180 ok_last 10 lb2 2 || true
    hold 25
    phase restauration
    act "VMware → VM1 « novyra-agent » → Power On (▶). Ne lance AUCUNE commande ensuite." "Power On VM1"
    wait_for "galera1 revenu seul : cluster à 3 nœuds et VIP rendue à lb1 (10 × 200)" 900 ok_last 10 lb1 3 || true
    ;;
  vm2)
    phase panne
    act "VMware → VM2 « novyra-node2 » → Power Off (PAS « Shut Down Guest »)" "Power Off VM2"
    wait_for "cluster à 2 nœuds, VIP toujours sur lb1 (10 × 200)" 180 ok_last 10 lb1 2 || true
    hold 25
    phase restauration
    act "VMware → VM2 « novyra-node2 » → Power On. Ne lance AUCUNE commande ensuite." "Power On VM2"
    wait_for "galera2 revenu seul : cluster à 3 nœuds (10 × 200)" 900 ok_last 10 lb1 3 || true
    ;;
  garbd)
    phase panne
    act "Dans un 2e terminal SUR VM3 : sudo systemctl stop garb" "systemctl stop garb"
    wait_for "cluster à 2 nœuds (galera1 + galera2), service maintenu (10 × 200)" 60 ok_last 10 lb1 2 || true
    hold 20
    phase restauration
    act "Dans le 2e terminal SUR VM3 : sudo systemctl start garb" "systemctl start garb"
    wait_for "garbd revenu : cluster à 3 nœuds (10 × 200)" 120 ok_last 10 lb1 3 || true
    ;;
  downup)
    phase panne
    act "SUR VM1 : cd ~/projet7-ha && scripts/deploy-multi.sh down" "deploy-multi.sh down lancé"
    wait_for "service arrêté (5 échecs consécutifs)" 300 bash -c "tail -n 5 '$CSV' | awk -F, '{if(\$3==200) ok=1} END{exit (NR<5||ok)}'" || true
    printf '\n\033[1;33m   Attends la fin de « down » sur VM1 (message « Arrêté »)…\033[0m\n' >/dev/tty
    phase restauration
    act "SUR VM1 : scripts/deploy-multi.sh up   (galera1, arrêté en dernier, refonde le cluster)" "deploy-multi.sh up lancé"
    wait_for "service revenu : cluster à 3 nœuds, VIP sur lb1 (10 × 200)" 900 ok_last 10 lb1 3 || true
    ;;
esac
phase apres
hold 15
mark "fin de la sonde"
cleanup; PROBE_PID=""

# --- Vue de l'arbitre (journal garbd) ---------------------------------------------
journalctl -u garb --since "$START_ISO" --no-pager -o short-iso 2>/dev/null \
  | grep -E 'Quorum results|members +=|view\(view_id|Shifting|left|partition|suspect' > "$RUN/garbd.log" || true

# --- Rapport --------------------------------------------------------------------
mkdir -p "$OUT/raw"
REPORT="$OUT/${TS}_vm-$SCEN.md"; RAW="$OUT/raw/${TS}_vm-$SCEN.csv"
cp "$CSV" "$RAW"
python3 - "$SCEN" "$TITLE" "$FAULT" "$MAX_OUT" "$CSV" "$EV" "$RUN/garbd.log" "$REPORT" "$RAW" "$TS" "$OUT/index.md" "$INTERVAL" <<'PY'
import csv, sys, os, datetime, collections
scen, title, fault, max_out, fcsv, fev, fg, rep, raw, ts, idx, interval = sys.argv[1:13]
max_out = float(max_out)
MAC = {"00:0c:29:f7:30:e8": "VM1", "00:0c:29:94:8e:2a": "VM2"}
rows = list(csv.DictReader(open(fcsv)))
for r in rows:
    r["t"] = int(r["t_ms"]); r["ok"] = r["code"] == "200"
    r["n"] = int(r["compteur"]) if r["compteur"].isdigit() else None
    r["sz"] = r["cluster_size"]; r["vm"] = MAC.get(r["vip_mac"], r["vip_mac"] or "?")
ev = [(int(a), b) for a, b in (l.rstrip("\n").split(",", 1) for l in open(fev).readlines()[1:])]
t0 = rows[0]["t"]; rel = lambda t: (t - t0) / 1000
def evt(prefix):
    for t, e in ev:
        if e.startswith(prefix): return t
fault_t = next((t for t, e in ev if not e.startswith(("phase", "atteint", "état", "fin", "DÉLAI"))), None)
rest_t = [t for t, e in ev if not e.startswith(("phase", "atteint", "état", "fin", "DÉLAI"))]
rest_t = rest_t[1] if len(rest_t) > 1 else None

# Fenêtres d'indisponibilité : 1re requête en échec → 1re requête réussie suivante
wins, cur = [], None
for r in rows:
    if not r["ok"] and cur is None: cur = {"start": r["t"], "n": 0, "phase": r["phase"]}
    if not r["ok"]: cur["n"] += 1
    if r["ok"] and cur is not None: cur["end"] = r["t"]; wins.append(cur); cur = None
if cur is not None: cur["end"] = rows[-1]["t"]; cur["open"] = True; wins.append(cur)
dur = lambda w: (w["end"] - w["start"]) / 1000
maxw = max((dur(w) for w in wins), default=0.0)
ok = [r for r in rows if r["ok"]]; ko = [r for r in rows if not r["ok"]]
causes = collections.Counter(("HTTP " + r["code"]) if r["code"] not in ("000", "") else "timeout/connexion" for r in ko)

# Compteur : strictement croissant sur les réponses réussies
vals = [r["n"] for r in ok if r["n"] is not None]
anom = sum(1 for a, b in zip(vals, vals[1:]) if b <= a)
before = [r["n"] for r in ok if r["n"] is not None and fault_t and r["t"] < fault_t]
after = [r["n"] for r in ok if r["n"] is not None and fault_t and r["t"] > fault_t]

def first(cond, since=None):
    for r in rows:
        if (since is None or r["t"] >= since) and cond(r): return r
def stable_from(cond, since, n=10):
    run = 0
    for r in rows:
        if r["t"] < since: continue
        run = run + 1 if cond(r) else 0
        if run == n: return r
def fmt(r, base):
    return f"{(r['t'] - base) / 1000:.1f} s" if r and base else "—"
cnt = lambda xs: " ".join(f"{k}×{v}" for k, v in sorted(collections.Counter(xs).items()) if k) or "—"

checks = []
def chk(okv, txt): checks.append((bool(okv), txt))
last5 = all(r["ok"] for r in rows[-5:])
lb_before = {r["lb"] for r in ok if fault_t and r["t"] < fault_t}
if scen == "vm1":
    r_lb2 = first(lambda r: r["ok"] and r["lb"] == "lb2", fault_t)
    chk(r_lb2, f"La VIP passe sur lb2 (VM2) après le Power Off de VM1 – 1re réponse de lb2 à +{fmt(r_lb2, fault_t)}")
    mac2 = first(lambda r: r["vm"] == "VM2", fault_t)
    chk(mac2, f"Vu depuis VM3, la VIP répond avec la MAC de VM2 – à +{fmt(mac2, fault_t)}")
    sz2 = first(lambda r: r["ok"] and r["sz"] == "2", fault_t)
    chk(sz2, f"Le cluster continue à 2 nœuds (galera2 + garbd, quorum 2/3) – à +{fmt(sz2, fault_t)}")
    back = stable_from(lambda r: r["ok"] and r["sz"] == "3", rest_t) if rest_t else None
    chk(back, f"galera1 rejoint le cluster SEUL après Power On (taille 3, aucune commande) – à +{fmt(back, rest_t)} du Power On")
    lb1b = stable_from(lambda r: r["ok"] and r["lb"] == "lb1", rest_t) if rest_t else None
    chk(lb1b, f"lb1 reprend la VIP (préemption après preempt_delay 10 s) – à +{fmt(lb1b, rest_t)} du Power On")
elif scen == "vm2":
    lbs = {r["lb"] for r in ok if fault_t and r["t"] >= fault_t}
    chk(lbs <= {"lb1"}, f"La VIP reste sur lb1 pendant toute la panne de VM2 (vu : {' '.join(sorted(lbs)) or '—'})")
    sz2 = first(lambda r: r["ok"] and r["sz"] == "2", fault_t)
    chk(sz2, f"Le cluster continue à 2 nœuds (galera1 + garbd) – à +{fmt(sz2, fault_t)}")
    back = stable_from(lambda r: r["ok"] and r["sz"] == "3", rest_t) if rest_t else None
    chk(back, f"galera2 rejoint le cluster SEUL après Power On – à +{fmt(back, rest_t)} du Power On")
elif scen == "garbd":
    sz2 = first(lambda r: r["ok"] and r["sz"] == "2", fault_t)
    chk(sz2, f"Sans garbd, le cluster reste Primary à 2 nœuds – à +{fmt(sz2, fault_t)}")
    back = stable_from(lambda r: r["ok"] and r["sz"] == "3", rest_t) if rest_t else None
    chk(back, f"garbd revient dans le cluster (taille 3) – à +{fmt(back, rest_t)} du start")
    lbs = {r["lb"] for r in ok}
    chk(lbs <= {"lb1"}, f"La VIP ne bouge pas (vu : {' '.join(sorted(lbs))})")
elif scen == "downup":
    back = stable_from(lambda r: r["ok"] and r["sz"] == "3" and r["lb"] == "lb1", rest_t) if rest_t else None
    chk(back, f"Service revenu après « up » : cluster 3, VIP sur lb1 – à +{fmt(back, rest_t)} du lancement de up")
if max_out > 0:
    chk(maxw <= max_out, f"Indisponibilité max {maxw:.1f} s ≤ objectif {max_out:.0f} s")
else:
    chk(True, f"Indisponibilité (attendue : arrêt volontaire) : {maxw:.1f} s")
chk(anom == 0 and vals, f"Compteur strictement croissant sur toutes les réponses ({vals[0] if vals else '—'} → {vals[-1] if vals else '—'}, {anom} anomalie)")
if before and after:
    chk(min(after) > max(before), f"Compteur continu à travers la panne : dernière valeur avant {max(before)} < première après {min(after)} (aucune écriture perdue)")
chk(last5, "Service rétabli : 5 dernières requêtes réussies")
verdict_ok = all(c for c, _ in checks)
verdict = "✅ RÉUSSI" if verdict_ok else f"❌ ÉCHEC ({sum(1 for c, _ in checks if not c)} contrôle(s))"

dt = datetime.datetime.strptime(ts, "%Y%m%d-%H%M%S")
L = []
L += [f"# Test de bascule multi-VM – {title}", "", "| | |", "|---|---|",
      f"| Date | {dt:%d/%m/%Y %H:%M:%S} |", "| Script | `scripts/test_failover_vm.sh " + scen + "` (exécuté sur VM3, indépendant de VM1/VM2) |",
      f"| Panne | {fault} |",
      f"| Sonde | VM3 192.168.89.137 · `GET https://www.projet7.local/api` via la VIP 192.168.89.100 · toutes les {interval} s · timeout 2 s · certificat validé par la Root CA |",
      f"| **Verdict** | **{verdict}** |", "", "## Mesures", "| Indicateur | Valeur |", "|---|---|",
      f"| Requêtes envoyées (durée {rel(rows[-1]['t']):.1f} s) | {len(rows)} |",
      f"| Réussies / en échec | {len(ok)} / {len(ko)}" + (f" ({', '.join(f'{k}×{v}' for k, v in causes.items())})" if ko else "") + " |",
      f"| **Indisponibilité maximale** | **{maxw:.1f} s**" + (f" (objectif ≤ {max_out:.0f} s)" if max_out > 0 else " (arrêt volontaire)") + " |",
      f"| Indisponibilité cumulée | {sum(dur(w) for w in wins):.1f} s sur {len(wins)} fenêtre(s) |",
      f"| Compteur (première → dernière réponse) | {vals[0] if vals else '—'} → {vals[-1] if vals else '—'} |", "",
      "> Indisponibilité = temps entre l'envoi de la première requête en échec et celui de la",
      "> première requête réussie suivante (résolution ≈ 0,2 s + timeout de la requête).", "",
      "## Chronologie", "| Instant | Événement |", "|---|---|"]
L += [f"| +{rel(t):.1f} s | {e} |" for t, e in ev]
L += ["", "## Répartition des réponses par phase",
      "| Phase | Requêtes | Réussies | Échecs | Latence max | LB | VIP (MAC vue de VM3) | Web | App | Galera | Taille du cluster |",
      "|---|---|---|---|---|---|---|---|---|---|---|"]
for ph in ["avant", "panne", "restauration", "apres"]:
    rs = [r for r in rows if r["phase"] == ph]
    if not rs: continue
    oks = [r for r in rs if r["ok"]]
    L.append(f"| {ph} | {len(rs)} | {len(oks)} | {len(rs) - len(oks)} | {max((float(r['time_s']) for r in oks), default=0):.2f} s | "
             f"{cnt(r['lb'] for r in oks)} | {cnt(r['vm'] for r in rs)} | {cnt(r['web'] for r in oks)} | {cnt(r['app'] for r in oks)} | "
             f"{cnt(r['db'] for r in oks)} | {cnt(r['sz'] for r in oks)} |")
L += ["", "| Début | Phase | Indisponibilité | Requêtes en échec |", "|---|---|---|---|"]
L += [f"| +{rel(w['start']):.1f} s | {w['phase']} | **{dur(w):.1f} s**{' (non refermée)' if w.get('open') else ''} | {w['n']} |" for w in wins] or ["| — | — | 0 s | 0 |"]
L += ["", "## Contrôles"] + [f"- {'✅' if c else '❌'} {t}" for c, t in checks]
g = open(fg).read().strip()
L += ["", "## Vue de l'arbitre (journal garbd sur VM3)", "", "```", g[-6000:] if g else "(aucun changement de vue pendant le test)", "```",
      "", f"Données brutes : [`raw/{os.path.basename(raw)}`](raw/{os.path.basename(raw)}) (une ligne par requête : horodatage ms, phase, code HTTP, LB, web, app, nœud Galera, compteur, taille du cluster, état, durée, MAC de la VIP vue de VM3, code curl)."]
open(rep, "w").write("\n".join(L) + "\n")
line = f"| {dt:%d/%m/%Y %H:%M:%S} | vm-{scen} | {fault} | {maxw:.1f} s | {len(ko)} / {len(rows)} | {verdict} | [{os.path.basename(rep)}]({os.path.basename(rep)}) |"
open(idx, "a").write(line + "\n")
print(verdict); print("\n".join(f"  {'✅' if c else '❌'} {t}" for c, t in checks))
PY
info "Rapport : $REPORT"
info "CSV brut : $RAW"
rm -rf "$RUN"
