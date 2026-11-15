#!/usr/bin/env bash
# =============================================================================
# Projet 7 – PKI interne à 2 niveaux (openssl)
#
#   Root CA (RSA 4096, 10 ans, HORS LIGNE)
#     └── CA intermédiaire (RSA 4096, 5 ans, pathlen:0)
#           └── certificat serveur (ECDSA P-256, 397 jours, SAN = domaine)
#
# Usage : scripts/pki.sh all                 # init + server + verify (défaut)
#         scripts/pki.sh init                # Root CA + CA intermédiaire
#         scripts/pki.sh server [CN] [SAN…]  # certificat serveur (défaut : www.projet7.local)
#         scripts/pki.sh verify [CN]         # contrôles de la chaîne
#         scripts/pki.sh offline             # archive chiffrée de la clé Root puis effacement
#         scripts/pki.sh restore-root FICHIER.enc  # remet la clé Root (renouvellement intermédiaire)
#         scripts/pki.sh rotate-pass         # nouvelles phrases de passe des clés CA (clés inchangées)
#
# Idempotent : ne régénère jamais une CA existante. Aucune commande sudo.
# =============================================================================
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PKI_DIR="$ROOT_DIR/pki"
export SAN="DNS:placeholder"          # requis par intermediate.cnf ($ENV::SAN)
ROOT="$PKI_DIR/root-ca"
INT="$PKI_DIR/intermediate"
DEFAULT_CN="www.projet7.local"
DEFAULT_SANS=("www.projet7.local" "projet7.local")

log()  { printf '\033[1;34m[pki]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pki] ERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

# Arborescence d'une CA (base openssl ca)
prepare_ca_dir() {
  local d=$1
  mkdir -p "$d"/{certs,crl,csr,newcerts,db,private}
  chmod 700 "$d/private"
  [[ -f "$d/db/index.txt" ]] || : > "$d/db/index.txt"
  [[ -f "$d/db/serial"    ]] || openssl rand -hex 16 > "$d/db/serial"
  [[ -f "$d/db/crlnumber" ]] || echo 1000 > "$d/db/crlnumber"
}

# Phrase de passe aléatoire (protège la clé au repos ; à reporter dans un coffre)
ensure_pass() {
  local f=$1
  [[ -s "$f" ]] || { openssl rand -base64 32 > "$f"; chmod 600 "$f"; }
}

# -----------------------------------------------------------------------------
init_root() {
  prepare_ca_dir "$ROOT"
  if [[ -f "$ROOT/certs/root-ca.crt" ]]; then ok "Root CA déjà présente (non régénérée)"; return; fi
  log "Génération de la Root CA (RSA 4096, clé chiffrée AES-256)"
  ensure_pass "$ROOT/private/root-ca.pass"
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -aes-256-cbc -pass "file:$ROOT/private/root-ca.pass" \
    -out "$ROOT/private/root-ca.key"
  openssl req -config "$ROOT/root-ca.cnf" -new -x509 -days 3650 -sha384 \
    -key "$ROOT/private/root-ca.key" -passin "file:$ROOT/private/root-ca.pass" \
    -extensions v3_root_ca -out "$ROOT/certs/root-ca.crt"
  # Copie DER (.cer) : double-clic / import direct sous Windows
  openssl x509 -in "$ROOT/certs/root-ca.crt" -outform DER -out "$ROOT/certs/root-ca.cer"
  chmod 644 "$ROOT/certs/root-ca.crt" "$ROOT/certs/root-ca.cer"
  ok "Root CA : $ROOT/certs/root-ca.crt"
}

init_intermediate() {
  prepare_ca_dir "$INT"
  if [[ -f "$INT/certs/intermediate.crt" ]]; then ok "CA intermédiaire déjà présente (non régénérée)"; return; fi
  [[ -f "$ROOT/private/root-ca.key" ]] || die "clé Root absente (hors ligne ?) : utilise 'restore-root' d'abord"
  log "Génération de la CA intermédiaire (RSA 4096, clé chiffrée AES-256)"
  ensure_pass "$INT/private/intermediate.pass"
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -aes-256-cbc -pass "file:$INT/private/intermediate.pass" \
    -out "$INT/private/intermediate.key"
  openssl req -config "$INT/intermediate.cnf" -new \
    -key "$INT/private/intermediate.key" -passin "file:$INT/private/intermediate.pass" \
    -out "$INT/csr/intermediate.csr"
  log "Signature par la Root CA (5 ans, pathlen:0)"
  openssl ca -config "$ROOT/root-ca.cnf" -batch -notext -days 1825 -md sha384 \
    -extensions v3_intermediate_ca -passin "file:$ROOT/private/root-ca.pass" \
    -in "$INT/csr/intermediate.csr" -out "$INT/certs/intermediate.crt" 2>&1 | sed 's/^/    /'
  cat "$INT/certs/intermediate.crt" "$ROOT/certs/root-ca.crt" > "$INT/certs/ca-chain.crt"
  chmod 644 "$INT/certs/intermediate.crt" "$INT/certs/ca-chain.crt"
  ok "CA intermédiaire : $INT/certs/intermediate.crt"
}

# -----------------------------------------------------------------------------
issue_server() {
  local cn=${1:-$DEFAULT_CN}; shift || true
  local sans=("$@"); [[ ${#sans[@]} -gt 0 ]] || sans=("${DEFAULT_SANS[@]}")
  [[ " ${sans[*]} " == *" $cn "* ]] || sans=("$cn" "${sans[@]}")
  local d="$PKI_DIR/server/$cn"
  mkdir -p "$d/private"; chmod 700 "$d/private"
  [[ -f "$INT/certs/intermediate.crt" ]] || die "CA intermédiaire absente : lance 'init'"

  if [[ -f "$d/server.crt" ]] && openssl x509 -checkend $((30*86400)) -noout -in "$d/server.crt" >/dev/null; then
    ok "Certificat serveur $cn valide encore > 30 jours (non réémis ; supprime $d/server.crt pour forcer)"
    return
  fi

  SAN=$(printf 'DNS:%s,' "${sans[@]}"); export SAN="${SAN%,}"
  log "Émission du certificat serveur $cn  ($SAN)"
  openssl genpkey -quiet -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$d/private/server.key"
  openssl req -new -key "$d/private/server.key" -subj "/O=Projet7 HA/CN=$cn" -out "$d/server.csr"
  openssl ca -config "$INT/intermediate.cnf" -batch -notext -days 397 -md sha256 \
    -extensions server_cert -passin "file:$INT/private/intermediate.pass" \
    -in "$d/server.csr" -out "$d/server.crt" 2>&1 | sed 's/^/    /'

  # Chaîne présentée au client : serveur + intermédiaire (jamais la racine)
  cat "$d/server.crt" "$INT/certs/intermediate.crt" > "$d/fullchain.crt"
  # Format HAProxy : chaîne + clé privée dans un seul PEM
  cat "$d/fullchain.crt" "$d/private/server.key" > "$d/private/haproxy.pem"
  chmod 644 "$d/server.crt" "$d/fullchain.crt" "$d/server.csr"
  chmod 600 "$d/private/server.key" "$d/private/haproxy.pem"
  ok "Certificat : $d/server.crt"
  ok "HAProxy    : $d/private/haproxy.pem"
}

# -----------------------------------------------------------------------------
verify() {
  local cn=${1:-$DEFAULT_CN}
  local d="$PKI_DIR/server/$cn" fails=0
  check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else printf '\033[1;31m  ✘\033[0m %s\n' "$1"; fails=$((fails+1)); fi; }
  log "Vérifications ($cn)"
  check "Root CA auto-signée et valide"            "openssl verify -CAfile '$ROOT/certs/root-ca.crt' '$ROOT/certs/root-ca.crt'"
  check "Intermédiaire signée par la Root"         "openssl verify -CAfile '$ROOT/certs/root-ca.crt' '$INT/certs/intermediate.crt'"
  check "Serveur : chaîne complète valide (purpose sslserver)" \
        "openssl verify -purpose sslserver -CAfile '$ROOT/certs/root-ca.crt' -untrusted '$INT/certs/intermediate.crt' '$d/server.crt'"
  check "Nom d'hôte $cn couvert par le SAN"        "openssl x509 -in '$d/server.crt' -noout -checkhost '$cn' | grep -q 'does match'"
  check "Intermédiaire : pathlen:0"                "openssl x509 -in '$INT/certs/intermediate.crt' -noout -ext basicConstraints | grep -q 'pathlen:0'"
  check "Serveur : CA:FALSE + EKU serverAuth"      "openssl x509 -in '$d/server.crt' -noout -ext basicConstraints,extendedKeyUsage | tr -d '\n' | grep -q 'CA:FALSE.*TLS Web Server Authentication'"
  check "Clé privée serveur ↔ certificat"         "[ \"\$(openssl pkey -in '$d/private/server.key' -pubout)\" = \"\$(openssl x509 -in '$d/server.crt' -noout -pubkey)\" ]"
  check "Serveur valide ≤ 398 jours (règle navigateurs)" \
        "[ \$(( ( \$(date -d \"\$(openssl x509 -in '$d/server.crt' -noout -enddate | cut -d= -f2)\" +%s) - \$(date -d \"\$(openssl x509 -in '$d/server.crt' -noout -startdate | cut -d= -f2)\" +%s) ) / 86400 )) -le 398 ]"
  check "Clés Root/intermédiaire chiffrées"        "! grep -L 'ENCRYPTED' '$INT/private/intermediate.key' | grep -q . && { [ ! -f '$ROOT/private/root-ca.key' ] || grep -q ENCRYPTED '$ROOT/private/root-ca.key'; }"
  check "Permissions private/ = 700, clés = 600"   "[ -z \"\$(find '$PKI_DIR' -path '*/private/*' -type f ! -perm 600)\" ] && [ -z \"\$(find '$PKI_DIR' -type d -name private ! -perm 700)\" ]"
  check "Aucune clé privée suivie par git"         "[ -z \"\$(git -C '$ROOT_DIR' ls-files pki | grep -E 'private/|\\.key\$|\\.pass\$|haproxy\\.pem')\" ]"
  echo
  openssl x509 -in "$d/server.crt" -noout -subject -issuer -dates -ext subjectAltName
  echo "SHA-256 Root CA : $(openssl x509 -in "$ROOT/certs/root-ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
  [[ $fails -eq 0 ]] || die "$fails contrôle(s) en échec"
  ok "Tous les contrôles PKI sont OK"
}

# -----------------------------------------------------------------------------
# Les fichiers private/ sont en 700/600 : seul le propriétaire de pki/ y accède.
# Lancé par un autre compte (ou avec sudo), un test -f échoue par MANQUE DE DROITS
# et non par absence – l'ancienne version concluait alors à tort « déjà hors ligne ».
require_owner() {
  local uid; uid=$(stat -c %u "$PKI_DIR")
  [[ $EUID -eq $uid ]] || die "à lancer en tant que $(stat -c %U "$PKI_DIR") (propriétaire de pki/), sans sudo – lancé ici par $(id -un)"
}

# État de la clé Root : present | absent | inaccessible (jamais de confusion)
root_key_state() {
  local d="$ROOT/private"
  [[ -e "$d" ]] || { echo absent; return; }
  [[ -r "$d" && -x "$d" ]] || { echo inaccessible; return; }
  if [[ -e "$d/root-ca.key" ]]; then
    [[ -r "$d/root-ca.key" ]] && echo present || echo inaccessible
  else
    echo absent
  fi
}

offline() {
  require_owner
  local key="$ROOT/private/root-ca.key" pass="$ROOT/private/root-ca.pass" archives
  case "$(root_key_state)" in
    present) ;;
    inaccessible) die "$ROOT/private ou la clé Root est illisible pour $(id -un) : droits à vérifier (attendu : 700/600, propriétaire de pki/)" ;;
    absent)
      archives=$(ls -1 "$PKI_DIR"/offline/root-ca-key-*.tar.gz.enc 2>/dev/null || true)
      [[ -n "$archives" ]] && die "clé Root déjà hors ligne (archive(s) : $(echo $archives))"
      die "clé Root absente de $ROOT/private et aucune archive dans pki/offline : situation anormale, ne rien effacer" ;;
  esac
  [[ -f "$pass" ]] || die "$pass absent : impossible de contrôler l'archive"

  local out="$PKI_DIR/offline/root-ca-key-$(date +%Y%m%d-%H%M%S).tar.gz.enc"
  mkdir -p "$PKI_DIR/offline"; chmod 700 "$PKI_DIR/offline"
  log "Archive chiffrée de la clé Root (AES-256 + PBKDF2) – choisis une phrase de passe forte (saisie 2 fois)"
  tar -C "$ROOT" -czf - private/root-ca.key private/root-ca.pass \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -out "$out"
  chmod 600 "$out"

  # Contrôle complet AVANT effacement, en mémoire (tmpfs) : contenu, ouverture de la
  # clé avec son .pass, correspondance avec le certificat Root
  log "Contrôle : déchiffrement de l'archive (même phrase de passe, saisie 1 fois)"
  local t; t=$(mktemp -d /dev/shm/p7-root-check.XXXXXX)
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$out" | tar -C "$t" -xzf - \
     || [[ ! -s "$t/private/root-ca.key" || ! -s "$t/private/root-ca.pass" ]] \
     || [[ "$(openssl pkey -in "$t/private/root-ca.key" -passin "file:$t/private/root-ca.pass" -pubout 2>/dev/null)" \
           != "$(openssl x509 -in "$ROOT/certs/root-ca.crt" -noout -pubkey)" ]]; then
    find "$t" -type f -exec shred -u {} +; rm -rf "$t"
    die "archive incomplète ou illisible : clé Root NON effacée (archive à supprimer : $out)"
  fi
  find "$t" -type f -exec shred -u {} +; rm -rf "$t"
  ok "Archive contrôlée : clé + .pass présents, la clé s'ouvre et correspond au certificat Root"

  shred -u "$key" "$pass"
  [[ ! -e "$key" && ! -e "$pass" ]] || die "effacement incomplet : $(ls "$ROOT/private")"
  ok "Clé Root et phrase de passe effacées de la VM (shred). Archive : $out"
  echo "  → copie-la HORS de la VM (clé USB / coffre), puis supprime-la : shred -u '$out'"
  echo "  → limite : shred ne garantit pas l'effacement physique sur XFS/LVM ni dans les instantanés VMware"
}

restore_root() {
  local f=${1:?fichier .enc requis}
  require_owner
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$f" | tar -C "$ROOT" -xzf -
  chmod 600 "$ROOT/private/"*; ok "Clé Root restaurée (pense à refaire 'offline' ensuite)"
}

# -----------------------------------------------------------------------------
# Nouvelle phrase de passe pour une clé de CA. La CLÉ ne change pas (seul son
# chiffrement change) : la CA et tous les certificats émis restent valides.
# Aucune phrase de passe n'est affichée. L'ancienne clé chiffrée et l'ancienne
# phrase ne sont effacées qu'après réussite de tous les contrôles.
rotate_pass_one() {
  local name=$1 key=$2 pass=$3 cert=$4 data
  [[ -f "$key" ]] || { log "$name : clé absente (hors ligne ?) – ignorée"; return 0; }
  [[ -f "$pass" ]] || die "$name : $pass absent"
  local nk="$key.new" np="$pass.new"
  undo() { shred -u "$nk" "$np" 2>/dev/null || true; die "$name : $1 (aucun fichier remplacé)"; }

  openssl rand -base64 32 > "$np"; chmod 600 "$np"
  openssl pkey -in "$key" -passin "file:$pass" -aes-256-cbc -passout "file:$np" -out "$nk" 2>/dev/null \
    || undo "déchiffrement avec la phrase actuelle impossible"
  chmod 600 "$nk"

  # Contrôles AVANT remplacement
  grep -q 'ENCRYPTED' "$nk" || undo "nouvelle clé non chiffrée"
  [[ "$(openssl pkey -in "$nk" -passin "file:$np" -pubout)" == "$(openssl x509 -in "$cert" -noout -pubkey)" ]] \
    || undo "la clé rechiffrée ne correspond pas au certificat"
  ! openssl pkey -in "$nk" -passin "file:$pass" -noout 2>/dev/null \
    || undo "l'ancienne phrase de passe ouvre encore la nouvelle clé"

  # Remplacement (les anciens fichiers restent en .old jusqu'au contrôle final)
  mv "$key" "$key.old"; mv "$pass" "$pass.old"
  mv "$nk" "$key";      mv "$np" "$pass"

  # Contrôle fonctionnel : signature avec la clé, vérifiée avec le certificat
  data=$(mktemp); openssl rand 64 > "$data"
  if ! openssl dgst -sha256 -sign "$key" -passin "file:$pass" "$data" \
       | openssl dgst -sha256 -verify <(openssl x509 -in "$cert" -noout -pubkey) -signature /dev/stdin "$data" >/dev/null; then
    mv -f "$key.old" "$key"; mv -f "$pass.old" "$pass"; rm -f "$data"
    die "$name : signature de contrôle invalide – anciens fichiers remis en place"
  fi
  rm -f "$data"
  shred -u "$key.old" "$pass.old"
  ok "$name : phrase de passe changée (clé et certificat inchangés, signature de contrôle OK)"
}

rotate_pass() {
  rotate_pass_one "Root CA"          "$ROOT/private/root-ca.key"     "$ROOT/private/root-ca.pass"     "$ROOT/certs/root-ca.crt"
  rotate_pass_one "CA intermédiaire" "$INT/private/intermediate.key" "$INT/private/intermediate.pass" "$INT/certs/intermediate.crt"
}

# -----------------------------------------------------------------------------
cmd=${1:-all}; shift || true
case "$cmd" in
  all)          init_root; init_intermediate; issue_server "$@"; verify "${1:-$DEFAULT_CN}" ;;
  init)         init_root; init_intermediate ;;
  server)       issue_server "$@" ;;
  verify)       verify "$@" ;;
  offline)      offline ;;
  restore-root) restore_root "$@" ;;
  rotate-pass)  rotate_pass ;;
  *)            sed -n '3,18p' "$0"; exit 1 ;;
esac
