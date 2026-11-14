# Phase 0 – Vérifications de la VM (2026-11-14)

| Élément | Résultat |
|---|---|
| OS | RHEL 10.2 (Coughlan), noyau 6.12.0-211.55.1.el10_2 |
| Ressources | 8 vCPU, 11 Gio RAM (~4 Gio dispo, wazuh-indexer ≈ 4,4 Gio), 27 Go disque libre |
| Réseau | ens160 192.168.89.136/24, gw/DNS 192.168.89.2 (VMnet8 NAT) – **adressage DHCP** (ipv4.method=auto) |
| IP projet | .100 (VIP), .101, .102, .53 : libres (arping -D, 3 sondes, aucune réponse) |
| Modules noyau | ipvlan, macvlan, br_netfilter, overlay, nf_conntrack disponibles |
| SELinux | enabled / enforcing / targeted ; container-selinux 2.248 présent |
| firewalld | actif, zone public (ens160) : ssh cockpit dhcpv6-client + 443,1514,1515,8889/tcp |
| Conteneurs | Podman 5.8.2 + podman-docker (émulation) – aucun conteneur ; Docker CE absent |
| Dépôt Docker RHEL 10 | accessible (HTTP 200) ; Docker Hub joignable |
| Heure | NTP synchronisé (prérequis certificats) |
| Outils | git, openssl 3.5.8, curl, jq, dig, nmcli présents |
| Services existants | wazuh-manager/indexer/dashboard, filebeat, rsyslog, ollama, postgresql |
| Ports hôte occupés | 22, 443 (wazuh-dashboard), 1514/1515/55000 (wazuh), 514/udp (rsyslog), 9090, 4330, 44321 ; locaux : 5432, 6379, 9200, 11434 |

## Nettoyage des applications tierces (validé par le binôme)

Script : `scripts/phase0_cleanup_apps.sh` (simulation par défaut, `--apply` pour exécuter), lancé avec sudo le 2026-11-14.

| Élément supprimé | Détail |
|---|---|
| Wazuh 4.7.5 (manager, indexer, dashboard) + filebeat 7.10.2 | paquets, données, configs, dépôt `wazuh.repo`, utilisateurs/groupes |
| Ollama | binaire, bibliothèques (2,1 Go), modèles (4,1 Go), service systemd, utilisateur/groupe |
| PostgreSQL 16 + Valkey 8.0 | paquets et données |
| Metasploit Framework 6.5.3 | paquet, `/opt/metasploit-framework`, dépôt |
| Node.js 22 + npm | paquets |
| firewalld (zone public, permanent) | ports 443, 1514, 1515 et 8889/tcp fermés |

### État après nettoyage

| Contrôle | Résultat |
|---|---|
| Paquets / fichiers / dépôts / utilisateurs résiduels | aucun ; seul `redhat.repo` reste |
| firewalld public | services `ssh cockpit dhcpv6-client`, **aucun port supplémentaire** |
| Ports en écoute (hors loopback) | 22 (ssh), 9090 (cockpit), 4330/44321 (PCP), 5353/udp (avahi) |
| RAM disponible | **8,7 Gio** (au lieu de 4,1) |
| Disque libre | **38 Go** (au lieu de 27) |
| Unités systemd en échec | aucune |
| SELinux / firewalld | Enforcing / actif (inchangés) |
| Podman | conservé ; `podman-docker` sera retiré en phase 1 |
| Adressage ens160 | DHCP conservé (choix (a)) |
