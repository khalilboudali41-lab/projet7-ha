# Phase 5 – Tier load balancing, VIP et TLS (2026-11-14)

## Architecture

```
 Client Windows 192.168.89.1 ──HTTPS──► VIP 192.168.89.100 (VRRP, VRID 70)
                                         │
       réseau « lan » : ipvlan L2 sur ens160 (VMnet8) – même MAC que la VM
       ┌─────────────────────────────────┴─────────────────────────────────┐
  lb1 192.168.89.101  [HAProxy 3.2.26 uid 99 + keepalived 2.3.4]  prio 150 (MASTER)
  lb2 192.168.89.102  [HAProxy 3.2.26 uid 99 + keepalived 2.3.4]  prio 100 (BACKUP)
       │  VRRP unicast .101 ↔ .102 · track_script : HAProxy répond sur 127.0.0.1:8405
       ▼
  front_net → web1/web2/web3 (leastconn, check HTTP /healthz)
  log_net   → logcollector (rsyslog) → ./logs/
 VM (hôte) ── p7-shim 192.168.89.99/32 (ipvlan, NetworkManager) ──► .53 .100 .101 .102
```

## Pourquoi ipvlan L2 (rappel de la décision validée)
- `network_mode: host` : les 2 keepalived partageraient la même IP/interface → VRRP dégénéré, la VIP ne serait qu'une IP secondaire de la VM.
- macvlan : une MAC par conteneur → mode promiscuité requis sur le vSwitch VMware.
- **ipvlan L2** : chaque LB a sa propre IP sur le LAN avec la MAC de la VM → aucun réglage VMware ; le client Windows joint directement la VIP.
- Conséquences gérées :
  1. le noyau isole l'hôte de ses propres slaves ipvlan → **shim** `p7-shim` (slave ipvlan côté hôte) ;
  2. le trafic vers la VIP n'entre pas dans la pile IP de l'hôte → firewalld de l'hôte ne le voit pas ; la surface exposée = sockets HAProxy (80, 443, 8404) uniquement ;
  3. ipvlan refuse une même adresse sur deux slaves (`EADDRINUSE`) → lors d'une préemption, keepalived échouait à poser la VIP (`Netlink: error: Address in use(98)`) : corrigé par `vip-ensure.sh` (réessai 100 ms × 50) ;
  4. **VIP orpheline (17/11/2026)** : `notify_master` est asynchrone. Sur une bascule MASTER→BACKUP dans la même milliseconde (VMs figées 13 s puis reprise), `vip-ensure.sh` s'exécutait **après** le retrait de la VIP par keepalived et la reposait : lb2 restait BACKUP pour keepalived mais portait la VIP (conflit ARP, « deux MASTER » dans `status`). Corrigé par `vrrp_notify_fifo` + `vrrp-notify.sh` : les transitions sont traitées **dans l'ordre** par un processus unique (MASTER → pose la VIP, tout autre état → la retire), et l'état réel est écrit dans `/run/keepalived/state`, que `deploy-multi.sh status` confronte à la présence de la VIP (`VIP ORPHELINE`, `split-brain`).

## Pourquoi HAProxy (plutôt que Nginx ou Traefik)
| Critère | HAProxy | Nginx (OSS) | Traefik |
|---|---|---|---|
| Health checks actifs HTTP | ✅ natifs | ❌ (Plus payant) | ✅ |
| Stick-tables / rate limiting fin | ✅ | partiel | partiel (middleware) |
| Page de stats temps réel | ✅ | ❌ (Plus) | dashboard |
| Socket d'admin (état, drain à chaud) | ✅ | ❌ | API |
| Rechargement sans coupure, TCP + HTTP | ✅ | ✅ | ✅ |
| Couplage keepalived (track_script) | standard de fait | possible | peu courant |
| Orientation | LB pur, très performant | serveur web + proxy | proxy dynamique (découverte) |

## Configuration (lb/haproxy.cfg, lb/keepalived.conf.tmpl)
| Fonction | Mise en œuvre |
|---|---|
| TLS | TLS 1.2/1.3 uniquement, suites AEAD + PFS (Mozilla intermediate), `no-tls-tickets`, courbes X25519/P-256/P-384, ALPN h2 + http/1.1, chaîne serveur + intermédiaire |
| HTTP → HTTPS | 301 sur le port 80 |
| HSTS + en-têtes | HSTS 2 ans, CSP stricte (`default-src 'none'`), nosniff, X-Frame-Options DENY, Referrer-Policy, Permissions-Policy, COOP/CORP ; `Server` supprimé |
| Hôtes | `www.projet7.local` ; `projet7.local` → 301 vers www ; autre → 421 |
| Méthodes | GET/HEAD uniquement (405) |
| Rate limiting | stick-table par IP : > 100 requêtes / 10 s ou > 30 connexions simultanées → 429 |
| Répartition | `leastconn`, check `GET /healthz` toutes les 2 s (2 échecs → DOWN), `observe layer7`, `redispatch` |
| Sticky sessions | non nécessaires (application sans état) – directive `cookie` documentée en commentaire |
| Stats | `https://www.projet7.local:8404/stats`, poste d'administration 192.168.89.1 uniquement (403 sinon), utilisateur + empreinte SHA-512 (userlist hors image, dans `/run/secrets`) |
| VRRP | unicast, auth PASS, 2 nœuds BACKUP prio 150/100, `preempt_delay 10`, `track_script` (HAProxy répond **et** au moins 1 serveur web UP) |
| Conteneur | HAProxy non-root (uid 99) via su-exec ; keepalived root avec `NET_ADMIN`, `NET_RAW` ; rootfs read-only ; sysctls de namespace `ip_nonlocal_bind=1`, `ip_unprivileged_port_start=0` ; superviseur : la mort d'un processus arrête le conteneur (VIP libérée) |
| Journaux | HAProxy → syslog UDP (log_net) ; tous les autres conteneurs → pilote Docker `syslog` (127.0.0.1:5514) ; `./logs/<conteneur>.log` + `all.log` ; `docker logs` toujours disponible |

## Résultats des tests (client sur le réseau lan, 192.168.89.97)
| Test | Résultat |
|---|---|
| `http://www.projet7.local/` | ✅ 301 → https |
| HTTPS via VIP, validation avec la Root CA | ✅ HTTP/2 200, `Verify return code: 0`, en-têtes de sécurité présents, `x-lb-node: lb1` |
| TLS 1.0 / 1.1 (client forcé `SECLEVEL=0`) | ✅ refusés (`alert protocol version`) |
| TLS 1.2 / 1.3 | ✅ ECDHE-ECDSA-AES128-GCM-SHA256 / TLS_AES_128_GCM_SHA256 |
| Suites faibles (AES128-SHA, ECDHE-RSA-AES128-SHA, DES-CBC3-SHA) | ✅ refusées |
| `projet7.local` / hôte inconnu / POST | ✅ 301 → www / 421 / 405 |
| Répartition (12 requêtes) | ✅ web1 3, web2 4, web3 5 |
| Stats sans / avec mot de passe | ✅ 401 / 200 |
| Rate limiting (150 requêtes rafale) | ✅ 84 × 200 puis 66 × 429 |
| Mise à jour tournante de 11 conteneurs (dont Galera) sous sonde HTTPS | ✅ **267/267 requêtes 200** |
| `docker kill lb1` (sonde 5 req/s) | ✅ VIP sur lb2 en < 3 s, **1 requête perdue** (timeout 2 s) |
| Retour de lb1 | ✅ reprise de la VIP après preempt_delay, **0 requête perdue** |

## Validation manuelle depuis le client Windows (192.168.89.1)
Fichier hosts + Root CA importée (cadenas valide, aucun avertissement).
| Panne provoquée | Résultat observé |
|---|---|
| web1 + web2 arrêtés | ✅ site servi par web3 |
| app1 + app2 arrêtés | ✅ site servi par app3 |
| galera1 arrêté | ✅ compteur conservé, retour à 3 nœuds au redémarrage |
| dbproxy1 arrêté | ✅ dbproxy2 prend le relais (alias `db`) |
| lb1 arrêté | ✅ VIP basculée sur lb2 |

## Shim hôte (persistant – optionnel, non encore créé)
Utile seulement pour joindre la VIP **depuis la VM elle-même** (le client Windows n'en a pas besoin).
Sans shim, les scripts de test passent par un conteneur sonde sur le réseau `lan`.
```bash
sudo nmcli connection add type ipvlan con-name p7-shim ifname p7-shim \
  ipvlan.parent ens160 ipvlan.mode l2 \
  ipv4.method manual ipv4.addresses 192.168.89.99/32 \
  ipv4.routes "192.168.89.100/32, 192.168.89.101/32, 192.168.89.102/32, 192.168.89.53/32" \
  ipv4.never-default yes ipv6.method disabled \
  connection.autoconnect yes connection.zone public
sudo nmcli connection up p7-shim
```
Retrait : `sudo nmcli connection delete p7-shim`.

## Commandes
```bash
scripts/deploy.sh lb        # collecteur de journaux + lb2 puis lb1
scripts/deploy.sh status    # … + VRRP (qui détient la VIP) et état des web vus par chaque LB
tail -f logs/haproxy-lb1.log
```
