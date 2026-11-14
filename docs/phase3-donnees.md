# Phase 3 – Tier données (2026-11-14)

## Architecture

```
      app (phase 4) ──► alias DNS « db » (db_net)
                         ├── dbproxy1 172.30.30.21  HAProxy 3.2.26 + check Galera
                         └── dbproxy2 172.30.30.22  (même règle → même écrivain)
                                  │ écrivain unique, secours ordonnés
              ┌───────────────────┼───────────────────┐
         galera1 .11          galera2 .12          galera3 .13
         (écrivain)           (secours 1)          (secours 2, sauvegardes)
              └──── réplication synchrone Galera 4 (wsrep) ────┘
         db-backup .31 : mariadb-dump planifié → ./backups (600)

db_net 172.30.30.0/24 : internal (pas de sortie), gateway_mode isolated (aucune IP hôte)
```

| Élément | Choix | Justification |
|---|---|---|
| SGBD | MariaDB 11.4.13 LTS + Galera 4 (`mariadb:11.4.13-noble`) | Multi-maître synchrone : chaque transaction validée est présente sur les 3 nœuds (RPO = 0), bascule sans promotion manuelle (contrairement à primaire/réplique) |
| 3 nœuds | quorum | 1 panne tolérée sans perte du composant primaire ; 2 nœuds = split-brain à la moindre coupure |
| SST | `mariabackup` | Transfert complet sans bloquer le donneur ; IST (incrémental, gcache 128 Mo) pour une absence courte |
| Proxy SQL | HAProxy ×2 en TCP, alias DNS `db` | Pas de SPOF : Docker DNS retire un proxy arrêté. Écrivain unique (galera1, puis galera2, puis galera3) pour éviter les conflits de certification |
| Check | script `galera-check.sh` (`external-check`) | Un nœud n'est UP que s'il est **Synced + Primary + ready**, pas seulement joignable en TCP |
| Bootstrap | `deploy.sh` : `safe_to_bootstrap` → sinon `wsrep-recover` (seqno max) | Reprise automatique après arrêt propre **ou crash total** ; le fondateur est ensuite recréé sans `--wsrep-new-cluster` (pas de 2e cluster possible) |
| Sauvegarde | `mariadb-dump --single-transaction` toutes les 6 h depuis un nœud de secours, rétention 7 j, SHA-256 | Instantané cohérent sans verrou ; comptes inclus (`--system=users`) ; restauration idempotente |

## Sécurité
| Mesure | Mise en œuvre |
|---|---|
| Secrets | `.env` (600, non versionné) → `secrets/` (700, label SELinux `container_file_t`) → `/run/secrets` en lecture seule. Aucun mot de passe en variable d'environnement, ni en ligne de commande, ni dans `docker inspect` |
| Comptes | `vitrine` (DML sur `vitrine.*`, depuis db_net seulement), `monitor` (USAGE), `backup` (lecture), `mariabackup` (local), `root` **localhost uniquement** |
| Réseau | aucun port publié ; `internal: true` (pas de sortie Internet) ; `gateway_mode_ipv4: isolated` (injoignable même depuis la VM) |
| Conteneurs | `cap_drop: ALL` (+5 capacités pour la bascule root→mysql de l'entrypoint Galera), `no-new-privileges`, `read_only` pour dbproxy et backup, limites mémoire |
| Processus | mariadbd en uid 999 (mysql), haproxy en uid 99, backup en uid 1000 ; labels SELinux `container_t` avec catégories MCS distinctes par conteneur |

## Résultats des tests
| Test | Résultat |
|---|---|
| Écriture via dbproxy, lecture sur les 3 nœuds | ✅ identique partout |
| Moindre privilège : `DROP` / lecture `mysql.user` par `vitrine`, `root` à distance | ✅ refusés (1142, 1142, 1045) |
| Isolation : ports publiés / hôte → 3306 / conteneur → Internet | ✅ aucun / injoignable / bloqué |
| Redémarrage tournant des 3 nœuds sous écriture continue (1/s) | ✅ 59/60 écritures OK (1 coupure au redémarrage de l'écrivain) |
| Arrêt de l'écrivain galera1 sous charge (2 écritures/s) | ✅ bascule vers galera2, **38/38 écritures confirmées présentes sur les 3 nœuds**, 2 échecs pendant la détection (~2-4 s), retour de galera1 par IST |
| Crash simultané SIGKILL des 3 nœuds (seqno −1 partout) | ✅ `wsrep-recover` → seqno 48 → bootstrap → cluster reformé, **aucune perte** |
| Sauvegarde + restauration dans une instance jetable (2 imports successifs) | ✅ 250 visites, compteur, 5 comptes ; import idempotent |
| Mémoire | ~125 Mo par nœud Galera, ~13 Mo par dbproxy |

## Problèmes rencontrés et corrections
1. **`01-users.sh` exécutable** → l'entrypoint l'exécute au lieu de le sourcer (`docker_process_sql: command not found`) ; comptes non créés. Corrigé : fichier en 644 (commentaire en tête).
2. **Collation** : forcer `utf8mb4_unicode_ci` figeait cette collation dans les vues système (`mysql.user`) → `mariadb-dump --system=users` en échec (*Illegal mix of collations*). Corrigé : collation par défaut de la 11.4 (`utf8mb4_uca1400_ai_ci`) et réinitialisation du cluster (données de test uniquement).
3. `mariadb-dump` n'accepte pas `--connect-timeout` (option du client) → options séparées.
4. Dumps de comptes non idempotents (`CREATE USER` sur `mariadb.sys`) → `--insert-ignore` (`CREATE USER IF NOT EXISTS`) ; dumps en 600 (empreintes de mots de passe).
5. Bridge de db_net joignable depuis l'hôte (172.30.30.1) → `gateway_mode_ipv4: isolated`.
6. Avertissements sans impact : `io_uring` désactivé par RHEL (InnoDB repasse en AIO classique), `memory.pressure` non accessible en cgroup v2 non privilégié.

## Commandes
```bash
scripts/deploy.sh db         # déploie / reprend le tier données (idempotent)
scripts/deploy.sh status     # conteneurs, état wsrep, écrivain vu par chaque dbproxy
scripts/backup_db.sh now|list|verify|restore <fichier>
```
