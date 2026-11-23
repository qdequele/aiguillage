# Aiguillage

Outil macOS personnel pour le train : un démon root capture tout le trafic IPv4 dans une interface
`utun` et fait sortir chaque connexion par le meilleur de deux liens physiques — le Wi-Fi du train
(`en0`, lien primaire) et le partage de connexion USB de l'iPhone (par ex. `en7`, lien secondaire).
Il bascule quand le Wi-Fi est « connecté mais mort ».

Pas de Network Extension, pas de compte développeur, pas de serveur. Swift + SwiftPM uniquement
(Command Line Tools, sans Xcode).

## Installation

Trois façons, de la plus simple à la plus bas-niveau.

### 1. App + DMG (recommandé)

Récupère `Aiguillage.dmg` dans les [Releases](https://github.com/qdequele/aiguillage/releases)
(ou construis-le : `bash scripts/make-dmg.sh` → `dist/Aiguillage.dmg`).

1. Ouvre le `.dmg`, glisse **`Aiguillage.app`** dans `Applications`.
2. Premier lancement : **clic droit sur l'app → Ouvrir** (l'app est signée ad-hoc, pas par Apple),
   puis « Ouvrir » dans la boîte de dialogue. Une seule fois.
3. L'icône (un aiguillage) apparaît dans la barre de menus. **Démarrer le démon…** demande le mot
   de passe administrateur (le routage réseau exige root).

### 2. Service launchd — démarrage auto, sans mot de passe

Pour que le démon démarre tout seul à chaque boot/login **sans redemander le mot de passe** :

```sh
swift build -c release
sudo bash scripts/install-launchd.sh      # copie le binaire dans /usr/local/bin, installe le service
```

- Démarre au boot/login, se relance en cas de crash (`KeepAlive` sur sortie anormale seulement).
- **Arrêter** depuis la barre de menus → reste arrêté (sortie propre). Le rallumer sans mot de passe :
  `sudo launchctl kickstart system/com.qdequelen.aiguillage`.
- Désinstaller : `sudo bash scripts/uninstall-launchd.sh`.

### 3. Depuis les sources (dev)

```sh
swift build -c release
sudo .build/release/aiguillage up            # Ctrl-C pour arrêter proprement
sudo .build/release/aiguillage up --verbose --mode failover
```

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
- **DNS** : par défaut `--dns-mode auto` — le démon s'adapte à l'environnement (voir
  [Modes DNS](#modes-dns)). **Avec Tailscale**, il ne touche pas au résolveur système : Tailscale
  possède déjà le DNS (résolveur supplémentaire « match-all » sur son utun qui relaie lui-même en
  amont), le détourner casserait toute résolution fraîche. **Sans Tailscale**, il installe 198.18.0.2
  comme résolveur primaire et prend en charge les requêtes : elles partent vers les DNS (DHCP) de
  chaque lien, le préféré d'abord, l'autre 150 ms après ; la première réponse positive gagne (une
  réponse négative attend jusqu'à 400 ms l'autre lien : les portails captifs ont des noms que seul
  le DNS du Wi-Fi connaît). Les requêtes AAAA reçoivent une réponse vide ; l'IPv6 est de toute façon
  refusée côté transport.
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

## Barre de menus

Une petite app AppKit (`aiguillage-menubar`, embarquée dans `Aiguillage.app`) ajoute une icône dans
la barre de menus : état de chaque lien (Wi-Fi / iPhone USB) avec pastille de couleur, RTT, octets,
lien primaire, mode courant, nombre de flux TCP/UDP actifs et règles de routage avec le nombre de
flux épinglés. L'icône est le symbole SF `arrow.triangle.branch` (un aiguillage), **coloré selon
l'état global** : gris (arrêté), vert (sain), orange (dégradé — un lien down/captif), rouge (tout en
panne).

En dev, sans bundle :

```sh
swift build -c release
.build/release/aiguillage-menubar &        # app non privilégiée (pas de Dock)
```

Si aucun démon ne tourne, le menu affiche « Aiguillage : arrêté ».

- **Démarrer le démon…** : l'app tourne **sans privilèges**, elle ne peut pas devenir root toute
  seule. Elle lance donc le démon via une **fenêtre macOS de mot de passe administrateur**
  (`osascript … with administrator privileges`). Le démon est lancé **détaché** via un sous-shell
  (`( … >> /tmp/aiguillage.log 2>&1 </dev/null & )`) — pas `nohup`, qui échoue sans terminal de
  contrôle sous les privilèges admin — et continue de tourner après la fenêtre. Le binaire
  `aiguillage` est cherché à côté de `aiguillage-menubar` (même dossier), puis
  `/usr/local/bin/aiguillage` ; surchargeable via `AIGUILLAGE_BIN`, arguments de `up` via
  `AIGUILLAGE_UP_ARGS`. *(Avec le service launchd, inutile : le démon tourne déjà.)*
- **Arrêter le démon** : **pas de mot de passe**. L'app écrit `{"cmd":"stop"}` sur la socket de
  statut (`/var/run/aiguillage.sock`, mode 0666) ; le démon, déjà root, fait son arrêt propre
  habituel (DNS restauré, routes scoped retirées, utun fermé, « ciao les naz! ») et quitte.
- **Mode** : bascule `race` ⇄ `failover` à chaud via la même socket (`{"cmd":"set-mode"}`) ; les
  nouveaux flux prennent le nouveau mode.
- **Quitter** : ferme **uniquement** l'app de barre de menus ; le démon continue de tourner.

## Forcer un domaine sur un lien

> Nécessite `--dns-mode networksetup` (donc : sans Tailscale, ou en le forçant). En mode `none`
> (le défaut quand Tailscale tourne) le transitaire DNS ne voit pas les requêtes, donc rien n'est
> appris et les règles par domaine sont inactives — ce n'est pas un problème en pratique : en mode
> global `race`/`best`, **tout** le trafic prend déjà le meilleur lien.

Des règles associent une destination à une politique :

| politique  | effet |
|------------|-------|
| `best`     | **recommandé** : suit le meilleur lien du moment sans gaspiller la data — un seul lien est tenté, le plus sain (état, puis RTT, puis échecs récents ; à égalité, le Wi-Fi) — l'autre seulement si la connexion échoue ou dépasse 1 s |
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
sudo .build/release/aiguillage up --dns-mode networksetup --rule '*.anthropic.com=cellular'
```

Pour vérifier qu'un domaine passe par le bon lien : `aiguillage status` (ou `doctor` pendant que le
démon tourne) liste les flux associés à une règle, avec la règle et le lien utilisé.

Limite : une appli qui fait son propre DNS (DoH) ou qui avait déjà l'adresse en cache avant le
démarrage échappe à la règle et suit le mode global, jusqu'à sa prochaine résolution.

## Tailscale

Aiguillage cohabite avec Tailscale : il n'ajoute que `0/1`, `128/1`, `::/1` et `8000::/1`, donc
les routes plus spécifiques de Tailscale (100.64.0.0/10, pairs, 100.100.100.100,
fd7a:115c:a1e0::/48, sous-réseaux annoncés) continuent d'aller vers son utun. Le trafic du tailnet
et MagicDNS (`*.ts.net`) continuent de marcher ; un paquet CGNAT qui arriverait quand même dans
notre utun est jeté, jamais relayé dehors.

**DNS** : quand Tailscale est détecté, `--dns-mode auto` choisit `none` et **laisse le DNS système
tranquille**. C'est délibéré : Tailscale installe un résolveur supplémentaire « match-all » que
macOS privilégie et qui relaie lui-même en amont ; forcer notre résolveur à sa place fait que macOS
ne nous livre jamais les requêtes *et* qu'on coupe celui de Tailscale → plus aucune résolution
fraîche. La résolution native marche très bien, on ne s'en mêle pas. (Conséquence : les règles par
domaine sont inactives — voir la note plus haut.)

Non supporté : les **exit nodes** (Aiguillage les contournerait ; `doctor`/`up` préviennent).
Le transport chiffré de Tailscale reste lié à l'interface physique que Tailscale a choisie : le
trafic du tailnet lui-même ne bascule peut-être pas quand le Wi-Fi est connecté-mais-mort (non
vérifié, à tester).

## Vérifier que ça marche

```sh
aiguillage status          # liens, RTT, octets, flux actifs  (binaire : /usr/local/bin ou .build/release)
aiguillage status --json   # snapshot JSON, aussi lu par l'app de barre de menus
aiguillage doctor          # sans root : liens, DNS, sondes, tunnels, règles
netstat -rn -f inet | grep -E '^(0/1|128.0/1)'       # les deux routes vers l'utun d'Aiguillage
dig +short claude.ai                                 # doit répondre
curl -v --max-time 8 https://api.anthropic.com       # doit se connecter (404 sur / = OK)
```

Service launchd : `sudo launchctl print system/com.qdequelen.aiguillage` ; logs dans
`/var/log/aiguillage.log` (ou `/tmp/aiguillage.log` si lancé par la barre de menus).

En mode `networksetup` seulement, `up` affiche au démarrage « dns check: … » qui confirme que
198.18.0.2 est le premier résolveur primaire, et `scutil --dns | head -20` doit le montrer en tête.

Test de bascule (à deux liens) : brancher l'iPhone en USB, puis couper le Wi-Fi « sans le couper »
(par ex. débrancher le routeur ou bloquer sa sortie) — les logs doivent montrer
`link en0 (primary): up -> down` et les connexions repartir par l'iPhone.

## Modes DNS

`--dns-mode` vaut par défaut **`auto`** :

- **`auto`** : `none` si Tailscale tourne (DNS natif, qui marche déjà), sinon `networksetup`.
  Un `--dns-mode` explicite l'emporte toujours.
- **`networksetup`** : `networksetup -setdnsservers <service> 198.18.0.2` sur les services des liens
  actifs. 198.18.0.2 devient un résolveur **primaire**, qui l'emporte sur le résolveur supplémentaire
  « match-all » de Tailscale — mais c'est précisément ce combat qui casse la résolution quand
  Tailscale est là, d'où le défaut `none` dans ce cas. Les anciennes valeurs sont sauvées dans
  `/var/run/aiguillage-dns.json`, restaurées à l'arrêt (SIGINT/SIGTERM/SIGHUP), au démarrage suivant
  (reste périmé d'un crash), et par `aiguillage restore`. C'est le mode qui permet aux règles par
  domaine d'apprendre les adresses.
- **`dynamicstore`** : écrit un résolveur supplémentaire à clé de session (disparaît tout seul si le
  process meurt). **Ne bat pas Tailscale** (l'`order` vient de la position du service, pas de notre
  `SearchOrder`). À réserver aux machines sans Tailscale.
- **`none`** : ne touche pas au DNS système (les requêtes vers 198.18.0.2 marchent quand même si on
  les y envoie).

## Compiler, tester, diagnostiquer

```sh
swift build -c release
swift test                                   # 64 tests (Swift Testing)

# teste IP_BOUND_IF + connect brut SANS routes (quand `up` ne tourne PAS) :
sudo .build/release/aiguillage bindtest en0 1.1.1.1 443
# teste l'egress AVEC les routes installées, puis tourne normalement :
sudo .build/release/aiguillage up --selftest --verbose   # lignes « selftest <if>: ok/… »
```

Options de `up` : `--primary IF`, `--secondary IF` (sinon : Wi-Fi = primaire, l'autre interface =
secondaire), `--mode race|failover`, `--dns-mode auto|networksetup|dynamicstore|none`, `--rule`,
`--no-default-rules`, `--selftest`, `--verbose`.

## Limites

- IPv4 seulement ; IPv6 est refusé. ICMP (ping, traceroute) et fragments IP sont jetés.
- Pas de relais pour les datagrammes UDP plus grands que le MTU (1500).
- Les sockets d'Aiguillage sont liés aux interfaces : un VPN qui détient la route par défaut est
  contourné ; `doctor` le signale.
- Avec Tailscale, le routage **par domaine** est inactif (DNS laissé natif) — sans effet pratique
  en mode global `race`/`best`.
- La **bascule à deux liens** (Wi-Fi mort → iPhone) n'est pas encore validée en conditions réelles ;
  le chemin à un lien et la cohabitation Tailscale, eux, tournent (service launchd en production).

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
  `netstat -rn -f inet | grep -i ifscope`.
