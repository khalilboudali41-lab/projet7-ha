# Phase 7 – Tests de bascule automatisés (2026-11-14)

## Scripts
| Script | Panne provoquée (`docker kill` = SIGKILL, arrêt brutal) | Objectif d'indisponibilité |
|---|---|---|
| `scripts/test_failover_web.sh` | web1 + web2 (2 nginx sur 3) | ≤ 3 s |
| `scripts/test_failover_app.sh` | app1 + app2 (2 php-fpm sur 3) | ≤ 3 s |
| `scripts/test_failover_dbproxy.sh` | dbproxy1 (1 proxy SQL sur 2) | ≤ 3 s |
| `scripts/test_failover_db.sh` | galera1, le nœud **écrivain** | ≤ 5 s |
| `scripts/test_failover_lb.sh` | lb1, le **MASTER** VRRP qui porte la VIP | ≤ 5 s |
| `scripts/test_failover_all.sh` | les 5 à la suite (≈ 6 min), arrêt si l'état nominal n'est pas retrouvé | |
| `scripts/healthcheck.sh` | contrôle de l'état nominal complet (`-q` : silencieux) | |

Paramètres : `FAULT_HOLD=20` (durée de la panne en s) et `PROBE_INTERVAL=0.2`, par exemple `FAULT_HOLD=60 scripts/test_failover_db.sh`.

## Déroulé d'un test (scripts/failover_lib.sh)
1. **Précondition** : `healthcheck.sh` doit valider l'état nominal, sinon le test est annulé sans rien toucher. L'état nominal comprend :
   - 16 conteneurs sains ;
   - Galera à 3 nœuds Synced/Primary ;
   - écrivain galera1 vu UP par les 2 dbproxy ;
   - 3 web UP sur lb1 et lb2 ;
   - VIP sur lb1 ;
   - DNS → VIP ;
   - HTTPS de bout en bout.
2. **Sonde** : `GET https://www.projet7.local/api` sur la VIP toutes les 0,2 s, avec un timeout de 2 s et le certificat **validé** par la Root CA.
   - La sonde tourne sur la VM si `p7-shim` existe ; sinon dans un conteneur sur le LAN (192.168.89.97), c'est-à-dire du même point de vue que le poste Windows.
   - Chaque réponse est enregistrée : horodatage en ms, code HTTP, LB, web, app, nœud Galera, compteur et durée.
3. 5 s de référence, puis **panne**. On mesure pendant la panne les délais de détection (LB, dbproxy, VRRP, quorum Galera).
4. Panne maintenue pendant 20 s, puis **restauration** (`docker start`), puis attente de l'**état nominal complet** (au plus 180 s), puis 8 s d'observation.
5. **Analyse** :
   - indisponibilité = temps entre la première requête en échec et la première requête réussie suivante ;
   - répartition des réponses par phase ;
   - compteur **strictement croissant** ;
   - compteur en base ≥ dernière valeur servie (aucune écriture perdue) ;
   - expectations propres au test (par exemple « pendant la panne, aucune réponse de galera1 »).
6. **Rapport horodaté** dans `docs/resultats-tests/AAAAMMJJ-HHMMSS_<test>.md`, CSV brut dans `raw/` et une ligne ajoutée à l'index `docs/resultats-tests/README.md`. Code retour 0 si toutes les vérifications passent.

## Défauts révélés par les tests, et corrections
Les premiers passages ont mis en évidence des réglages trop lents. Les rapports « avant » sont conservés dans `docs/resultats-tests/`.

| Test | Constat (avant) | Cause | Correction | Après |
|---|---|---|---|---|
| web | 1 requête perdue (2,2 s) | HAProxy attendait `timeout connect 3s` sur l'IP du conteneur mort, puis le nouvel essai retombait sur l'autre serveur mort (2 sur 3 pas encore détectés). Log : `0/1002/-1/-1/1997 CC--` | `timeout connect 500ms`, `retries 3`, `option redispatch 1` (chaque essai sur un autre serveur), `fastinter 500ms`, `observe layer4 error-limit 2` | **0 perte** |
| app | 2 requêtes perdues (2,2 s) | Même mécanisme entre nginx et php-fpm (`fastcgi_connect_timeout 2s`) | `fastcgi_connect_timeout 500ms`, pire cas 2 × 0,5 s | **0 perte** |
| db | 6,6 s, objectif non tenu | dbproxy ne détectait la panne qu'après 3 checks de 2 s (6,1 s) et continuait d'envoyer les connexions vers galera1 | dbproxy : `observe layer4 error-limit 1 on-error mark-down` (la première connexion qui échoue bascule l'écrivain), `timeout connect 500ms`, `redispatch 1`, `fastinter 500ms` ; check `--connect-timeout=1` | **4,0 s** (détection 1,7 s au lieu de 6,1 s) |

| web (série complète) | 1 requête en **502** (`SH--`) | requête déjà **en cours** sur web1 à l'instant du kill ; par défaut, HAProxy ne rejoue que les échecs de connexion | `retry-on conn-failure empty-response response-timeout` (sûr, car seules GET/HEAD sont acceptées). Compromis : une visite déjà commitée peut être comptée deux fois | **0 perte** (2 passages) |

Choix délibéré : le contrôle passif est en `layer4` et **non** en `layer7` sur le LB. En layer7, les 503 renvoyés par l'application pendant une bascule de la base retireraient **tous** les serveurs web du pool.

Corrections de l'outillage lui-même :
- la sonde perdait l'accès à son dossier, car le label SELinux privé `:Z` était repris par le conteneur de `healthcheck.sh`. Passage à `:z` (label partagé) ;
- le début de la panne est désormais horodaté **après** que le `docker kill` est effectif ;
- `deploy.sh` recrée les conteneurs nginx et dbproxy (`--force-recreate`), car un bind mount de fichier ne voit pas un fichier remplacé (nouvel inode).

## Ce qui reste incompressible
| Test | Indisponibilité | Origine | Réglage possible |
|---|---|---|---|
| db | ≈ 4 s | Galera attend `evs.suspect_timeout` (5 s) avant d'exclure le nœud muet ; les commits patientent pendant ce temps. Aucune donnée n'est perdue. | `evs.suspect_timeout=PT3S` : plus rapide, mais risque d'exclusion à tort si la VM est ralentie. Défaut conservé. |
| lb | ≈ 3,6 s | VRRP : le BACKUP déclare le MASTER mort après 3 annonces manquées plus un *skew* (`advert_int 1`), soit environ 3,6 s | VRRPv3 avec `advert_int 0.5` : environ 1,8 s, au prix de plus de trafic VRRP |

## Résultats – série complète `test_failover_all.sh` (14/11/2026 15:37 → 15:42)
Sonde : conteneur sur le LAN (point de vue du client Windows), 5 requêtes/s, certificat validé.

| Panne | Requêtes | En échec | Indisponibilité max | Détection / bascule mesurée | Retour nominal | Compteur | Verdict |
|---|---|---|---|---|---|---|---|
| web1 + web2 tués | 210 | 1 (*) | 0,2 s | LB retire les 2 web en ≈ 2-4 s | ✅ | 4096 → 4305, croissant | ✅ |
| app1 + app2 tués | 191 | 0 | **0 s** | nginx bascule sur app3 dès la première requête | ✅ | croissant | ✅ |
| dbproxy1 tué | 212 | 0 | **0 s** | l'alias `db` ne résout plus que dbproxy2 | ✅ | croissant | ✅ |
| galera1 (écrivain) tué | 210 | 2 | 4,0 s | dbproxy → galera2 en < 2 s ; quorum 2/3 ; galera1 resynchronisé par **IST** en ≈ 14 s ; 3 nœuds identiques | ✅ | croissant, **0 écriture perdue** | ✅ |
| lb1 (MASTER) tué | 217 | 3 | 3,6 s | VIP sur lb2 en ≈ 3,4 s ; reprise par lb1 (préemption) avec **0 perte** | ✅ | croissant | ✅ |

(*) Corrigé ensuite par `retry-on` : 2 nouveaux passages du test web donnent **0/207** et **0/205**.

**5/5 tests réussis.** Chaque test se termine par le retour vérifié à l'état nominal, avec VIP sur lb1 et galera1 écrivain. Détails, chronologies et CSV : `docs/resultats-tests/README.md`.

## Commandes
```bash
scripts/healthcheck.sh               # état nominal ? (code retour 0/1)
scripts/test_failover_db.sh          # un test (≈ 1 min)
scripts/test_failover_all.sh         # les 5 (≈ 6 min)
FAULT_HOLD=60 scripts/test_failover_lb.sh
```
