# Aiguillage

Outil macOS personnel pour le train : un démon root capture tout le trafic IPv4 dans une interface
`utun` et fait sortir chaque connexion par le meilleur de deux liens physiques — le Wi-Fi du train
(`en0`, lien primaire) et le partage de connexion USB de l'iPhone (par ex. `en7`, lien secondaire).
Il bascule quand le Wi-Fi est « connecté mais mort ».

Pas de Network Extension, pas de compte développeur, pas de serveur.

## Fonctionnement

- **Capture** : une `utun` (198.18.0.1 ↔ 198.18.0.2) et deux routes `0/1` + `128/1` qui
  l'emportent sur la route par défaut sans la supprimer. Les sous-réseaux locaux restent directs
  (routes plus spécifiques). Les routes disparaissent avec l'interface si le processus meurt.
- **TCP** : les SYN sont réécrits (NAT) vers un listener local sur 198.18.0.1 ; c'est la pile TCP
  du noyau qui termine la connexion, puis le démon la relaie vers la vraie destination par un socket
  lié à une interface physique. Mode `race` (par défaut) : on tente le lien préféré, puis l'autre
  après un court délai (`2 × RTT`, entre 300 ms et 1 s) ; le premier établi gagne. Mode `failover` :
  le second lien seulement si le premier est en panne ou échoue (1 s).
- **UDP** : NAT par flux, un socket par flux lié au lien choisi ; re-épinglage sur l'autre lien si
  le lien tombe ou si 3 datagrammes restent sans réponse pendant 1,5 s.
- **DNS** : le résolveur système est redirigé vers 198.18.0.2. Les requêtes partent vers les DNS
  (DHCP) de chaque lien, le préféré d'abord, l'autre 150 ms après ; la première réponse positive
  gagne (une réponse négative attend jusqu'à 400 ms l'autre lien : les portails captifs ont des noms
  que seul le DNS du Wi-Fi connaît). Les requêtes AAAA reçoivent une réponse vide : tout reste en IPv4.
  La redirection utilise par défaut `--dns-mode networksetup` (voir plus bas), qui installe
  198.18.0.2 comme résolveur **primaire** des services actifs.
- **Sortie (egress)** : chaque socket sortant est un socket BSD brut lié à l'interface physique
  avec `IP_BOUND_IF` (index via `if_nametoindex`). `requiredInterface` de Network.framework ne
  marche pas ici : une fois nos routes posées, il juge l'interface physique non routable vers
  Internet et rejette la connexion. Seule la partie *entrante* (le listener sur 198.18.0.1) reste
  en Network.framework.
  Pour que la recherche de route *scoped* d'`IP_BOUND_IF` trouve une destination hors-réseau (nos
  routes globales 0/1 + 128/1 sur l'utun masqueraient sinon la route par défaut du lien, même pour
  une recherche scoped → ENETUNREACH), on installe par lien des routes **scoped à l'interface** via
  sa passerelle : `route -n add -net 0.0.0.0/1 <routeur> -ifscope <if>` (et `128.0.0.0/1`). Ces
  routes ne matchent que les recherches liées à cette interface (nos sockets egress), donc elles
  n'affectent pas le routage normal. Elles ne sont pas liées au fd de l'utun : Aiguillage les
  retire à l'arrêt et nettoie les résidus au démarrage suivant.
- **IPv6** : capturé et refusé (RST sur les SYN), les applications retombent sur IPv4.
- **Santé des liens** : sonde HTTP `http://captive.apple.com/hotspot-detect.html` liée à chaque
  lien (toutes les 2 s, 5 s pour l'iPhone quand le Wi-Fi va bien, 1 s pour un lien en panne).
  États `up` / `captive` / `down` ; `down` après 2 échecs, `up` après 3 succès. Quand un lien
  tombe, ses connexions TCP sont coupées (RST) pour que les applis se reconnectent sur l'autre.

## Compiler et lancer

```sh
swift build -c release
sudo .build/release/aiguillage up            # Ctrl-C pour arrêter proprement
sudo .build/release/aiguillage up --verbose --mode failover
```

Options de `up` : `--primary IF`, `--secondary IF` (sinon : Wi-Fi = primaire, l'autre interface =
secondaire), `--mode race|failover`, `--dns-mode networksetup|dynamicstore|none` (défaut
`networksetup`), `--rule`, `--no-default-rules`, `--verbose`.

Diagnostic bas niveau :

```sh
# teste IP_BOUND_IF + connect brut SANS routes (à lancer quand `up` ne tourne PAS) :
sudo .build/release/aiguillage bindtest en0 1.1.1.1 443
# teste l'egress AVEC les routes installées (reproduit la vraie condition), puis tourne normalement :
sudo .build/release/aiguillage up --selftest --verbose   # regarder les lignes « selftest <if>: ok/… »
```

## Vérifier que ça marche

```sh
.build/release/aiguillage doctor          # sans root : liens, DNS, sondes, tunnels, règles
.build/release/aiguillage status          # liens, RTT, octets, flux actifs
.build/release/aiguillage status --json   # snapshot JSON, aussi lu par l'app de barre de menus
netstat -rn -f inet | grep -E '^(0/1|128.0/1)'   # les deux routes vers l'utun d'Aiguillage
scutil --dns | head -20                   # 198.18.0.2 doit être le résolveur primaire (resolver #1)
dig +short claude.ai                      # doit répondre via Aiguillage
dig +short <pair>.<tailnet>.ts.net        # doit toujours passer par MagicDNS (spécificité)
curl -v http://captive.apple.com/hotspot-detect.html
```

Au démarrage, `up` affiche « dns check: … » : en mode `networksetup` il confirme que 198.18.0.2
est le premier résolveur primaire ; en mode `dynamicstore` il indique quel résolveur « match-all »
est en tête et prévient si un autre (Tailscale) passe avant le nôtre.

Test de bascule : couper le Wi-Fi « sans le couper » (par ex. débrancher le routeur ou bloquer la
sortie), les logs doivent montrer `link en0 (primary): up -> down` et les connexions repartir par
l'iPhone.

## Barre de menus

Une petite app AppKit (`aiguillage-menubar`) ajoute une icône dans la barre de menus : état de
chaque lien (Wi-Fi / iPhone USB) avec pastille de couleur, RTT, octets, lien primaire, mode
courant, nombre de flux TCP/UDP actifs et règles de routage avec le nombre de flux épinglés. L'icône
(symbole SF, image *template* qui s'adapte au thème clair/sombre) résume l'état global : démon
arrêté, sain, dégradé (un lien down/captif) ou tout en panne.

```sh
swift build -c release
.build/release/aiguillage-menubar &        # app non privilégiée (pas de .app, pas de Dock)
```

Si aucun démon ne tourne, le menu affiche « Aiguillage : arrêté ».

- **Démarrer le démon…** : l'app tourne **sans privilèges**, elle ne peut pas devenir root toute
  seule. Elle lance donc le démon via une **fenêtre macOS de mot de passe administrateur**
  (`osascript … with administrator privileges`). C'est attendu : le démon a besoin de root. Le démon
  est lancé détaché (`nohup … &`, sortie redirigée vers `/tmp/aiguillage.log`) et continue de tourner
  après la fenêtre. Le binaire `aiguillage` est cherché à côté de `aiguillage-menubar` (même dossier
  `.build/<config>/`), puis `/usr/local/bin/aiguillage` ; surchargeable via `AIGUILLAGE_BIN`, et les
  arguments de `up` via `AIGUILLAGE_UP_ARGS`.
- **Arrêter le démon** : **pas de mot de passe**. L'app écrit `{"cmd":"stop"}` sur la socket de
  statut (`/var/run/aiguillage.sock`, mode 0666) ; le démon, déjà root, fait son arrêt propre
  habituel (DNS restauré, routes scoped retirées, utun fermé, « ciao les naz! ») et quitte.
- **Mode** : bascule `race` ⇄ `failover` à chaud via la même socket (`{"cmd":"set-mode"}`) ; les
  nouveaux flux prennent le nouveau mode.
- **Quitter** : ferme **uniquement** l'app de barre de menus ; le démon continue de tourner. Pour
  arrêter le démon, utiliser « Arrêter le démon ».

## Forcer un domaine sur un lien

Des règles associent une destination à une politique :

| politique  | effet |
|------------|-------|
| `best`     | **recommandé** : suit le meilleur lien du moment sans gaspiller la data — un seul lien est tenté, le plus sain (état, puis RTT, puis échecs récents ; à égalité, le Wi-Fi) — l’autre seulement si la connexion échoue ou dépasse 1 s |
| `cellular` | force l'iPhone/5G, même quand il est moins bon que le Wi-Fi (tunnel, 4G faible) |
| `wifi`     | force le Wi-Fi |
| `race`, `failover` | remplace le mode global pour cette destination |
| `block`    | bloque |

Si le lien forcé (`cellular` / `wifi`) est absent ou en panne, le flux bascule quand même sur
l'autre lien (comme `failover`) et c'est journalisé ; `block` bloque toujours.

Les noms sont reconnus grâce au DNS : quand le transitaire DNS résout un nom couvert par une règle,
il retient les adresses IPv4 renvoyées (pendant leur TTL, borné entre 60 s et 1 h) et les relais
TCP/UDP consultent cette table à l'ouverture de chaque flux. `exemple.com` = ce nom exactement,
`*.exemple.com` = tous ses sous-domaines ; une adresse ou un CIDR (`203.0.113.0/24`) marche aussi.

Règles par défaut (dans `Sources/AiguillageCore/RoutingRules.swift`, `defaultRoutingRules`) :
`anthropic.com`, `*.anthropic.com`, `claude.ai`, `*.claude.ai`, `claude.com`, `*.claude.com` →
`best`. Les désactiver : `--no-default-rules`.

Fichiers de règles (lus s'ils existent, le second l'emporte) : `/etc/aiguillage/rules.conf` puis
`~/.config/aiguillage/rules.conf` (sous `sudo`, le home de l'utilisateur appelant). Une règle par
ligne, `#` pour les commentaires :

```
# Claude suit le meilleur lien du moment
*.anthropic.com = best
claude.ai       = best
# forcer la 5G pour un service précis
api.exemple.com = cellular
# jamais par l'iPhone
*.icloud-content.com = wifi
```

Priorité : `--rule` > fichiers > règles par défaut (à motif identique). Exemple :

```sh
sudo .build/release/aiguillage up --rule '*.anthropic.com=cellular'
```

Pour vérifier que Claude passe bien par le bon lien : `aiguillage status` (ou `doctor` pendant que
le démon tourne) liste les flux associés à une règle, avec la règle et le lien utilisé.

Limite : une appli qui fait son propre DNS (DoH) ou qui avait déjà l'adresse en cache avant le
démarrage échappe à la règle et suit le mode global, jusqu'à sa prochaine résolution.

## Tailscale

Aiguillage cohabite avec Tailscale : il n'ajoute que `0/1`, `128/1`, `::/1` et `8000::/1`, donc
les routes plus spécifiques de Tailscale (100.64.0.0/10, pairs, 100.100.100.100,
fd7a:115c:a1e0::/48, sous-réseaux annoncés) continuent d'aller vers son utun. Le trafic du tailnet
et MagicDNS (`*.ts.net`, résolveur dédié au domaine) continuent de marcher ; un paquet CGNAT qui
arriverait quand même dans notre utun est jeté, jamais relayé dehors. Notre résolveur « match-all »
demande un `SearchOrder` de 1 pour passer devant celui de Tailscale (≈ 102000).

Non supporté : les **exit nodes** (Aiguillage les contournerait ; `doctor`/`up` préviennent).
Le transport chiffré de Tailscale reste lié à l'interface physique que Tailscale a choisie : le
trafic du tailnet lui-même ne bascule peut-être pas quand le Wi-Fi est connecté-mais-mort (non
vérifié, à tester).

## Limites

- IPv4 seulement ; IPv6 est refusé. ICMP (ping, traceroute) et fragments IP sont jetés.
- Pas de relais pour les datagrammes UDP plus grands que le MTU (1500).
- Les sockets d'Aiguillage sont liés aux interfaces : un VPN qui détient la route par défaut est
  contourné ; `doctor` le signale.
- Partie root non testée par l'auteur : voir « dépannage » si quelque chose coince.

## Modes DNS

- `networksetup` (**défaut**) : `networksetup -setdnsservers <service> 198.18.0.2` sur les services
  des liens actifs. 198.18.0.2 devient un résolveur **primaire**, qui l'emporte sur le résolveur
  supplémentaire « match-all » de Tailscale. Les anciennes valeurs sont sauvées dans
  `/var/run/aiguillage-dns.json`, restaurées à l'arrêt (SIGINT/SIGTERM/SIGHUP), au démarrage suivant
  (reste périmé d'un crash), et par `aiguillage restore`.
- `dynamicstore` : écrit un résolveur supplémentaire `State:/Network/Service/<uuid>/DNS` à clé de
  session (disparaît tout seul si le process meurt). **Ne bat pas Tailscale** sur cette machine :
  l'`order` d'un résolveur supplémentaire vient de la position/primauté du service, pas de notre
  champ `SearchOrder`, donc notre entrée se range derrière le résolveur supplémentaire de Tailscale
  (≈ order 101400) et toutes les résolutions partent vers 100.100.100.100. À réserver aux machines
  sans Tailscale. (Piste non retenue : un override global `State:/Network/Global/DNS` ou une clé
  `Setup:` pourrait passer devant, mais c'est fragile et intrusif — non implémenté par défaut.)
- `none` : ne touche pas au DNS système (les requêtes vers 198.18.0.2 marchent quand même si on les
  y envoie).

`ts.net` : même avec notre DNS primaire, le résolveur dédié de Tailscale pour `*.ts.net` gagne par
spécificité (à confirmer en test root avec `dig +short <pair>.<tailnet>.ts.net`).

## Dépannage : DNS bloqué

- Après un crash en mode `networksetup` :

  ```sh
  sudo .build/release/aiguillage restore
  ```

  En dernier recours, à la main : `networksetup -setdnsservers Wi-Fi Empty` (idem pour
  « iPhone USB »), puis `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.
- Les routes globales et l'utun disparaissent quand le processus meurt. Si `0/1` reste visible
  (`netstat -rn`), `sudo route -n delete -net 0.0.0.0/1` et `128.0.0.0/1`.
- Les routes egress **scoped** (`-ifscope`) ne sont pas liées à l'utun. Après un `kill -9` elles
  peuvent rester : c'est sans danger (scoped, inutilisées tant que rien ne se lie à cette
  interface) et c'est nettoyé au prochain `up` (ou par `sudo aiguillage restore`). Pour les voir :
  `netstat -rn -f inet | grep -i ifscope` ; à la main :
  `sudo route -n delete -net 0.0.0.0/1 <routeur> -ifscope <if>`.
