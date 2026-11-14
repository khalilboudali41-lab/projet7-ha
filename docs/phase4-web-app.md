# Phase 4 – Tiers web et application (2026-11-14)

## Architecture

```
 (HAProxy, phase 5) ──► front_net 172.30.10.0/24 (internal, isolated)
                        web1 .11   web2 .12   web3 .13      nginx 1.30.6 (uid 101, RO)
                           └──────────┼──────────┘  upstream : 3 php-fpm, next_upstream
                        app_net 172.30.20.0/24 (internal, isolated)
                        app1 .11   app2 .12   app3 .13      php-fpm 8.4.27 (uid 82, RO)
                           └──────────┼──────────┘  PDO → alias « db »
                        db_net 172.30.30.0/24 → dbproxy1/2 → Galera ×3
```

| Choix | Justification |
|---|---|
| Web et app séparés (3 + 3 conteneurs) | Vrai N-tiers : chaque nginx répartit sur les 3 php-fpm → on peut perdre 2 web **ou** 2 app. Le web n'a aucun accès à la base (pas sur db_net). |
| Application sans état | Aucune session PHP : tout l'état est en base → **pas besoin de sticky sessions**, n'importe quel couple web/app sert n'importe quelle requête. |
| Code dans l'image (`projet7/vitrine-app:1.0`) | Les 3 conteneurs sont strictement identiques et immuables ; `opcache.validate_timestamps=0`. |
| Réessai SQL (1 fois, 300 ms) | Masque la fenêtre de détection d'une bascule de l'écrivain Galera (2-4 s mesurés en phase 3). |
| `/healthz` (web + php-fpm) / `/healthz/db` (chaîne complète) | HAProxy vérifiera `/healthz` : une panne DB ne doit pas retirer tous les serveurs web du pool (la page affiche alors une erreur 503 explicite). |

## Application « vitrine HA »
- `/` : serveur web, serveur app, nœud Galera, heure serveur, compteur en base, état du cluster, 8 dernières requêtes ; `/?refresh=2` pour la démo.
- `/api` : la même chose en JSON (utilisé par les scripts de test).
- Compteur : `UPDATE … SET valeur = LAST_INSERT_ID(valeur+1)` + `INSERT INTO visites` dans **une transaction** ; requêtes préparées, sortie échappée (`htmlspecialchars`), CSS servi en fichier (compatible CSP sans `unsafe-inline`).

## Durcissement
| Couche | Mesures |
|---|---|
| nginx | non-root (101), `read_only` + tmpfs /tmp, `server_tokens off`, GET/HEAD seulement (`limit_except`), corps ≤ 64 Ko, timeouts courts, IP réelle crue uniquement depuis front_net |
| php-fpm | non-root (82), `read_only`, `listen.allowed_clients` = les 3 nginx, `clear_env`, `expose_php`/`allow_url_fopen`/`file_uploads` désactivés, `disable_functions` (exec, system…), `open_basedir` |
| Conteneurs | `cap_drop: ALL`, `no-new-privileges`, limites mémoire, aucun port publié, réseaux `internal` + `gateway_mode isolated` |

## Résultats des tests (client sur front_net, à la place de HAProxy)
| Test | Résultat |
|---|---|
| `/api` sur web1, web2, web3 | ✅ 200, compteur incrémenté, `db_node=galera1`, cluster `3 · Primary / Synced` |
| Répartition web1 → app (30 requêtes) | ✅ app1 14, app2 8, app3 8 |
| **app1 + app2 arrêtés** | ✅ 20/20 requêtes OK, toutes servies par app3 |
| **web1 + web2 arrêtés** | ✅ web3 répond (les 2 autres en timeout → HAProxy les retirera en phase 5) |
| POST / traversée de chemin / `/index.php` | ✅ 403 / 400 / 404 |
| Isolation : ports publiés, app → Internet, web → base | ✅ aucun / bloqué / injoignable |
| Conteneur intrus sur app_net → php-fpm | ✅ refusé (`Connection disallowed: IP address '172.30.20.1' has been dropped`) |
| Utilisateurs / rootfs | ✅ nginx uid 101, php-fpm uid 82, écriture refusée (*Read-only file system*) |
| Mémoire | ~7 Mo par nginx, ~11 Mo par php-fpm |

## Commandes
```bash
scripts/deploy.sh web      # construit l'image app et (re)déploie app1-3 puis web1-3
scripts/deploy.sh status
```
