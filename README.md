# Netfeeds Sync - MikroTik RouterOS whitelist automation

Ce projet permet de maintenir à jour des listes blanches (whitelists) dynamiques de pare-feu sur un routeur MikroTik RouterOS v7.
Puisque le but est d'avoir une politique par défaut extrêmement restrictive (où seul le trafic légitime en provenance d'infrastructures de confiance comme Cloudflare et Plex est autorisé, et tout le reste est bloqué), nous utilisons GitHub Actions comme source de vérité et un automate afin d'alimenter le routeur de façon sécurisée et déterministe.

## Sommaire

1. [Vue d'ensemble de l'architecture](#vue-densemble-de-larchitecture)
2. [Automatisation avec GitHub Actions](#automatisation-avec-github-actions)
3. [Configuration du Routeur MikroTik (Script)](#configuration-du-routeur-mikrotik-script)
4. [Configuration du Pare-feu de façon sécurisée](#configuration-du-pare-feu-de-façon-sécurisée)
5. [Dépannage & Retours d'erreur](#dépannage--retours-derreur)
6. [Considérations de Sécurité](#considérations-de-sécurité)

---

## Vue d'ensemble de l'architecture

Le fonctionnement repose sur une structure simple mais très robuste :
- Un script d'automatisation tourne via **GitHub Actions** pour rapatrier, vérifier, nettoyer et normaliser les adresses IP officielles de Plex et Cloudflare.
- Ce script commit ses changements dans ce même dépôt uniquement si de nouvelles lignes apparaissent (ou des anciennes disparaissent).
- Le routeur MikroTik, configuré avec son propre planificateur HTTP (scheduler), télécharge périodiquement les fichiers bruts (Raw URLs depuis GitHub).
- Le routeur intègre intelligemment les différences (Differential Update) : il **ajoute seulement** les IPs manquantes et **supprime seulement** les IPs qui n'existent plus, sans relâcher la sécurité, et ce, sans jamais toucher aux IPs entrées manuellement.

---

## Automatisation avec GitHub Actions

La pipeline CI/CD est définie dans `.github/workflows/update-lists.yml`.

### Fonctionnalités de la Pipeline :
* **Déclenchement** : Automatique toutes les 6 heures (via cron) et manuel (via workflow_dispatch).
* **Récupération conditionnelle** : Utilise l'option cURL ETag et `If-Modified-Since` pour économiser la bande passante si le fichier n'a pas été mis à jour en amont.
* **Normalisation (cleanups)** : Le script `scripts/update_lists.sh` fait un nettoyage : il élimine les lignes vides, dé-doublonne et trie les adresses.
* **Commit conditionnel** : Git ajoute un nouveau commit seulement si le contenu change (via `git diff`). La validation est effectuée par l'identité d'un bot GitHub standard `github-actions[bot]`.

---

## Configuration du Routeur MikroTik (Script)

Un script RouterOS très robuste (`routeros/update-whitelists.rsc`) s'exécute localement sur votre routeur.

### Étapes d'installation

1. **Ajustez le lien du script :**
   Dans le fichier `update-whitelists.rsc`, changez la variable `repoUrl` pour qu'elle corresponde à l'adresse **Raw** de ce dépôt sur GitHub.

2. **Créez le script :**
   Allez dans le terminal MikroTik, sous `/system script` :
   ```routeros
   /system script add name="update-whitelists" dont-require-permissions=no policy=read,write,test source=[Le Contenu de update-whitelists.rsc]
   ```

3. **Ajoutez un Scheduler (Planificateur) :**
   Ce cron local téléchargera et vérifiera nos whitelists automatiquement toutes les 6 heures :
   ```routeros
   /system scheduler add name="update-whitelists-job" interval=6h on-event="update-whitelists" start-time=startup comment="Update firewall whitelists every 6 hours"
   ```

### Mécanismes Anti-Verrouillage (Anti-Lockout)
- Le script télécharge d'abord le fichier de whitelists, mais *ne vide jamais* la `address-list` originale.
- Il s'assure que la liste obtenue par HTTP n'est pas vide et contient en effet un nombre **minimum vital de lignes** (ex: 1 pour Plex, 10 pour Cloudflare IPv4). S'il y a un souci, le run entier est abandonné, prévenant ainsi que tout le monde ne se fasse expulser de son propre serveur.
- Chaque nouvelle IP reçoit un commentaire structure ("tag") spécifique : `auto:cloudflare-v4`, etc. Seules les IP taggées par lui-même seront potentiellement mises à jour ou supprimées, de façon à respecter des IPs que vous auriez écrites manuellement pour ces mêmes whitelists.

---

## Configuration du Pare-feu de façon sécurisée

L'architecture est "Drop Tous par Défaut". Assurez-vous d'implémenter les règles dans cet ordre strict.
Toute mauvaise configuration risquerait de bloquer votre accès WinBox ou SSH. **Testez via Safe Mode**.

### Règles recommandées (IPv4 via terminal) :
```routeros
/ip firewall filter
# 1. Toujours accepter l'existant, le relié et non-tracké
add action=accept chain=input connection-state=established,related,untracked comment="Allow established/related"

# 2. Supprimer tout trafic mal formé
add action=drop chain=input connection-state=invalid comment="Drop invalid packets"

# 3. /!\ ACCES LOCAL (A adapter a votre propre réseau local !) /!\
add action=accept chain=input src-address=192.168.88.0/24 comment="Allow LAN Management access"

# 4. Whitelists
add action=accept chain=input src-address-list=plex protocol=tcp dst-port=32400 comment="Allow Plex Infrastructure"
add action=accept chain=input src-address-list=cloudflare comment="Allow Cloudflare Infrastruture"

# 5. Règle finale (Bloquer le reste)
add action=drop chain=input log=yes log-prefix="Drop-Input-Auto" comment="Drop tout autre trafic"
```

### Règles recommandées (IPv6 via terminal) :
```routeros
/ipv6 firewall filter
add action=accept chain=input connection-state=established,related,untracked comment="Allow established/related IPv6"
add action=drop chain=input connection-state=invalid comment="Drop invalid IPv6"

# Le "localhost" de l'IPv6 est extremement critique
add action=accept chain=input src-address=fe80::/10 comment="Allow IPv6 Link-Local (MANDATORY)"
add action=accept chain=input protocol=icmpv6 comment="Allow ICMPv6"

# Whitelists
add action=accept chain=input src-address-list=plex protocol=tcp dst-port=32400 comment="Allow Plex IPv6"
add action=accept chain=input src-address-list=cloudflare comment="Allow Cloudflare IPv6"

# Règle finale
add action=drop chain=input log=yes log-prefix="Drop-Input-v6-Auto" comment="Drop tout autre trafic IPv6"
```

---

## Dépannage & Retours d'erreur

Si les IPs ne se mettent pas à jour :
* Ouvrez vos **Logs RouterOS**. Le script a été configuré avec un excellent système de traçabilité.
* Vérifiez les erreurs `Validation en echec pour ...: recu X IPs, minimum requis Y`. Si GitHub Raw limite votre IP ou a un problème de latence, les lignes peuvent ne pas matcher la base minimum, et le script arrêtera la mise à jour par précaution.
* L'absence de certificat Root sur RouterOS v7 : `tool fetch` requiert que les certificats HTTPS racine (DigiCert, Let's Encrypt etc) soient présents physiquement dans `System > Certificates`. Sinon, importez `cacert.pem`.

---

## Considérations de Sécurité

1. **La branche main de ce repo est en clair, si le dépôt est public**. Assurez-vous que ces fichiers `.txt` de whitelists ne révèlent  aucune infrastructure ultra-privée autre que les IPs de Cloudflare et Plex.
2. Si vous modifiez `update-lists.sh`, prêtez une attention extrême à ne jamais insérer de formatage Windows (`\r\n`) qui pourrait invalider le validateur de boucle par ligne de MikroTik. Mettez le dépôt en strict `\n`.
3. Assurez-vous que votre MikroTik dispose bien du serveur NTP activé pour garantir le succès de la validation TLS du HTTPS Raw Github content.
