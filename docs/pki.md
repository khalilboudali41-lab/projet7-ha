# PKI interne – Projet 7

## 1. Architecture

```
Projet7 Root CA                RSA 4096 · SHA-384 · 10 ans · clé HORS LIGNE
└── Projet7 Intermediate CA    RSA 4096 · SHA-384 · 5 ans · pathlen:0
    │                          nameConstraints: permitted DNS:projet7.local
    └── www.projet7.local      ECDSA P-256 · SHA-256 · 397 jours
                               SAN: www.projet7.local, projet7.local · EKU serverAuth
```

| Choix | Justification |
|---|---|
| 2 niveaux (racine + intermédiaire) | La racine ne sert qu'à signer l'intermédiaire puis est mise hors ligne. Une compromission de l'intermédiaire (clé en ligne) se corrige en la révoquant et en en signant une nouvelle, **sans redéployer la racine sur les clients**. |
| `pathlen:0` | L'intermédiaire ne peut pas créer de sous-CA. |
| `nameConstraints` sur l'intermédiaire | Même volée, sa clé ne permet pas de forger un certificat pour un autre domaine (ex. google.com) : vérifié, `permitted subtree violation`. Limite le risque d'importer notre racine dans le magasin de confiance du client. |
| ECDSA P-256 côté serveur | Poignée de main plus rapide que RSA, supporté par tous les clients TLS 1.2/1.3. |
| 397 jours | Durée maximale acceptée par les navigateurs (règle CA/B Forum, ≤ 398 j). |
| Clés CA chiffrées (AES-256) | Phrases de passe aléatoires de 32 octets dans `*/private/*.pass` (600). |
| `copy_extensions = none` | Les SAN sont imposés par la CA, jamais repris de la CSR. |

## 2. Fichiers

| Fichier | Usage | Versionné |
|---|---|---|
| `pki/root-ca/certs/root-ca.crt` (PEM) / `root-ca.cer` (DER) | **à importer chez le client** | oui |
| `pki/intermediate/certs/intermediate.crt`, `ca-chain.crt` | chaîne | oui |
| `pki/server/www.projet7.local/fullchain.crt` | serveur + intermédiaire | oui |
| `pki/server/www.projet7.local/private/haproxy.pem` | chaîne + clé, monté dans HAProxy | **non** |
| `pki/*/private/*.key`, `*.pass` | clés et phrases de passe | **non** |
| `pki/*/db/`, `newcerts/`, `crl/` | base `openssl ca` (traçabilité, révocations) | oui |

## 3. Commandes

```bash
scripts/pki.sh all                    # init + émission + contrôles (idempotent)
scripts/pki.sh verify                 # 11 contrôles automatiques
scripts/pki.sh server www.projet7.local www.projet7.local projet7.local   # réémission
scripts/pki.sh offline                # met la clé Root hors ligne
scripts/pki.sh restore-root <archive.enc>                                # la remet (renouvellement)
```

Contrôle manuel d'une poignée de main (validation stricte avec la seule racine) :
```bash
openssl s_client -connect 192.168.89.100:443 -servername www.projet7.local \
  -verify_hostname www.projet7.local -CAfile pki/root-ca/certs/root-ca.crt -verify_return_error </dev/null
```

## 4. Mise hors ligne de la Root CA

La clé Root ne doit plus résider sur la VM une fois l'intermédiaire signée.

```bash
scripts/pki.sh offline
```
1. crée `pki/offline/root-ca-key-<date>.tar.gz.enc` : `tar` de la clé et de sa phrase de passe, chiffré AES-256-CBC + PBKDF2 (600 000 itérations) avec une phrase de passe **que tu choisis** ;
2. vérifie que l'archive se déchiffre (sinon rien n'est effacé) ;
3. efface la clé de la VM (`shred -u`).

Ensuite : copier l'archive sur un support hors ligne (clé USB, coffre), noter la phrase de passe dans un gestionnaire de mots de passe, puis `shred -u` l'archive sur la VM.
Elle ne sert qu'à renouveler/révoquer l'intermédiaire (tous les 5 ans) : `scripts/pki.sh restore-root`, opération, puis `offline` à nouveau.

## 5. Import de la Root CA sur le client Windows

**Empreinte SHA-256 attendue** (à comparer avant import) :
`E9:C5:4A:C6:38:EA:4D:02:AA:DB:35:1B:FF:FD:0F:47:12:DE:69:24:58:C0:0B:8A:9F:71:15:5D:AD:23:A4:EA`

### 5.1 Récupérer le certificat (PowerShell sur l'hôte Windows, client OpenSSH intégré)
```powershell
scp dr-khalil@192.168.89.136:projet7-ha/pki/root-ca/certs/root-ca.cer $env:USERPROFILE\Downloads\
certutil -hashfile $env:USERPROFILE\Downloads\root-ca.cer SHA256   # doit correspondre à l'empreinte ci-dessus
```

### 5.2 Importer dans le magasin Windows (utilisé par Edge et Chrome)
PowerShell **en administrateur** (tous les utilisateurs du PC) :
```powershell
Import-Certificate -FilePath $env:USERPROFILE\Downloads\root-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Projet7*'
```
Équivalents : `certutil -addstore -f Root root-ca.cer` (admin) ; pour l'utilisateur courant seulement : `certutil -user -addstore Root root-ca.cer`.
Interface graphique : `certlm.msc` → *Autorités de certification racines de confiance* → *Certificats* → clic droit → *Toutes les tâches* → *Importer…*.

### 5.3 Firefox
Firefox a son propre magasin. Au choix :
- `about:config` → `security.enterprise_roots.enabled` = `true` (Firefox reprend alors les racines Windows) ;
- ou *Paramètres → Vie privée et sécurité → Certificats → Afficher les certificats → Autorités → Importer…* → cocher « Confirmer cette AC pour identifier des sites web ».

Redémarrer le navigateur. Le cadenas doit afficher « Vérifié par : Projet7 HA ».

### 5.4 Retrait après le projet
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Projet7 Root CA*' | Remove-Item
```

## 6. Variante Let's Encrypt (domaine public)

`.local` est un domaine réservé (mDNS) : aucune CA publique ne peut le certifier. La variante suppose un vrai domaine (ex. `www.exemple.fr`) dont on contrôle le DNS.

| Défi ACME | Condition | Adapté ici |
|---|---|---|
| HTTP-01 | port 80 de la VIP joignable depuis Internet (redirection NAT/box vers 192.168.89.100) | si exposition publique |
| **DNS-01** | API du fournisseur DNS (plugin certbot) | **recommandé** : aucune ouverture de port, VM pouvant rester privée |

**DNS-01** (exemple OVH, image officielle à version fixée) :
```bash
docker run --rm -v "$PWD/letsencrypt:/etc/letsencrypt:Z" -v "$PWD/secrets/ovh.ini:/ovh.ini:ro,Z" \
  certbot/dns-ovh:<version> certonly --dns-ovh --dns-ovh-credentials /ovh.ini \
  -d www.exemple.fr -d exemple.fr --agree-tos -m <email> --non-interactive
```
**HTTP-01** : HAProxy route `/.well-known/acme-challenge/` (avant la redirection HTTPS) vers un conteneur `certbot certonly --standalone --http-01-port 8888` présent sur le réseau front.

Déploiement dans HAProxy (hook `--deploy-hook`, exécuté à chaque renouvellement) :
```bash
cat "$RENEWED_LINEAGE/fullchain.pem" "$RENEWED_LINEAGE/privkey.pem" > pki/server/<domaine>/private/haproxy.pem
docker kill -s USR2 lb1 lb2      # rechargement à chaud de HAProxy (master-worker), sans coupure
```
Renouvellement : `certbot renew` quotidien (timer systemd) ; les certificats Let's Encrypt durent 90 jours (vers une réduction progressive), d'où l'automatisation obligatoire. Le reste de l'architecture (HSTS, TLS 1.2/1.3) est inchangé.
