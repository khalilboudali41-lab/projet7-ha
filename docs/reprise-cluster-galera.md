# Reprise du cluster Galera – incident du 15/11/2026 (VM1, version mono-VM)

> Heures en **heure locale (CET, UTC+1)**. Les journaux centralisés (`logs/galeraN.log`)
> sont horodatés en UTC : 17:51Z = 18:51 locale.

## 1. Résumé

| | |
|---|---|
| Symptôme | galera1/2/3 en boucle de redémarrage (66 à 70 redémarrages chacun), `failed to reach primary view` (110, délai dépassé) → `Aborting`. Base de données indisponible, page en 503. |
| Durée | de 18:51 (démarrage de VM1) à 19:30 (reprise) – environ 40 min |
| Cause | les 3 nœuds se sont arrêtés **en même temps, sans sortie propre de Galera**, lors de l'extinction de VM1 pour le clonage de VM2 (18:41). Au redémarrage, aucun nœud n'était désigné pour refonder le cluster. |
| Données | **aucune perte**. Les 3 nœuds avaient des données identiques : compteur 5570, 5570 visites, dernière visite le 14/11 à 15:56:58.877. |
| Reprise | arrêt de la boucle, copie à froid des 3 volumes, `scripts/deploy.sh db` (bootstrap de galera1). |

## 2. Chronologie

| Heure | Événement | Source |
|---|---|---|
| 14/11 15:56:58 | Dernière visite enregistrée (fin des tests et de la démo) | `vitrine.visites` |
| 14/11 (après) | La session démarrée le 14/11 à 12:40 se termine **sans arrêt propre** (`crash`) | `last -x` |
| 15/11 18:37:37 | Démarrage de VM1. Les nœuds trouvent `cbd78a8a-e028-11f1-97bb-aefd4b5a4acb:-1` et `gvwstate.dat` : **`restore pc from disk successfully`**. Le composant primaire est reformé seul (`pc.recovery`). | `logs/galera1.log` |
| 18:37:38 | `Quorum: No node with complete state` : le composant est reformé, mais aucun nœud ne détient un état Galera complet. | `docker logs galera2` |
| 18:37:40 | Les 3 nœuds sont `Synced` | `logs/galera*.log` |
| 18:41:14 | Début de l'extinction de VM1 (pour le clonage). Chaque nœud se retrouve seul (`NON_PRIM`, `memb_num = 1`). | `docker logs galera2/3` |
| 18:41:15 | Vue `PRIM` 3/3, à nouveau `No node with complete state` | `docker logs galera2/3` |
| 18:41:17 | **Dernière ligne écrite par les 3 nœuds.** Aucune ligne `Normal shutdown` ni `Shutdown complete` : aucun nœud n'est sorti proprement. | `docker logs galera2/3` |
| 18:41 → 18:50 | VM1 éteinte. **VM2 est clonée pendant cet intervalle** : son historique `last -x` est identique à celui de VM1 jusqu'à 18:41, puis elle démarre seule à 18:51. | `last -x` sur VM1 et VM2 |
| 18:51:02 | Démarrage de VM1. Les 3 nœuds trouvent `00000000-0000-0000-0000-000000000000:-1`, `safe_to_bootstrap: 0`, **pas de `gvwstate.dat`** → `restore pc from disk failed` | `logs/galera*.log` |
| 18:51:32 | Premier `failed to reach primary view` → `Aborting` → Docker redémarre le conteneur (`unless-stopped`). La boucle dure ensuite 30 s par tour. | `logs/galera*.log` |
| 19:29:53 | Arrêt de la boucle (`docker compose stop`), puis copie à froid des 3 volumes | – |
| 19:30–19:31 | `scripts/deploy.sh db` : bootstrap de galera1, jonction de galera2 et galera3, recréation des dbproxy | sortie du script |
| 19:31:54 | Première visite après la reprise (compteur 5571, web3 → app2 → galera1) | `vitrine.visites` |

## 3. Cause

1. **Galera ne refonde jamais seul un cluster entièrement arrêté.** Il faut qu'un nœud
   démarre avec `--wsrep-new-cluster`. Il existe une exception : la reprise automatique
   `pc.recovery`, qui exige le fichier `gvwstate.dat`. Ce fichier n'est présent que si les
   nœuds faisaient partie d'un composant primaire au moment de l'arrêt.
2. **À 18:37,** cette exception a joué : `gvwstate.dat` était présent, laissé par l'arrêt
   brutal de la session du 14/11, et le cluster s'est reformé seul. Mais il s'est reformé
   **sans état Galera complet** (`No node with complete state`). À partir de là, la position
   enregistrée par les nœuds est `00000000…:1` : l'historique `cbd78a8a…` est perdu, même si
   les données InnoDB restent identiques.
3. **À 18:41,** l'extinction de VM1 a arrêté les 3 nœuds **simultanément**. Aucun d'eux n'a
   été le « dernier à partir », donc aucun n'a écrit `safe_to_bootstrap: 1`, et
   `gvwstate.dat` n'a pas été conservé.
4. **À 18:51,** il n'y avait plus aucun moyen automatique de repartir : ni `safe_to_bootstrap`
   ni `gvwstate.dat`. La politique `restart: unless-stopped` relançait les nœuds sans fin.
   C'est le comportement **attendu et sûr** de Galera : démarrer un nœud en fondateur sans
   savoir qu'il est le plus à jour risquerait de perdre des transactions, ou de créer deux
   clusters divergents.

## 4. Positions des nœuds (`--wsrep-recover`)

Le `--wsrep-recover` a été relancé **sur les copies à froid de 19:29:53**, restaurées dans des
volumes temporaires. Il est impossible de le relancer sur les volumes actuels : le cluster
tourne, et ces volumes ne reflètent plus l'état d'avant la reprise. Ces copies représentent
exactement ce que `deploy.sh` a vu.

| Nœud | `grastate.dat` | Position récupérée | LSN InnoDB | Id de transaction | Compteur | Visites (`max id`) | `test_failover` |
|---|---|---|---|---|---|---|---|
| galera1 | `0000…:-1`, safe 0 | `00000000-0000-0000-0000-000000000000:1` | 2812166 | 10955 | 5570 | 5570 (16471) | 39 |
| galera2 | `0000…:-1`, safe 0 | `00000000-0000-0000-0000-000000000000:1` | 2812161 | 10946 | 5570 | 5570 (16471) | 39 |
| galera3 | `0000…:-1`, safe 0 | `00000000-0000-0000-0000-000000000000:1` | 2811599 | 10950 | 5570 | 5570 (16471) | 39 |

Les LSN et les identifiants de transaction sont propres à chaque nœud, car chaque InnoDB écrit
son propre journal. **Ils ne servent pas à départager des nœuds Galera.** La comparaison
des données applicatives, elle, est probante.

## 5. Choix du fondateur

Règle de `scripts/deploy.sh` (`galera_up`) :

1. Un nœud porte `safe_to_bootstrap: 1` → c'est le fondateur. **Ici : aucun.**
2. Sinon, le nœud au `seqno` récupéré le plus élevé. **Ici : égalité, les trois sont à 1.**
3. En cas d'égalité, la boucle garde le premier de la liste → **galera1**.

**galera1 a donc été choisi par ordre de liste, pas sur une preuve.** Le choix est validé
*a posteriori* : les données des trois copies sont identiques (§4), donc aucune transaction
n'a été perdue. Ce ne serait pas forcément le cas lors d'un autre incident.

**Correctif à intégrer dans `deploy-multi.sh` (P5) :** en cas d'égalité de `seqno` ou de
position à UUID nul, le script devra s'arrêter, afficher l'état de chaque nœud et demander
qu'on désigne explicitement le fondateur (`--bootstrap galeraN`), au lieu de choisir en
silence.

## 6. Procédure de reprise (cluster entièrement arrêté)

Toutes les commandes se lancent **sans sudo**, depuis `~/projet7-ha` sur VM1, version mono-VM.
La procédure multi-VM sera documentée avec `deploy-multi.sh`.

```bash
# 1. Arrêter la boucle de redémarrage. Sans cet arrêt, les nœuds réécrivent
#    grastate.dat à chaque tour, et deploy.sh refuse d'agir sur des nœuds lancés.
docker compose stop galera1 galera2 galera3
docker ps -a --filter name=galera --format '{{.Names}} {{.Status}}'   # → Exited

# 2. Copie à froid des volumes (filet de sécurité avant toute écriture)
ts=$(date +%Y%m%d-%H%M%S)
for n in 1 2 3; do
  docker run --rm --network none -v projet7_galera${n}_data:/src:ro alpine:3.24.4 \
    tar czf - -C /src . > backups/galera${n}-vol-$ts.tgz
done
chmod 600 backups/galera*-vol-$ts.tgz

# 3. État enregistré par chaque nœud
for n in 1 2 3; do
  docker run --rm --network none -v projet7_galera${n}_data:/d:ro --entrypoint cat \
    mariadb:11.4.13-noble /d/grastate.dat
done

# 4. Si aucun safe_to_bootstrap: 1 → position réelle de chaque nœud
for n in 1 2 3; do
  echo "== galera$n"
  docker run --rm --network none -v projet7_galera${n}_data:/var/lib/mysql \
    -v "$PWD/db/conf/galera.cnf:/etc/mysql/conf.d/60-projet7-galera.cnf:ro,z" \
    mariadb:11.4.13-noble mariadbd --user=mysql --wsrep-recover 2>&1 | grep 'Recovered position'
done

# 5. EN CAS D'ÉGALITÉ : comparer les données sur une COPIE (jamais sur le volume réel)
n=1; docker volume create p7-recover-galera$n
docker run --rm -i --network none -v p7-recover-galera$n:/dst alpine:3.24.4 \
  tar xzf - -C /dst < backups/galera$n-vol-$ts.tgz
docker run --rm --network none -v p7-recover-galera$n:/var/lib/mysql --entrypoint bash \
  mariadb:11.4.13-noble -c 'gosu mysql mariadbd --wsrep_on=OFF --skip-networking --skip-grant-tables &
    for i in $(seq 30); do mariadb -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
    mariadb -N -e "SELECT valeur FROM vitrine.compteur; SELECT COUNT(*), MAX(id), MAX(horodatage) FROM vitrine.visites"'
docker volume rm p7-recover-galera$n          # répéter pour chaque nœud

# 6. Reprise : bootstrap du nœud choisi, jonction des autres (IST/SST),
#    puis redémarrage du fondateur en membre ordinaire
scripts/deploy.sh db
#    Pour forcer un fondateur précis plutôt que le choix automatique :
#    GALERA2_BOOTSTRAP=1 docker compose up -d galera2   (puis les autres, puis recréer galera2)

# 7. Vérification
docker exec galera2 sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" -N -e \
  "SHOW STATUS WHERE Variable_name IN (\"wsrep_cluster_size\",\"wsrep_cluster_status\",\"wsrep_local_state_comment\");
   SELECT valeur FROM vitrine.compteur"'
```

Résultat du 15/11 à 19:31 : `wsrep_cluster_size 3`, `Primary`, `Synced`. La page répond en
HTTP 200 via la VIP depuis VM3, et le compteur passe de 5570 à 5571.

## 7. Enseignements pour la version multi-VM

- **Éteindre une VM qui héberge tous les nœuds fait tomber tout le cluster.** C'est précisément
  ce que la répartition galera1 (VM1), galera2 (VM2) et garbd (VM3) supprime : il reste un
  quorum de 2 votes sur 3 quand une VM s'éteint.
- **L'arrêt des deux VMs reste un cas de reprise manuelle.** Le bootstrap ne doit jamais être
  automatique : s'il l'était, chaque VM pourrait refonder son propre cluster, et on aurait
  deux bases divergentes.
- **`deploy-multi.sh` ne doit jamais choisir en silence en cas d'égalité** (§5).
- **Le collecteur de journaux s'arrête en même temps que la VM.** Les dernières secondes avant
  l'arrêt ne sont donc pas dans `logs/` : elles n'ont été retrouvées que dans `docker logs`
  des conteneurs qui n'avaient pas été recréés.
