# Démonstration – 5 minutes chrono

> Objectif : montrer **en direct** que le site reste disponible quand on tue brutalement un composant de chaque tier, que le HTTPS est propre et qu'aucune donnée n'est perdue.
> Les temps entre crochets sont ceux mesurés lors de la répétition du 14/11/2026.

## Rôles
- **Personne A, au clavier (terminal sur la VM)** : lance `scripts/demo.sh <étape>`. Chaque étape affiche la commande réelle (`$ docker kill …`) et l'état observé.
- **Personne B, à l'oral et sur l'écran Windows** : commente ce que montrent le navigateur et la boucle PowerShell.

## Préparation (H − 15 min)

**Sur la VM**, dans un terminal récent (`unset DOCKER_HOST` si c'est un ancien terminal), avec une police agrandie :
```bash
cd ~/projet7-ha && ./scripts/demo.sh prep     # doit finir par « Plateforme dans l'état nominal »
```

**Sur Windows**, ouvrir 3 fenêtres côte à côte :
1. Le **navigateur** sur `https://www.projet7.local/?refresh=2` : cadenas valide, 6 cartes (LB, web, app, nœud Galera, heure, compteur).
2. Un onglet sur `https://www.projet7.local:8404/stats`, connecté avec `admin` et le mot de passe du `.env`.
3. **PowerShell** avec la boucle ci-dessous. C'est le témoin principal : une ligne toutes les 0,5 s, et elle continue même si une requête échoue.
   ```powershell
   while ($true) {
     try   { $r = Invoke-RestMethod https://www.projet7.local/api -TimeoutSec 2
             "{0:HH:mm:ss.f}  {1}  {2}  {3}  {4,-8} compteur {5}" -f (Get-Date), $r.lb, $r.web, $r.app, $r.db_node, $r.compteur }
     catch { Write-Host ("{0:HH:mm:ss.f}  ÉCHEC" -f (Get-Date)) -ForegroundColor Red }
     Start-Sleep -Milliseconds 500 }
   ```

Garder aussi ouverts le README (schéma Mermaid affiché) et `docs/resultats-tests/README.md`.

Si `prep` signale un problème : `./scripts/deploy.sh all`, qui est idempotent et redéploie uniquement ce qui doit l'être (≈ 1-2 min), puis relancer `prep`.

---

## Déroulé

### 0:00 – 0:30 · Le contexte (B, schéma du README)
« Un site N-tiers sans point unique de défaillance :
- 2 load balancers HAProxy qui se partagent une IP virtuelle grâce à Keepalived ;
- 3 serveurs web et 3 serveurs applicatifs ;
- 2 proxys SQL devant un cluster MariaDB Galera à 3 nœuds à réplication synchrone.

Le tout en HTTPS uniquement, avec une PKI interne, 16 conteneurs non-root et SELinux en mode Enforcing. La base n'est jamais exposée. »

### 0:30 – 1:15 · HTTPS et sécurité (B, navigateur)
- Taper `projet7.local` dans la barre d'adresse : redirection vers **`https://www.`**projet7.local. Le port 80 et l'apex sont redirigés.
- **Cadenas → certificat** : chaîne *Projet7 Root CA → intermédiaire → www.projet7.local*. Préciser : « Root CA hors ligne, intermédiaire contrainte au domaine, TLS 1.2/1.3 uniquement. »
- **F12 → Réseau → en-têtes** : `strict-transport-security`, `content-security-policy`, `x-frame-options`, ainsi que `x-lb-node`, `x-web-node` et `x-app-node`.
- Sur la page : les cartes **web, app et compteur changent à chaque rafraîchissement**. C'est la répartition de charge.

### 1:15 – 2:00 · Panne de 2 serveurs web sur 3 (A puis B)
```bash
./scripts/demo.sh web        # $ docker kill web1 web2   [DOWN sur les 2 LB en ≈ 3 s]
```
- B : « On tue 2 serveurs web sur 3, brutalement. » La boucle PowerShell **ne montre aucun ÉCHEC**, la colonne web n'affiche plus que **web3**, et la page de stats passe web1/web2 **en rouge**.
- Explication : « HAProxy vérifie chaque serveur toutes les 2 s. Une requête qui tombe sur un serveur mort est rejouée sur un autre en 0,5 s : le client ne voit rien. »
```bash
./scripts/demo.sh web-ok     # $ docker start web1 web2   [≈ 15 s, tout redevient vert]
```

### 2:00 – 3:00 · Panne du nœud de base de données qui reçoit les écritures (A puis B)
```bash
./scripts/demo.sh db         # $ docker kill galera1   [quorum 2/3 en ≈ 6 s]
```
- B : la carte **Nœud Galera passe de galera1 à galera2**, le **compteur continue de monter** et la page indique « Cluster Galera : 2 nœud(s) ».
- Dire honnêtement : « Pendant la reconfiguration du cluster, on peut voir **1 ou 2 requêtes en ÉCHEC**, soit environ 4 s mesurées. C'est le délai de détection de Galera, conservé volontairement pour éviter les fausses bascules. **Aucune écriture n'est perdue**, la réplication est synchrone. »
```bash
./scripts/demo.sh db-ok      # $ docker start galera1   [rattrapage IST ≈ 15 s, puis compteur identique sur les 3 nœuds]
```
- B : « galera1 a récupéré uniquement les transactions manquées (IST) ; les 3 nœuds ont **le même compteur**. Il redevient l'écrivain. »

### 3:00 – 3:50 · Panne du load balancer actif (A puis B)
```bash
./scripts/demo.sh lb         # $ docker kill lb1   [VIP sur lb2 en ≈ 3 s]
```
- B : la carte **Load balancer passe de lb1 à lb2**, avec 2 ou 3 lignes ÉCHEC dans PowerShell, puis tout repart. La page de stats (servie par lb1) ne répond plus, ce qui est normal ; on peut la recharger, elle est alors servie par lb2.
- Explication : « lb2 constate l'absence de 3 annonces VRRP et prend l'IP virtuelle. Le client garde la même adresse ; il n'y a rien à changer côté DNS. »
```bash
./scripts/demo.sh lb-ok      # $ docker start lb1   [lb1 reprend la VIP ≈ 15 s plus tard, sans aucune perte]
```
> Si le navigateur affiche une erreur pendant la bascule, faire **F5** : le rafraîchissement automatique s'arrête quand une page échoue. La boucle PowerShell, elle, continue toujours.

### 3:50 – 4:30 · Les preuves mesurées (A)
```bash
./scripts/healthcheck.sh     # tout est revenu à l'état nominal (≈ 2 s)
```
Puis montrer `docs/resultats-tests/README.md` : les 5 tests sont **automatisés**, avec une sonde à 5 requêtes/s, l'indisponibilité mesurée et un compteur vérifié.

| Panne | Indisponibilité |
|---|---|
| web ×2 | 0 s |
| app ×2 | 0 s |
| dbproxy | 0 s |
| Galera écrivain | 4,0 s |
| LB MASTER | 3,6 s |

Toujours **0 écriture perdue**. « Ces tests ont aussi servi à corriger la configuration : les pannes web/app sont passées de 2,2 s à 0 s. »

### 4:30 – 5:00 · Conclusion (B)
- « Chaque tier tolère la perte d'un composant ; le retour à la normale est automatique et vérifié. »
- « Sécurité : HTTPS uniquement avec HSTS, en-têtes stricts, rate limiting, secrets hors git, conteneurs non-root et en lecture seule, réseaux isolés, SELinux et firewalld actifs. »
- « Limite assumée : tout tourne sur une seule VM. En production, on répartirait les mêmes conteneurs sur 3 hôtes, sans changer l'architecture. »

---

## Plan B
| Incident | Réaction |
|---|---|
| La page ne se rafraîchit plus | F5 (la boucle PowerShell reste la référence) |
| `db-ok` dépasse 30 s | Continuer la démo ; `./scripts/demo.sh etat` à la fin montre galera1 Synced |
| Un composant ne revient pas | `./scripts/deploy.sh all` (idempotent), puis `./scripts/healthcheck.sh` |
| Pas d'accès Windows → VIP | Vérifier le fichier hosts / la règle NRPT et `Resolve-DnsName www.projet7.local` ; en dernier recours, faire la démo dans le terminal avec `./scripts/test_failover_lb.sh` (≈ 1 min) |
| Aucune démo possible | Présenter les rapports horodatés de `docs/resultats-tests/` (chronologie, mesures, CSV) |

## Questions probables du jury (réponses courtes)
- **Pourquoi pas de sticky sessions ?** L'application est sans état, tout est en base ; n'importe quel serveur peut servir n'importe quelle requête. La directive est prête en commentaire si besoin.
- **Pourquoi un seul écrivain Galera si tous les nœuds acceptent les écritures ?** Pour éviter les conflits de certification sur une ligne très sollicitée (le compteur). Les autres nœuds sont des secours immédiats.
- **Pourquoi 3 nœuds et pas 2 ?** Pour le quorum : avec 2 nœuds, la perte d'un seul bloque le cluster, pour éviter le split-brain.
- **Que se passe-t-il si les 3 nœuds Galera tombent en même temps ?** `deploy.sh db` choisit automatiquement le nœud le plus avancé (`wsrep-recover`) et reforme le cluster, sans perte. Testé avec un SIGKILL simultané des 3 nœuds.
- **Pourquoi ipvlan ?** Chaque LB a sa propre IP sur le LAN avec la MAC de la VM, sans mode promiscuité VMware, et VRRP fonctionne réellement entre deux piles réseau distinctes.
- **Comment le certificat est-il approuvé ?** La Root CA interne est importée dans le magasin Windows, après vérification de son empreinte SHA-256. Avec un domaine public, on utiliserait Let's Encrypt (défi DNS-01).
