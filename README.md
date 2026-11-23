# Aiguillage

A personal macOS tool for the train: a root daemon captures all IPv4 traffic into a `utun`
interface and sends each connection out over the better of two physical links — the train Wi-Fi
(`en0`, primary link) and the iPhone's USB tethering (e.g. `en7`, secondary link). It fails over
when the Wi-Fi is "connected but dead".

No Network Extension, no developer account, no server. Swift + SwiftPM only (Command Line Tools,
no Xcode).

## Installation

Three ways, from the simplest to the most low-level.

### 1. App + DMG (recommended)

Grab `Aiguillage.dmg` from the [Releases](https://github.com/qdequele/aiguillage/releases)
(or build it: `bash scripts/make-dmg.sh` → `dist/Aiguillage.dmg`).

1. Open the `.dmg`, drag **`Aiguillage.app`** into `Applications`.
2. First launch: **right-click the app → Open** (the app is ad-hoc signed, not by Apple), then
   "Open" in the dialog. Once only.
3. The icon (a railway switch) appears in the menu bar. **Start the daemon…** asks for the admin
   password (network routing requires root).

### 2. launchd service — auto-start, no password

To have the daemon start on its own at every boot/login **without asking for the password again**:

```sh
swift build -c release
sudo bash scripts/install-launchd.sh      # copies the binary to /usr/local/bin, installs the service
```

- Starts at boot/login, restarts on crash (`KeepAlive` on abnormal exit only).
- **Stop** it from the menu bar → stays stopped (clean exit). Turn it back on without a password:
  `sudo launchctl kickstart system/com.qdequelen.aiguillage`.
- Uninstall: `sudo bash scripts/uninstall-launchd.sh`.

### 3. From source (dev)

```sh
swift build -c release
sudo .build/release/aiguillage up            # Ctrl-C to stop cleanly
sudo .build/release/aiguillage up --verbose --mode failover
```

## How it works

- **Capture**: a `utun` (198.18.0.1 ↔ 198.18.0.2) plus two routes `0/1` + `128/1` that win over
  the default route without deleting it. Local subnets stay direct (more specific routes). The
  routes disappear with the interface if the process dies.
- **TCP**: SYNs are rewritten (NAT) to a local listener on 198.18.0.1; the kernel's TCP stack
  terminates the connection, then the daemon relays it to the real destination over a socket bound
  to a physical interface. `race` mode (the default): try the preferred link, then the other one
  after a short delay (`2 × RTT`, between 300 ms and 1 s); the first to connect wins. `failover`
  mode: the second link only if the first is down or fails (1 s).
- **UDP**: per-flow NAT, one socket per flow bound to the chosen link; re-pinned to the other link
  if the link goes down or if 3 datagrams go unanswered for 1.5 s.
- **DNS**: `--dns-mode auto` by default — the daemon adapts to the environment (see
  [DNS modes](#dns-modes)). **With Tailscale**, it leaves the system resolver alone: Tailscale
  already owns DNS (a "match-all" supplemental resolver on its utun that forwards upstream itself),
  and hijacking it would break all fresh resolution. **Without Tailscale**, it installs 198.18.0.2
  as the primary resolver and handles queries: they go to each link's (DHCP) DNS servers, the
  preferred one first, the other 150 ms later; the first positive answer wins (a negative answer
  waits up to 400 ms for the other link: captive portals have names only the Wi-Fi's DNS knows).
  AAAA queries get an empty answer; IPv6 is refused at the transport layer anyway.
- **Egress**: each outbound socket is a raw BSD socket bound to the physical interface with
  `IP_BOUND_IF` (index via `if_nametoindex`). Network.framework's `requiredInterface` does not work
  here: once our routes are in place, it decides the physical interface is not routable to the
  internet and rejects the connection. Only the *inbound* part (the listener on 198.18.0.1) stays
  in Network.framework.
  So that `IP_BOUND_IF`'s *scoped* route lookup can find an off-net destination (our global 0/1 +
  128/1 routes on the utun would otherwise shadow the link's default route, even for a scoped
  lookup → ENETUNREACH), we install per-link **interface-scoped** routes via its gateway:
  `route -n add -net 0.0.0.0/1 <router> -ifscope <if>` (and `128.0.0.0/1`). These routes only
  match lookups bound to that interface (our egress sockets), so they don't affect normal routing.
  They're not tied to the utun fd: Aiguillage removes them on stop and cleans up leftovers on the
  next start.
- **IPv6**: captured and refused (RST on SYNs), applications fall back to IPv4.
- **Link health**: an HTTP probe to `http://captive.apple.com/hotspot-detect.html` bound to each
  link (every 2 s, 5 s for the iPhone when Wi-Fi is fine, 1 s for a down link). States
  `up` / `captive` / `down`; `down` after 2 failures, `up` after 3 successes. When a link goes
  down, its TCP connections are cut (RST) so apps reconnect over the other.

## Menu bar

A small AppKit app (`aiguillage-menubar`, embedded in `Aiguillage.app`) adds an icon to the menu
bar: the state of each link (Wi-Fi / iPhone USB) with a colored dot, RTT, bytes, the primary link,
the current mode, the number of active TCP/UDP flows, and the routing rules with the number of
pinned flows. The icon is the SF symbol `arrow.triangle.branch` (a railway switch), **colored by
the overall state**: gray (stopped), green (healthy), orange (degraded — one link down/captive),
red (everything down).

In dev, without a bundle:

```sh
swift build -c release
.build/release/aiguillage-menubar &        # unprivileged app (no Dock)
```

If no daemon is running, the menu shows "Aiguillage: stopped".

- **Start the daemon…**: the app runs **unprivileged**, so it can't become root on its own. It
  therefore launches the daemon via a **macOS admin-password dialog**
  (`osascript … with administrator privileges`). The daemon is launched **detached** via a subshell
  (`( … >> /tmp/aiguillage.log 2>&1 </dev/null & )`) — not `nohup`, which fails without a
  controlling terminal under admin privileges — and keeps running after the dialog closes. The
  `aiguillage` binary is looked up next to `aiguillage-menubar` (same folder), then
  `/usr/local/bin/aiguillage`; overridable via `AIGUILLAGE_BIN`, and `up` arguments via
  `AIGUILLAGE_UP_ARGS`. *(With the launchd service this is unnecessary: the daemon is already
  running.)*
- **Stop the daemon**: **no password**. The app writes `{"cmd":"stop"}` to the status socket
  (`/var/run/aiguillage.sock`, mode 0666); the daemon, already root, does its usual clean shutdown
  (DNS restored, scoped routes removed, utun closed, "ciao les naz!") and exits.
- **Mode**: toggle `race` ⇄ `failover` live over the same socket (`{"cmd":"set-mode"}`); new flows
  pick up the new mode.
- **Quit**: closes **only** the menu-bar app; the daemon keeps running.

## Forcing a domain onto a link

> Requires `--dns-mode networksetup` (so: without Tailscale, or by forcing it). In `none` mode
> (the default when Tailscale is running) the DNS forwarder doesn't see the queries, so nothing is
> learned and per-domain rules are inactive — not a problem in practice: in global `race`/`best`
> mode, **all** traffic already takes the best link.

Rules map a destination to a policy:

| policy     | effect |
|------------|--------|
| `best`     | **recommended**: follows the current best link without wasting data — a single link is tried, the healthiest (state, then RTT, then recent failures; ties go to Wi-Fi) — the other one only if the connection fails or exceeds 1 s |
| `cellular` | forces the iPhone/5G, even when it's worse than Wi-Fi (tunnel, weak 4G) |
| `wifi`     | forces Wi-Fi |
| `race`, `failover` | overrides the global mode for this destination |
| `block`    | blocks |

If the forced link (`cellular` / `wifi`) is absent or down, the flow still fails over to the other
link (like `failover`) and this is logged; `block` always blocks.

Names are recognized via DNS: when the DNS forwarder resolves a name covered by a rule, it keeps
the returned IPv4 addresses (for their TTL, clamped between 60 s and 1 h) and the TCP/UDP relays
consult this table when each flow opens. `example.com` = that exact name, `*.example.com` = all its
subdomains; an address or a CIDR (`203.0.113.0/24`) works too.

Default rules (in `Sources/AiguillageCore/RoutingRules.swift`, `defaultRoutingRules`):
`anthropic.com`, `*.anthropic.com`, `claude.ai`, `*.claude.ai`, `claude.com`, `*.claude.com` →
`best`. Disable them: `--no-default-rules`.

Rule files (read if present, the second wins): `/etc/aiguillage/rules.conf` then
`~/.config/aiguillage/rules.conf` (under `sudo`, the calling user's home). One rule per line, `#`
for comments:

```
# Claude follows the current best link
*.anthropic.com = best
claude.ai       = best
# force 5G for a specific service
api.example.com = cellular
# never over the iPhone
*.icloud-content.com = wifi
```

Priority: `--rule` > files > default rules (for an identical pattern). Example:

```sh
sudo .build/release/aiguillage up --dns-mode networksetup --rule '*.anthropic.com=cellular'
```

To check that a domain goes over the right link: `aiguillage status` (or `doctor` while the daemon
is running) lists the flows tied to a rule, with the rule and the link in use.

Limitation: an app that does its own DNS (DoH) or that already had the address cached before startup
escapes the rule and follows the global mode, until its next resolution.

## Tailscale

Aiguillage coexists with Tailscale: it only adds `0/1`, `128/1`, `::/1` and `8000::/1`, so
Tailscale's more specific routes (100.64.0.0/10, peers, 100.100.100.100, fd7a:115c:a1e0::/48,
advertised subnets) keep going to its utun. Tailnet and MagicDNS (`*.ts.net`) traffic keeps
working; a CGNAT packet that still ended up in our utun is dropped, never relayed out.

**DNS**: when Tailscale is detected, `--dns-mode auto` chooses `none` and **leaves the system DNS
alone**. This is deliberate: Tailscale installs a "match-all" supplemental resolver that macOS
prefers and that forwards upstream itself; forcing our resolver in its place means macOS never
delivers queries to us *and* we blackhole Tailscale's → no more fresh resolution at all. Native
resolution works fine, so we stay out of it. (Consequence: per-domain rules are inactive — see the
note above.)

Not supported: **exit nodes** (Aiguillage would bypass them; `doctor`/`up` warn). Tailscale's
encrypted transport stays bound to the physical interface Tailscale picked: the tailnet traffic
itself may not fail over when the Wi-Fi is connected-but-dead (unverified, to be tested).

## Verifying it works

```sh
aiguillage status          # links, RTT, bytes, active flows  (binary: /usr/local/bin or .build/release)
aiguillage status --json   # JSON snapshot, also read by the menu-bar app
aiguillage doctor          # without root: links, DNS, probes, tunnels, rules
netstat -rn -f inet | grep -E '^(0/1|128.0/1)'       # the two routes to Aiguillage's utun
dig +short claude.ai                                 # must answer
curl -v --max-time 8 https://api.anthropic.com       # must connect (404 on / = OK)
```

launchd service: `sudo launchctl print system/com.qdequelen.aiguillage`; logs in
`/var/log/aiguillage.log` (or `/tmp/aiguillage.log` if started from the menu bar).

In `networksetup` mode only, `up` prints a "dns check: …" line at startup confirming that
198.18.0.2 is the first primary resolver, and `scutil --dns | head -20` should show it at the top.

Failover test (two links): plug in the iPhone over USB, then kill the Wi-Fi "without killing it"
(e.g. unplug the router or block its uplink) — the logs should show
`link en0 (primary): up -> down` and connections resume over the iPhone.

## DNS modes

`--dns-mode` defaults to **`auto`**:

- **`auto`**: `none` if Tailscale is running (native DNS, which already works), otherwise
  `networksetup`. An explicit `--dns-mode` always wins.
- **`networksetup`**: `networksetup -setdnsservers <service> 198.18.0.2` on the active links'
  services. 198.18.0.2 becomes a **primary** resolver that wins over Tailscale's "match-all"
  supplemental resolver — but that very fight is what breaks resolution when Tailscale is present,
  hence the `none` default in that case. The previous values are saved to
  `/var/run/aiguillage-dns.json`, restored on stop (SIGINT/SIGTERM/SIGHUP), on the next start (any
  leftover from a crash), and by `aiguillage restore`. This is the mode that lets per-domain rules
  learn addresses.
- **`dynamicstore`**: writes a session-keyed supplemental resolver (disappears on its own if the
  process dies). **Does not beat Tailscale** (the `order` comes from the service's position, not
  from our `SearchOrder`). Reserve it for machines without Tailscale.
- **`none`**: doesn't touch the system DNS (queries to 198.18.0.2 still work if you send them
  there).

## Building, testing, diagnosing

```sh
swift build -c release
swift test                                   # 64 tests (Swift Testing)

# test IP_BOUND_IF + a raw connect WITHOUT routes (when `up` is NOT running):
sudo .build/release/aiguillage bindtest en0 1.1.1.1 443
# test egress WITH the routes installed, then run normally:
sudo .build/release/aiguillage up --selftest --verbose   # "selftest <if>: ok/…" lines
```

`up` options: `--primary IF`, `--secondary IF` (otherwise: Wi-Fi = primary, the other interface =
secondary), `--mode race|failover`, `--dns-mode auto|networksetup|dynamicstore|none`, `--rule`,
`--no-default-rules`, `--selftest`, `--verbose`.

## Limitations

- IPv4 only; IPv6 is refused. ICMP (ping, traceroute) and IP fragments are dropped.
- No relay for UDP datagrams larger than the MTU (1500).
- Aiguillage's sockets are bound to interfaces: a VPN that owns the default route is bypassed;
  `doctor` flags it.
- With Tailscale, **per-domain** routing is inactive (DNS left native) — no practical effect in
  global `race`/`best` mode.
- **Two-link failover** (dead Wi-Fi → iPhone) is not yet validated in real conditions; the
  single-link path and Tailscale coexistence, however, do run (launchd service in production).

## Troubleshooting: DNS stuck

- After a crash in `networksetup` mode:

  ```sh
  sudo .build/release/aiguillage restore
  ```

  As a last resort, by hand: `networksetup -setdnsservers Wi-Fi Empty` (same for "iPhone USB"),
  then `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.
- The global routes and the utun disappear when the process dies. If `0/1` is still there
  (`netstat -rn`), `sudo route -n delete -net 0.0.0.0/1` and `128.0.0.0/1`.
- The **scoped** egress routes (`-ifscope`) are not tied to the utun. After a `kill -9` they may
  remain: this is harmless (scoped, unused as long as nothing binds to that interface) and is
  cleaned up on the next `up` (or by `sudo aiguillage restore`). To see them:
  `netstat -rn -f inet | grep -i ifscope`.
