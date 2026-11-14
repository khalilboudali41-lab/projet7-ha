#!/usr/bin/env bash
# =============================================================================
# Projet 7 – Phase 1 : prérequis hôte (RHEL 10)
#   - remplace l'émulateur podman-docker par Docker CE (dépôt officiel Docker)
#   - configure le démon Docker (SELinux, rotation des logs, live-restore)
#   - charge le module noyau ipvlan de façon persistante
#   - ajoute l'utilisateur au groupe docker
# SELinux (Enforcing) et firewalld (actif) ne sont NI désactivés NI modifiés.
#
# Usage : sudo bash scripts/install_prereqs.sh           -> simulation
#         sudo bash scripts/install_prereqs.sh --apply   -> exécution
# =============================================================================
set -euo pipefail

APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
DOCKER_VERSION="29.9.3"                       # version figée (reproductibilité)
REPO_URL="https://download.docker.com/linux/rhel/docker-ce.repo"
GPG_URL="https://download.docker.com/linux/rhel/gpg"
GPG_FPR="060A61C51B558A7F742B77AAC52FEB6B621E9F35"   # Docker Release (CE rpm)
TARGET_USER="${SUDO_USER:-}"

run()  { echo "+ $*"; [[ $APPLY -eq 1 ]] && "$@"; return 0; }
step() { echo; echo "=== $* ==="; }
die()  { echo "ERREUR : $*" >&2; exit 1; }

[[ $EUID -eq 0 ]]                 || die "à lancer avec sudo"
[[ -n "$TARGET_USER" ]]           || die "SUDO_USER vide : lance le script via sudo depuis ton compte"
grep -q '^ID="rhel"' /etc/os-release || die "ce script cible RHEL"
[[ "$(getenforce)" == "Enforcing" ]] || die "SELinux doit être en Enforcing"
systemctl is-active -q firewalld  || die "firewalld doit être actif"

echo "Mode : $([[ $APPLY -eq 1 ]] && echo EXÉCUTION || echo SIMULATION)  –  utilisateur cible : $TARGET_USER"

# -----------------------------------------------------------------------------
step "1. Retrait de l'émulateur podman-docker (Podman est conservé)"
if rpm -q podman-docker >/dev/null 2>&1; then
  run dnf remove -y podman-docker
else
  echo "podman-docker déjà absent"
fi

# -----------------------------------------------------------------------------
step "2. Dépôt officiel Docker + vérification de la clé GPG"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$GPG_URL" -o "$TMP/docker.gpg"
FPR=$(gpg --show-keys --with-colons "$TMP/docker.gpg" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[[ "$FPR" == "$GPG_FPR" ]] || die "empreinte GPG inattendue : $FPR"
echo "Empreinte GPG vérifiée : $FPR"
run rpm --import "$TMP/docker.gpg"
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  run curl -fsSL "$REPO_URL" -o /etc/yum.repos.d/docker-ce.repo
else
  echo "/etc/yum.repos.d/docker-ce.repo déjà présent"
fi

# -----------------------------------------------------------------------------
step "3. Installation de Docker CE $DOCKER_VERSION + plugins"
PKGS=(docker-ce-"$DOCKER_VERSION" docker-ce-cli-"$DOCKER_VERSION"
      containerd.io docker-buildx-plugin docker-compose-plugin)
if [[ $APPLY -eq 1 ]]; then
  dnf install -y "${PKGS[@]}"
else
  echo "+ dnf install -y ${PKGS[*]}"
  echo "  (la transaction exacte sera affichée en mode --apply ; le dépôt n'est pas encore ajouté en simulation)"
fi

# -----------------------------------------------------------------------------
step "4. Configuration du démon : /etc/docker/daemon.json"
DAEMON_JSON='{
  "selinux-enabled": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "userland-proxy": false,
  "icc": false
}'
echo "$DAEMON_JSON"
if [[ $APPLY -eq 1 ]]; then
  install -d -m 0755 /etc/docker
  [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  printf '%s\n' "$DAEMON_JSON" > /etc/docker/daemon.json
  chmod 0644 /etc/docker/daemon.json
fi

# -----------------------------------------------------------------------------
step "5. Module noyau ipvlan (persistant au reboot)"
run modprobe ipvlan
if [[ $APPLY -eq 1 ]]; then
  echo "ipvlan" > /etc/modules-load.d/projet7-ha.conf
else
  echo "+ echo ipvlan > /etc/modules-load.d/projet7-ha.conf"
fi

# -----------------------------------------------------------------------------
step "6. Démarrage des services"
run systemctl enable --now containerd.service docker.service

# -----------------------------------------------------------------------------
step "7. Groupe docker pour $TARGET_USER (effectif après reconnexion)"
echo "NB : appartenir au groupe docker équivaut à des droits root sur l'hôte (documenté dans le README)."
run usermod -aG docker "$TARGET_USER"

# -----------------------------------------------------------------------------
# Les sessions ouvertes avant l'installation peuvent garder DOCKER_HOST=podman (profile.d de podman-docker)
unset DOCKER_HOST

step "8. Vérifications"
if [[ $APPLY -eq 1 ]]; then
  docker version --format 'Docker Engine {{.Server.Version}} / client {{.Client.Version}}'
  docker compose version
  docker info --format 'Security options : {{.SecurityOptions}}'
  docker info --format 'Logging driver  : {{.LoggingDriver}} | Live restore : {{.LiveRestoreEnabled}}'
  if lsmod | awk '$1=="ipvlan"{f=1} END{exit !f}'; then echo "Module ipvlan : chargé"; else echo "Module ipvlan : ABSENT"; fi
  if firewall-cmd --get-zones | tr " " "\n" | awk '$0=="docker"{f=1} END{exit !f}'; then echo "Zone firewalld docker : présente"; fi
  echo "SELinux : $(getenforce) | firewalld : $(systemctl is-active firewalld)"
  docker run --rm hello-world | grep -m1 'Hello from Docker'
else
  echo "(sautées en simulation)"
fi

echo; echo "=== Terminé ($([[ $APPLY -eq 1 ]] && echo appliqué || echo simulation)) ==="
[[ $APPLY -eq 1 ]] && echo ">>> Déconnecte-toi puis reconnecte-toi (ou 'newgrp docker') pour utiliser docker sans sudo."
exit 0
