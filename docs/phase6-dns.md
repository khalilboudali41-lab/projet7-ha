# Phase 6 – Résolution de noms : DNS bind9 et fichier hosts (2026-11-14)

## Architecture

```
 Client Windows 192.168.89.1
   │  « www.projet7.local ? »  (règle NRPT, ou serveur DNS direct)
   ▼
 dns (ns1) 192.168.89.53  ── réseau « lan » (ipvlan L2 sur ens160, comme lb1/lb2)
   │  bind 9.20.30, faisant autorité pour projet7.local, sans récursion
   ▼  « 192.168.89.100 » (VIP Keepalived)
 HTTPS → lb1 / lb2 → web → app → Galera
```

## Zone `projet7.local` (dns/db.projet7.local)
| Nom | Type | Valeur |
|---|---|---|
| `projet7.local` | SOA / NS | `ns1.projet7.local.`, série `2026111401`, TTL 300 s |
| `ns1` | A | 192.168.89.53 |
| `www` | A | **192.168.89.100** (VIP) |
| `projet7.local` (apex) | A | 192.168.89.100 (HAProxy redirige vers www) |
| `lb1` / `lb2` | A | 192.168.89.101 / .102 (administration, stats) |

Le TTL de 300 s convient : la haute disponibilité repose sur la VIP, qui ne change jamais d'adresse, et non sur le DNS.

## Choix et durcissement
| Choix | Justification |
|---|---|
| **Autorité seule** (`recursion no`) | Ce n'est pas un résolveur ouvert : pas d'empoisonnement de cache ni d'amplification par récursion. Les autres domaines restent résolus par le DNS habituel du client (voir la règle NRPT ci-dessous). |
| `allow-query` limité au LAN 192.168.89.0/24 | Le serveur ne répond à personne d'autre. |
| `allow-transfer none`, `allow-update none`, `controls { }` | Pas de fuite de zone (AXFR), pas de mise à jour dynamique, pas de canal rndc. |
| `version/hostname/server-id none` | Les requêtes CHAOS (`version.bind`…) ne renvoient aucune information. |
| RRL (20 réponses/s, fenêtre 5 s) | Limite l'usage du serveur comme amplificateur DDoS. |
| Conteneur | Utilisateur `named` (uid 100, non-root), **aucune capacité** (port 53 autorisé via la sysctl de namespace `ip_unprivileged_port_start=53`), rootfs en lecture seule, tmpfs /tmp, 64 Mo. |
| Zone dans l'image | `named-checkconf -z` est exécuté au build : une zone invalide ne produit pas d'image. Modifier la zone : incrémenter la série, puis `scripts/deploy.sh dns`. |
| Journal des requêtes | `logs/dns.log` (collecteur central). |
| Instance unique | Ce n'est pas un SPOF du service : la VIP est fixe, les clients gardent la réponse en cache (300 s) et le fichier hosts sert de secours. Pour la production : un secondaire `ns2` sur une autre machine. |

## Résultats des tests (client sur le LAN 192.168.89.97)
| Test | Résultat |
|---|---|
| `dig @192.168.89.53 www.projet7.local A` | ✅ `192.168.89.100`, drapeau `aa` (réponse faisant autorité) |
| Apex, NS, SOA | ✅ `.100`, `ns1.projet7.local.`, série 2026111401 |
| Nom inexistant | ✅ `NXDOMAIN` |
| Récursion (`google.com`) | ✅ `REFUSED` |
| Transfert de zone (AXFR) | ✅ `Transfer failed` |
| `version.bind`, `hostname.bind`, `id.server` | ✅ 0 réponse |
| Résolution par bind9 puis HTTPS validé par la Root CA | ✅ `www` → HTTP/2 200 (`verify=0`) ; apex → 301 vers `https://www.projet7.local/` |
| Conteneur | ✅ uid 100, écriture refusée (`Read-only file system`), healthcheck vert |

## Côté Windows (192.168.89.1)

### Option A – DNS bind9 (recommandée) : règle NRPT
La règle envoie **uniquement** les noms en `projet7.local` vers bind9. Le reste d'Internet continue de passer par le DNS habituel. PowerShell **administrateur** :
```powershell
Add-DnsClientNrptRule -Namespace "projet7.local", ".projet7.local" -NameServers "192.168.89.53"
Clear-DnsClientCache
Resolve-DnsName www.projet7.local           # → 192.168.89.100
```
Retrait :
```powershell
Get-DnsClientNrptRule | Where-Object { $_.Namespace -match 'projet7' } | Remove-DnsClientNrptRule -Force
```
Pièges :
- `nslookup` **ignore** les règles NRPT. Pour interroger bind9 directement : `nslookup www.projet7.local 192.168.89.53`. Pour tester la règle : `Resolve-DnsName`.
- Le fichier hosts est **prioritaire** sur le DNS. Pour tester le DNS, commentez la ligne `projet7.local` du fichier hosts (option B), puis lancez `Clear-DnsClientCache`.

Variante sans PowerShell : Paramètres réseau de la carte VMnet8 → DNS préféré 192.168.89.53. Cela ne suffit que si la machine ne résout rien d'autre par cette carte, puisque bind9 refuse la récursion.

### Option B – fichier hosts (secours, sans DNS)
Bloc-notes lancé **en administrateur**, fichier `C:\Windows\System32\drivers\etc\hosts` :
```
192.168.89.100  www.projet7.local projet7.local
```
Puis `ipconfig /flushdns`. Cette option est simple et ne dépend d'aucun service, mais chaque poste doit être modifié à la main.

### Côté VM (RHEL)
Sans le shim `p7-shim` (docs/phase5-lb.md), la VM ne peut joindre ni la VIP ni .53, à cause de l'isolation hôte ↔ ipvlan. Une fois le shim créé :
- `dig @192.168.89.53 www.projet7.local` ;
- ou une ligne `192.168.89.100 www.projet7.local projet7.local` dans `/etc/hosts`.

## Commandes
```bash
scripts/deploy.sh dns       # construit (zone vérifiée) et (re)déploie bind9
scripts/deploy.sh status    # … + « www.projet7.local → 192.168.89.100 »
tail -f logs/dns.log        # requêtes reçues
```
