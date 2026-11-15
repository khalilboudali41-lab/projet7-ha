#!/usr/bin/env bash
# =============================================================================
# Projet 7 – gestion de .env et des secrets (à sourcer APRÈS lib.sh)
#   init_env       : crée .env (600) depuis .env.example, mots de passe aléatoires
#   render_secrets : exporte .env vers secrets/ (700, label SELinux container_file_t)
# Utilisée par scripts/deploy.sh (mono-VM) et scripts/deploy-multi.sh (multi-VM).
# =============================================================================
# -----------------------------------------------------------------------------
init_env() {
  if [[ -f .env ]]; then ok ".env déjà présent (conservé)"; else cp .env.example .env; ok ".env créé"; fi
  chmod 600 .env
  local line k n=0
  # 1. clés apparues dans .env.example depuis la création du .env
  while IFS= read -r line; do
    k=${line%%=*}; grep -q "^${k}=" .env || { echo "$line" >> .env; warn "clé ajoutée : $k"; }
  done < <(grep -E '^[A-Z0-9_]+=' .env.example)
  # 2. mots de passe vides → 32 caractères alphanumériques aléatoires
  while IFS= read -r k; do
    sed -i "s|^${k}=\$|${k}=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)|" .env
    n=$((n+1))
  done < <(grep -E '^[A-Z0-9_]+_(PASSWORD|PASS)=$' .env | cut -d= -f1)
  ok "$n mot(s) de passe généré(s)"
}

# -----------------------------------------------------------------------------
render_secrets() {
  [[ -f .env ]] || die ".env absent : lance 'deploy.sh init-env'"
  [[ "$(stat -c %a .env)" == 600 ]] || { chmod 600 .env; warn ".env remis en 600"; }
  install -d -m 700 secrets
  local map=(db_root_password:DB_ROOT_PASSWORD db_sst_password:DB_SST_PASSWORD
             db_monitor_password:DB_MONITOR_PASSWORD db_app_password:DB_APP_PASSWORD
             db_backup_password:DB_BACKUP_PASSWORD)
  local m f v
  for m in "${map[@]}"; do
    f=${m%%:*}; v=$(grep -E "^${m#*:}=" .env | cut -d= -f2-)
    [[ -n "$v" ]] || die "${m#*:} vide dans .env"
    printf '%s' "$v" > "secrets/$f.tmp" && mv "secrets/$f.tmp" "secrets/$f"
    # 644 : lisible par l'utilisateur non-root du conteneur ; le dossier parent en 700
    # empêche les autres comptes de l'hôte d'y accéder.
    chmod 644 "secrets/$f"
  done
  # Tier LB : mot de passe VRRP, certificat TLS (PKI), userlist des stats (empreinte SHA-512)
  grep -E '^VRRP_PASSWORD=.' .env | cut -d= -f2- | tr -d '\n' > secrets/vrrp_password
  local pem="pki/server/www.projet7.local/private/haproxy.pem"
  [[ -f "$pem" ]] || die "$pem absent : lance scripts/pki.sh all"
  install -m 644 "$pem" secrets/haproxy_pem
  local su sp hash cur
  su=$(grep -E '^HAPROXY_STATS_USER=' .env | cut -d= -f2-); sp=$(grep -E '^HAPROXY_STATS_PASSWORD=' .env | cut -d= -f2-)
  [[ -n "$su" && -n "$sp" ]] || die "HAPROXY_STATS_USER/PASSWORD vides dans .env"
  cur=$(awk '/ password /{print $4}' secrets/haproxy_users_cfg 2>/dev/null || true)
  # on ne régénère l'empreinte que si le mot de passe a changé (fichier stable)
  if [[ -z "$cur" ]] || [[ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$cur")" "$sp")" != "$cur" ]] || ! grep -q " user $su " secrets/haproxy_users_cfg; then
    hash=$(openssl passwd -6 "$sp")
    printf 'userlist stats_users\n    user %s password %s\n' "$su" "$hash" > secrets/haproxy_users_cfg
  fi
  chmod 644 secrets/vrrp_password secrets/haproxy_users_cfg
  # SELinux : sans ce label, container_t ne peut pas lire les fichiers (testé : EACCES)
  chcon -R -t container_file_t secrets
  ok "secrets/ à jour ($(ls secrets | wc -l) fichiers, label container_file_t)"
}
