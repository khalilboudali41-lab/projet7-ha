# Phase 1 – Prérequis hôte (2026-11-14)

Script : `scripts/install_prereqs.sh` (simulation par défaut, `--apply` pour exécuter).

## Actions réalisées
| Action | Résultat |
|---|---|
| Retrait de `podman-docker` (émulateur) | supprimé ; **Podman 5.8.2 conservé** |
| Dépôt officiel Docker | `/etc/yum.repos.d/docker-ce.repo`, clé GPG vérifiée `060A61C51B558A7F742B77AAC52FEB6B621E9F35` |
| Paquets | docker-ce/cli **29.9.3** (figé), containerd.io 2.4.2, buildx 0.39.0, compose **v5.7.1**, rootless-extras |
| `/etc/docker/daemon.json` | `selinux-enabled`, logs json-file 10m×5, `live-restore`, `userland-proxy:false`, `icc:false` (contexte SELinux `container_config_t`) |
| Module `ipvlan` | chargé + persistant (`/etc/modules-load.d/projet7-ha.conf`) |
| Services | `docker` et `containerd` actifs et activés au boot |
| Groupe `docker` | `dr-khalil` ajouté (⚠ équivalent root – voir hardening) |

## Vérifications
| Contrôle | Résultat |
|---|---|
| `docker info` → SecurityOptions | `seccomp(builtin)`, **`selinux`**, `cgroupns` |
| Logging / live-restore | json-file / true |
| SELinux / firewalld | Enforcing / actif (inchangés) |
| Zones firewalld | `public` (ens160 : ssh, cockpit, dhcpv6-client, aucun port) ; `docker` (docker0) créée par Docker |
| `docker run --rm hello-world` | « Hello from Docker! » |

## Points rencontrés
- Le contrôle « Module ipvlan : chargé » ne s'affichait pas : `lsmod | grep -q` avec `set -o pipefail` → SIGPIPE sur lsmod. Corrigé (awk).
- Les sessions ouvertes avant l'installation conservent `DOCKER_HOST=unix:///run/user/1000/podman/podman.sock`
  (exporté par `/etc/profile.d/podman-docker.sh`, désormais supprimé) → le client `docker` vise Podman.
  **Correctif : se reconnecter** (ou `unset DOCKER_HOST`). Le script fait `unset DOCKER_HOST` avant ses vérifications.
