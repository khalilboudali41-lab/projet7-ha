# Durcissement complémentaire (2026-11-14)

## 1. Page de statistiques HAProxy (:8404) limitée au poste d'administration
| Avant | Après |
|---|---|
| `acl from_lan src 192.168.89.0/24` : tout le LAN pouvait atteindre la page d'authentification | `acl from_admin src 192.168.89.1` : seul le poste Windows d'administration. Tout autre client reçoit **403 avant même la demande d'authentification**, ce qui empêche toute attaque par force brute depuis le reste du LAN. |

Vérifié depuis un autre client du LAN (192.168.89.97) : **403** sur la VIP, sur lb1 et sur lb2, avec ou sans identifiants.

## 2. Rotation de `HAPROXY_STATS_PASSWORD` (ancienne valeur exposée)
- Nouveau mot de passe aléatoire de 32 caractères, écrit directement dans `.env` (mode 600) et **jamais affiché**.
- `deploy.sh lb` régénère l'empreinte SHA-512 (`secrets/haproxy_users_cfg`) quand le mot de passe change, puis redémarre lb2 puis lb1 un par un. Le service n'est pas interrompu.
- Contrôles :
  - l'empreinte chargée par lb1 et lb2 (même SHA-256 que `secrets/`) correspond au **nouveau** mot de passe, et l'ancien est refusé ;
  - l'ancienne valeur n'apparaît nulle part : ni dans le dépôt, ni dans l'historique git, ni dans les journaux ; la sauvegarde temporaire de `.env` a été supprimée avec `shred`.
- Pour lire le mot de passe : `grep HAPROXY_STATS_PASSWORD .env`.
- `.gitignore` exclut désormais aussi `.env.*`, sauf `.env.example`.

Procédure de rotation, à réutiliser pour tout secret de `.env` :
```bash
sed -i 's/^HAPROXY_STATS_PASSWORD=.*/HAPROXY_STATS_PASSWORD=/' .env
scripts/deploy.sh init-env   # remplit la valeur vide avec un nouvel aléa
scripts/deploy.sh lb         # empreinte régénérée + redémarrage tournant
```

## 3. Variable `DOCKER_HOST` pointant vers Podman
- Constat : `DOCKER_HOST=unix:///run/user/1000/podman/podman.sock` n'était défini dans **aucun** fichier : ni `~/.bashrc`, ni `~/.bash_profile`, ni `/etc/profile.d`, ni `environment.d`.
- Origine : l'environnement du **gestionnaire systemd utilisateur** (`systemctl --user show-environment`). Ce gestionnaire, démarré avant la suppression de `podman-docker` (phase 0), avait gardé la variable et la transmettait à chaque nouveau terminal.
- Correction : `systemctl --user unset-environment DOCKER_HOST`, sans sudo et limitée à l'utilisateur. Plus rien ne la recrée, puisque le paquet est désinstallé.
- Les terminaux **déjà ouverts** gardent la variable : `unset DOCKER_HOST`, ou ouvrir un nouveau terminal.
- Les scripts du projet ignorent de toute façon un `DOCKER_HOST` Podman (garde dans `scripts/lib.sh`).
