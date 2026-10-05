> Pre-review detailed draft from the research workflow (2026-09-29). The approved plan (~/.claude/plans/look-into-how-to-wise-leaf.md) supersedes it wherever they differ: M0 runs as scripts with guards; RouteGuard compares only the relative order of services that already existed; ALVR stays a manual runbook with no `alvr` subcommand; E6 has separate link and VD outcomes; there is a session env file; background adb uses `shell -n`; adb over Wi-Fi goes through the `qw()` reconnect helper.

# questlink: implementation plan for a USB CDC-NCM link between a Quest 3 and a Mac

- **Date:** 2026-09-29
- **Repo:** `~/projects/personal/ncm`. It is empty and not yet a git repo.
- **Status:** this is a plan only. Nothing has been built, installed or changed.
- **Evidence tags:**
  - **[V]**: a primary source, or adversarially verified prior research.
  - **[V-here]**: checked today on this Mac or in the wine-vr repo.
  - **[L]**: likely or inferred.
  - **[U]**: unverified or single-source. Each [U] names the experiment that settles it.
  - **[C]**: contested.

---

## 0. Summary

**No driver work is needed on the Mac.**
- The built-in `com.apple.driver.usb.cdc.ncm` 5.0.0 is loaded. It matches any CDC-NCM interface (class 2/13/*) and has no VID/PID keys [V].
- The Quest 3 kernel (5.10.246) uses stock `f_ncm`, which is NCM 1.0 [V].
- What we build is the plumbing Windows handles without being asked:
  1. Raise the Mac's `enX` so the Quest gets carrier.
  2. Give both ends an IPv4 address.
  3. Handle the accessory-approval (TRM) and lock-state prompts.
  4. Keep the Mac's routes safe.
  5. Point apps at the link.

**Primary path: Mode B (adb-driven NCM).** A Mac companion, `questlink`, owns the link. It starts as a Swift CLI and later becomes a menu bar app.
1. `adb shell svc usb setFunctions ncm` switches the Quest.
2. A persistent Mac network service with no router gives the Mac 192.168.42.1/24 plus IPv6 link-local.
3. Meta's adb-only `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24` addresses the Quest [U for usb0].
4. Mac-to-Quest internet is optional, through a pf NAT anchor.
5. The wine-vr ALVR server is pinned to 192.168.42.2 over TCP.

**No Quest app is needed** on this path.

**Virtual Desktop uses Mode A** (Meta's official TRANSPORT_USB API) with no code. It is also the control experiment that tells a macOS problem apart from a Mode B problem.

**Milestone 0 is about 2 hours of headset time** for Session 1, using adb, tcpdump and ioreg only. It settles the one make-or-break unknown: does a Quest 3 on the current HzOS take IPv4 on `usb0`? Every failure maps to a named fallback (§4.8).

**Corrections found today** [V-here], all folded into this plan:
1. **OrbStack holds `127.0.0.1:8082`** (pid 1611, the paperless-ngx container). ALVR's dashboard binds `0.0.0.0:8082` (`ext/ALVR/alvr/server_core/src/web_server.rs:396-397`). Loopback requests go to the more specific OrbStack listener [L, bind specificity].
   - Never use `curl 127.0.0.1:8082` for ALVR.
   - Never treat "something listens on 8082" as "ALVR is running".
   - The ALVR pin is done by editing `session.json` offline. The live API is used only through a non-loopback Mac address.
2. **The `client.wired` race.** If `client.wired` exists and adb sees the Quest (Mode B keeps adb visible), ALVR's handshake loop (`connection.rs:278-376`, `alvr/adb/src/lib.rs` setup) does three things itself: adds the 9943/9944 forwards, autolaunches `alvr.client`, and connects over 127.0.0.1. If it gets `NotReady` instead, it skips manual IPs. So `client.wired` must be removed **before** the server starts.
3. **TRM relaxation is on this week.** `TRM_RelaxedPeriod=Yes` (timeout 259200 s) and `TRM_UnlockedPeriod=Yes` (timeout 86400 s) are live. The "Allow" prompt may be suppressed this week. Record TRM keys on every run and do not design the prompt UX from a run with no prompt.
4. **Tool details on 27.0:**
   - `system_profiler SPUSBHostDataType` is correct; `SPUSBDataType` is not.
   - The flag is spelled `networksetup -setv6LinkLocal`.
   - `networksetup -setmanual` shows the router as a positional argument; omitting it is [U].
5. **Persistent Quest-side changes are opt-in, not default:**
   - The "sticky" static IP on `usb0` requires `--sticky`, and E6b must pass first.
   - `wifi_always_requested=1` requires `--keep-quest-wifi`.
   - By default `down` returns `usb0` to `dhcp`.

---

## 1. Context

### 1.1 Goal and user decisions (2026-09-29)

**Goal:** a demo proving a USB CDC-NCM link between a Meta Quest 3 (Horizon OS, Android 14 base) and this MacBook Pro (Mac15,9, M3 Max, macOS 27.0 26A428), using only the in-box NCM driver. Once the link works, these apps should use it:
- wine-vr: Beat Saber under CrossOver, the embedded ALVR v20.14.1 server core, and the stock ALVR v20.14.1 Quest client.
- Virtual Desktop.
- Meta Quest Virtual Display / Remote Desktop, where possible.

| Decision | Consequence in this plan |
|---|---|
| Internet sharing is optional and Mac to Quest only | `questlink share on` / `up --share`: a pf NAT anchor plus Quest gateway/DNS set over adb. Never Quest to Mac. |
| Quest side is adb-driven; "macOS weirdness" is the main problem | Mode B is primary. The companion handles Gates 1–6. The Quest app is conditional. |
| Mac companion: Swift CLI first, then a menu bar app | M1–M3 build the CLI. M4 is the menu bar app plus a root daemon that reuses the same core. |
| wine-vr: manual proof only | Pin by editing `session.json`, or through the dashboard API over a non-loopback address. No wine-vr or ALVR code changes. |

**Correcting "adb tethering works":**
- The Quest is not a tethering server. In Mode B its EthernetService is a DHCP **client** on `usb0` [V, HzOS 2.7 dex], so the Mac must provide the address.
- The Windows success report ran a DHCP responder plus WinNAT on the host.
- The Virtual Desktop "NCM mode" you saw is Meta's official app API: IPv6 link-local only, no internet [V].

### 1.2 Local baseline (read-only checks, 2026-09-29)

| Item | Observed | Consequence |
|---|---|---|
| macOS and driver | 27.0 (26A428). `com.apple.driver.usb.cdc.ncm` 5.0.0 loaded (UUID 41F0BBCD). `AppleUSBDeviceNCM` is also loaded; it is device mode (en4–6, anpi*) | Identify the Quest interface by IORegistry ancestry (VID 0x2833), never by class |
| Build tools | Xcode 27.0 (27A266a); Swift 6.4, arm64-apple-macosx27.0.0. SDK ships `pcap.h`/`libpcap.tbd` and `kSCValNetIPv6ConfigMethodLinkLocal`. `PrimaryRank` is not in the public SC schema [V-here] | SwiftPM needs no installs. libpcap handles the sniffing and injection. PrimaryRank is written as a raw key [L] |
| adb | `/run/current-system/sw/bin/adb` (on PATH) and `~/Library/Android/sdk/platform-tools/adb`, both 1.0.41 / 37.0.0 | Same protocol, so the two binaries do not fight over the server. The user's server runs on 127.0.0.1:5037 |
| Android build | JDK 21.0.11. SDK platforms 32/34/35, build-tools 34/36, NDK 26.3 and 28.2. Android Studio installed; no `gradle` or `kotlinc` on PATH | Quest app uses the Gradle wrapper |
| Test tools | `tcpdump` and `jq` present. iperf3, socat and dnsmasq absent | M0 uses tcpdump, ping, python3 and the Quest's `toybox nc`. iperf3 is optional later |
| Apps | VD Streamer 1.34.22, Meta Quest Virtual Display 107.0.0.1.108, OrbStack and iTerm2 in /Applications; CrossOver in ~/Applications | — |
| Network | en0 <lan-ip>/24, default route via <lan-ip>. 192.168.42.0/24 unused. OrbStack bridge100–105 (192.168.138/23, 192.168.{107,117,148,155,156}/24). `net.inet.ip.forwarding=1`. `AllowNewInterfaces` off | Default subnet is 192.168.42.0/24, with a collision check at runtime |
| Service order | Wi-Fi, USB 10/100/1000 LAN (en13), en15, Thunderbolt Bridge, iPhone USB, then VPNs (Tailscale, ProtonVPN, Shadowrocket, Pangolin, …). USB NICs en8 (RTL8156, NCM) and en13–15 are **not attached today** | A new Ethernet service lands below Wi-Fi. The RTL8156 is a test fixture only if you plug it in |
| TRM | ConfigProfile 2 (Ask), DeviceLocked No, CacheMissCount 0, threshold 5, GracePeriodTimeout 259200, PolicyTimeout 604800 (meaning [U]), **RelaxedPeriod Yes, UnlockedPeriod Yes (86400)** | Record TRM keys on every run (E1, E10) |
| Interface names | NetworkInterfaces.plist permanently reserves one enN per MAC it has seen; an iPhone NCM took en16 | The Quest host MAC changes on each Quest reboot [V], so expect a new `enN` per Quest boot [L, E10]. Never cache `enN` |
| pf | `/etc/pf.conf` has `nat-anchor "com.apple/*"`; `pfctl -E`/`-X token` documented | Anchor `com.apple/questlink` with token-based enable |
| Port 8082 | **OrbStack (pid 1611) listens on 127.0.0.1:8082** | See §0, item 1 |
| ALVR session | `client.wired` pinned to 127.0.0.1. `3051/1857/4253.client` pinned to <lan-ip> (a stale Wi-Fi subnet). `stream_protocol {"variant":"Udp"}`. `client_discovery {"enabled":true,"content":{"auto_trust_clients":true}}`. `wired_client_autolaunch=true`. `wired_client_type {"variant":"Store"}`, so the package is `alvr.client`. `session.json.bak-wired` exists | The pin removes `client.wired`, clears the Wi-Fi pins, adds `quest.ncm`, sets Tcp and turns discovery off |
| ALVR source | `ext/ALVR` v20.14.1-2-g7f95262b. `ServerRequest`/`ClientListAction`/`PathSegment` shapes live in `alvr/packets/src/lib.rs`. `SetValues` errors are swallowed (`.ok()`, `web_server.rs:~201`). `wired = client_ip.is_loopback()` (`connection.rs:842`) | Always read `session.json` back after any live change |
| wine-vr | `./demo.sh run\|stop\|doctor --bottle <b>`. `run.sh` clears stale 9943/9944 forwards unless `--wired` is passed. The pre-init sync rewrites only bitrate, buffering and codec keys [V-here per prior read] | Hand edits to `client_connections`, `stream_protocol` and `client_discovery` persist |

### 1.3 The six gates

These are the actual "macOS weirdness". The driver binds fine [L]; every problem sits above it.

| # | Gate | Symptom on the Mac | Windows | Handled by |
|---|---|---|---|---|
| 1 | TRM accessory approval. Each USB composition (VID, PID, serial, class triples) is a new accessory | Device enumerates but publishes no interfaces: no enX, and no adb over USB | none | One Allow click per composition while unlocked. The companion refuses to switch compositions while locked unless the target is approved (S0/S4) |
| 2 | InterfaceNamer ignores unknown MACs that arrive while locked, and never retries after unlock | AppleUSBNCMData present, no BSD name | none | Enumerate while unlocked. After unlock, force re-enumeration (`svc usb resetUsbGadget` [L], or a replug). `--allow-new-interfaces` is opt-in |
| 3 | Nothing raises enX, so AppleUSBNCMData never selects alt 1, so the Quest never gets carrier | enX down; Quest `usb0` NO-CARRIER | NDIS enables the adapter at bind | A persistent, router-less Mac service: ipconfigd raises enX on every attach (E3.persist) |
| 4 | Nobody serves an address: the Quest is a DHCP client, not a tethering server | 169.254 on the Mac; endless DISCOVER from the Quest | the user's DHCP + WinNAT script | Quest static via `cmd ethernet`. Fallback: libpcap DHCP responder |
| 5 | Routing. On the Quest, self-initiated and UDP traffic follow Wi-Fi while `usb0` is not the default network | Mac-dialled TCP works; UDP and Quest-initiated traffic leave via Wi-Fi | same, hidden by NAT | TCP for ALVR. `--share` NAT validation makes `usb0` the default. The Mac service has no router, so the Mac default route cannot move |
| 6 | App gates: Local Network Privacy (LNP), VPN and filter extensions | EHOSTUNREACH, silent drops, false send success | n/a | Launch from Terminal.app. Root CLI and launchd daemons are exempt. `doctor` flags extensions |

### 1.4 Unknowns that decide the plan

| ID | Unknown | Settled by |
|---|---|---|
| U1 | Quest 3 `usb0` in Mode B is tracked by EthernetTracker (GLOBAL) and accepts `cmd ethernet … usb0 static`, or sends DISCOVER | E2, E3 |
| U2 | TCP the Mac dials to a non-default `usb0` is answered over `usb0`, for the shell uid (E3) and the ALVR app uid (E5) | E3, E5 |
| U3 | An unvalidated `usb0` keeps its address for 10+ minutes while Wi-Fi is the default | E3 hold |
| U4 | macOS 27 auto-creates a service for the Quest's enX (SCMonitor) [C] | E1 |
| U5 | A persistent router-less service re-raises enX by itself on re-attach | E3.persist |
| U6 | PID and interface set per composition; prompt behaviour under RelaxedPeriod | E1, E6, E10 |
| U7 | NAT validates `usb0` (and how fast), including with a VPN utun as egress | E4, E11 |
| U8 | VD Mode A works end to end on macOS 27 with the stable Streamer 1.34.22 | E6 |
| U9 | A STATIC `usb0` config applies in LOCAL mode, giving Mode A IPv4, and does not break VD | E6b |
| U10 | TRM escalation after one cache miss vs five; enN churn per Quest reboot | E10 |

---

## 2. Architecture

### 2.1 Overview

```
Quest 3 (HzOS 2.7 expected, 5.10 f_ncm)      USB 3 C-C, built-in port       MacBook Pro (macOS 27.0)
+-------------------------------------+                                  +--------------------------------------+
| usb0 (dev_addr fixed by Meta)       |===== CDC-NCM (NTB16, MTU 1500) ==| AppleUSBNCMControl/Data -> enX       |
|  Mode B: EthernetService GLOBAL     |                                  |  enX MAC = Quest host_mac (random    |
|   static 192.168.42.2/24            |                                  |   per Quest boot)                    |
|   [share: gw .1, dns R]             |                                  | Service "Quest NCM (questlink) enX": |
|  Mode A: app-held TRANSPORT_USB ->  |                                  |  IPv4 Manual 192.168.42.1/24, NO     |
|   LOCAL, fe80 (+.2 if STATIC        |                                  |  router; IPv6 LinkLocal;             |
|   applies [U, E6b])                 |                                  |  PrimaryRank Never (belt & braces)   |
| ALVR client 0.0.0.0:9943/9944       |<-- TCP dial (control + stream) --| wine-vr ALVR core (Terminal-launched)|
| VD headset app (Mode A)             |<-- fe80 -------------------------| VD Streamer 1.34.22                  |
| [share] default via 192.168.42.1    |--> pf nat-anchor com.apple/questlink -> primary egress (en0 / utun)     |
+-------------------------------------+                                  +--------------------------------------+
Control plane: adb over Wi-Fi (<quest-wifi-ip>:5555) for anything that switches the USB composition;
               adb over USB otherwise; adb over 192.168.42.2:5555 as a recovery path once the link is up.
```

### 2.2 Mode B (primary): responsibilities

**Quest composition:**
- `svc usb setFunctions ncm` gives VID 0x2833 with PID 0x500A (NCM+ADB). With `persist.ovr.usb.xrsp_enabled` set it gives 0x5018 (XRSP+NCM+ADB) [V, 2.7 HAL table].
- In ioreg decimal these are idVendor 10291 and idProduct 20490 / 20504.
- Never pass `ncm,adb`; it throws. ADB is ORed back in automatically [V].

**Mac side:**
- A service with IPv4 Manual and **no Router key** cannot become primary, so the Mac default route cannot move [V, IPMonitor].
- IPv6 LinkLocal keeps fe80 present for diagnostics and Mode A.
- ipconfigd raises enX on attach and after wake, which gives the Quest carrier (Gate 3) [L until E3.persist].

**Quest address:** `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24`, with `--gateway 192.168.42.1 --dns R` added only when sharing. It persists in the tethering APEX's `ipconfig.txt` [V], so:
- `down` reverts it to `dhcp` by default.
- `--sticky` keeps it, and is allowed only after E6b passes.
- `doctor` and `up` always detect foreign STATIC configs, for example Steam Link's 10.86.13.37/29.

**Proof of life:** the first Ethernet frame from the Quest's `usb0` MAC, seen with libpcap. "status: active" is only a hint, because it can be stale on both sides.

### 2.3 Mode A (control experiment and fallback)

- An app calls `ConnectivityManager.requestNetwork(TRANSPORT_USB, −INTERNET, −TRUSTED)`.
- The OS switches `usb0` to LOCAL mode: IPv6 link-local, no internet [V, Meta docs].
- Holding the request pre-empts Mode B.
- **Virtual Desktop Beta + VD Streamer 1.34.22** (E6) exercise TRM, binding, naming, Gate 3 and IPv6 against Meta's own Quest-side implementation, with no code.
- **F1** (Keeper app plus relays) exists only for stock ALVR, and only if Mode B addressing dies. If E6b shows a STATIC config applies in LOCAL, F1 needs only a request holder and no relay.

### 2.4 Which mode serves which app

| Use | Link mode | Quest address | Mac address | Transport | Quest app? |
|---|---|---|---|---|---|
| wine-vr / stock ALVR | **B** | 192.168.42.2 | 192.168.42.1 | TCP 9943/9944, the Mac dials | no |
| Mac-to-Quest internet (optional) | **B + share** | .2, gw .1, DNS R | .1 + pf NAT | any | no |
| Virtual Desktop (desktop streaming) | **A** (VD's own request) | fe80 (+.2 if E6b) | fe80%enX | VD's own | no |
| Meta Quest Virtual Display / Remote Desktop | none (default composition) | Wi-Fi | Wi-Fi | cloud-signalled WebRTC | no |
| ALVR when Mode B can't address `usb0` | **A + Keeper** | fe80 (+.2 if E6b) | fe80 / .1 | TCP relay, or direct if E6b | yes |

Modes A and B are mutually exclusive on one cable [V]. `questlink mode` detects which one is active; the companion never fights an app-held request.

### 2.5 Quest-side routing matrix (what stock apps get)

| Traffic pattern | Mode B, Wi-Fi default (no share) | Mode B + share (`usb0` validated, default) | Mode A (LOCAL) |
|---|---|---|---|
| Mac dials the Quest over TCP (ALVR control + TCP stream) | Works [L: `tcp_fwmark_accept=1`; E3/E5] | Works | Only with IPv4 on `usb0` (E6b) or via the Keeper relay |
| Mac to Quest ICMP | Works [L] | Works | same |
| UDP on an unbound Quest socket (ALVR UDP stream) | **Fails**: replies route via wlan0 [L, Quest 3 v207 eth0 observation] | Works | Fails unless the app binds to the Network |
| Quest-initiated (browser, Moonlight/VNC client, ALVR discovery broadcast, system) | Leaves via wlan0 | Over the cable | Only apps bound to the Network (VD does) |
| Internet on the Quest via the Mac | no | yes | no (VpnService stretch only) |
| fe80 between the two ends | yes | yes | yes |

**Rules that follow from the matrix:**
- The ALVR proof uses TCP. That is like-for-like with the adb-forward baseline, which also uses TCP because loopback forces it.
- UDP, and "everything just works", need `--share` validation (or Quest Wi-Fi off, F4).
- ALVR IPv4 broadcast discovery follows the default network, so the proof pins by IP and turns discovery off.
- The companion learns the Quest's addresses over adb, or via NDP if adb is gone. It never relies on Bonjour.

### 2.6 Addressing and naming

| Mode | Subnet | Mac | Quest | Notes |
|---|---|---|---|---|
| B (default) | 192.168.42.0/24 | .1 | .2 | Alternates: 192.168.231.0/24, then 172.29.42.0/24 (`--subnet`) |
| B, IPv6 | fe80::/64 | fe80::…%enX | fe80::…%usb0 | Diagnostics. Always scoped: `net.inet6.ip6.use_defaultzone=0` [V] |
| A | fe80::/64 | fe80::…%enX | fe80::…%usb0 | Link-local by design |
| F2 (spike) | 10.86.13.32/29 | .38 | .37 | [U] |
| F3 (Internet Sharing) | 192.168.2.0/24 on bridge106 [L] | .1 | leased | Only on its trigger |

**Runtime collision check.** The candidate subnet is checked against every `getifaddrs` prefix, every route, the Quest's own `wlan0` subnet (read over adb), and this reserved list:
- 192.168.1/24 and the current en0 subnet
- 192.168.2–17/24 (Internet Sharing)
- 192.168.64/24 (Apple container)
- 192.168.138/23 and 192.168.{107,117,148,155,156}/24 (OrbStack)
- 100.64/10 (Tailscale)
- 10.2.0/24 (ProtonVPN)
- 10.86.13.32/29 (Steam Link)

**Service identity:**
- The service is named `Quest NCM (questlink) enX` and bound to the current enX.
- A Quest reboot produces a new host MAC, and probably a new `enN` [L, E10]. The companion creates a service for the new interface and garbage-collects **only** services it created (recorded in its journal) whose interface is gone.
- It never edits NetworkInterfaces.plist, never changes the service order, and never touches other services.

### 2.7 USB composition policy

- Compositions: Default (XRSP/COMMLIB/Highwind + ADB), Mode B (0x500A or 0x5018), and Mode A (app-requested; recorded in E6). Each needs one TRM approval.
- **Restoring Default:** a replug resets functions to default [L, AOSP UsbDeviceManager].
  - `svc usb setFunctions` with no argument may give charging+ADB rather than Meta's default set [U; check the PID in E1/E10].
  - `svc usb resetUsbGadget` re-enumerates the **current** composition [L]. That is the tool for Gate 2, not for restoring Default.
- **The companion never:**
  - switches compositions while the Mac is locked, unless the target signature is approved (§5.6.3);
  - switches while a TRANSPORT_USB request is active;
  - switches over the USB transport when an adb-over-Wi-Fi transport exists.

### 2.8 One recommendation per concern

Fallbacks below fire only on named outcomes.

| Concern | Recommended | Fallback, and its trigger |
|---|---|---|
| Link mode | Mode B | **F1** (Mode A + Keeper): on `E3.CMD_REJECTED` together with `E2.NO_DISCOVER`, or on `E3.NO_INBOUND` together with `E4.NOT_VALIDATED`. **F5** (Ethernet adapter): on `E1.NO_BIND`, or `E2.NO_CARRIER` persisting, **and** `E6.FAIL` |
| Raising enX (Gate 3) | Persistent SCPreferences service (IPv4 Manual, no router, IPv6 LinkLocal) | Per-attach `ipconfig set enX MANUAL …` by `up`/`watch`, on `E3.PERSIST_FAIL` or an SC commit error |
| Quest IPv4 | `cmd ethernet set-ip-configuration usb0 static` | libpcap DHCP responder, on `E3.CMD_REJECTED` together with `E2.DISCOVER_SEEN`. In M0 only, Internet Sharing (F3) stands in |
| Quest-side persistence | Revert `usb0` to `dhcp` on `down` | `--sticky` (opt-in), allowed only after `E6b.STATIC_IN_LOCAL` and not `E6b.STATIC_BREAKS_VD` |
| Mac-to-Quest internet | pf anchor NAT plus Quest gateway/DNS | Internet Sharing, on `E4.PF_FAIL`, or `E4.NOT_VALIDATED` where E4-A validates |
| Keeping Quest Wi-Fi after validation | Opt-in `--keep-quest-wifi` (`wifi_always_requested=1`, prior value journaled). `share on` warns when it is off | — |
| ALVR transport | TCP to 192.168.42.2 | UDP (F4) only after `E4.VALIDATED` and `E5.PASS`. F1 (loopback relay) on `E5.FAIL` for a non-LNP reason |
| ALVR pin mechanism | Offline `session.json` edit while the core is stopped | Live dashboard API via `http://192.168.42.1:8082` (never 127.0.0.1), only for mid-session changes, only when a `*:8082` listener exists |
| adb driving | Exec `adb` as `$SUDO_USER` (never as root); `adb track-devices -l` for hotplug | Swift smart-socket client, on `M1.ADB_FLAKY` (spawn latency over 1 s, or server churn in `watch`) |
| Locked Mac | Refuse a switch unless the target composition is approved and within grace | Refuse every switch while locked, on `E10.ESCALATE_1` |
| Naming after a Quest reboot | Re-enumerate while unlocked (`resetUsbGadget` [L] or replug) | Opt-in `sudo scutil --allow-new-interfaces on`, on `E10.UNNAMED_PERSISTS` |
| Menu bar privilege | `SMAppService.daemon` root helper | Legacy `sudo questlink daemon install` LaunchDaemon, on `M4.0.SIGNING_FAIL` |
| LNP for Wine | Launch wine-vr from Terminal.app (exempt) or iTerm2 (allowed) | `AllowedEthernetLocalNetworkAddresses` + reboot, on `E5.LNP`; then F1 |

### 2.9 Fallback definitions and exclusions

- **F1:** Mode A + Quest Keeper relay (fe80 → 127.0.0.1) + Mac relay (127.0.0.1 → fe80%enX). The ALVR entry `quest.relay` → 127.0.0.1 is treated as wired, so it uses TCP.
- **F2:** HzOS 2.7 Steam-Link-style `SET_LOCAL_IP` (10.86.13.37/29). Spike only; largely replaced by E6b.
- **F3:** macOS Internet Sharing as zero-code DHCP+NAT. Manual procedure only.
- **F4:** `usb0` validated as the Quest default (or `svc wifi disable`), then UDP streaming.
- **F5:** a USB-C Ethernet adapter with PD pass-through on the Quest, cabled to the Mac's RTL8153 (en13 when attached), using the same service/NAT recipe.
- **F6:** today's baseline, `adb forward tcp:9943/9944` with `client.wired`. Kept working as the A/B comparison.
- **Not pursued:**
  - RNDIS (no macOS driver; Meta's HAL rejects it).
  - ECM (not a settable function; macOS 27 DriverKit TX stall).
  - AOA (the framework blocks it).
  - Mac as USB device (the Quest's `cdc_ncm` lacks the patches).
  - A user-space NCM driver on the Mac (kills adb; no precedent).
  - The Quest as tethering server.
  - Meta Quest Virtual Display over USB (server-gated, and needs vendor interfaces).

---

## 3. Milestones

| M | Deliverable | Depends on | Exit criteria | Est. |
|---|---|---|---|---|
| **M0-S1** | Ladder Session 1 (E0, E1, E2, E3, E5), evidence, decision gate (§4.8) | none | Every row of §4.8 resolved | ~2 h headset |
| **M1** | `questlink` v0.1: `doctor/status/snapshot/mode` (read-only), `up/down/repair/test`, `alvr pin/unpin/launch/status`, journal, `--dry-run`, PeerSniffer, RouteGuard. DHCP responder **only if** §4.8 says so | M0-S1 | V1–V6, V9, V12 | 3–4 days (+1–2 if DHCP) |
| **M0-S2** | E4 (sharing), E6/E6b (VD Mode A, static in LOCAL) | M0-S1 | §4.8 rows for sharing and sticky | ~1.5 h |
| **M2** | `share on\|off`, `up --share`, EgressWatcher, `vd prepare`, `--sticky` (if E6b passes) | M1, M0-S2 | V7, V8, V14 | 1–1.5 days |
| **M0-S3** | E10 (lock/TRM/naming/churn matrix), E11 (interference, perf), E12 (Virtual Display regression) | M1 (for E11) | Rule table in `docs/decisions.md` | ~2 h |
| **M3** | `watch` re-arm loop, lock gate, ApprovedStore (rules encoded from E10) | M2, M0-S3 | V10, V11, V13 | 2 days |
| **M4** | Menu bar app + root daemon. **M4.0 signing spike first** | M3 | V15 | 3–4 days |
| **M5** | *Conditional:* Quest app "NCM Keeper" (probe → relay → diagnostics); E7–E9 | trigger F1, or a wish for E7 | V16 | 3–4 days |
| **M6** | *Stretch:* Mode A VpnService internet (gnirehtet fork) | M5, explicit request | Browser over Mode A | not scheduled |

`questlink doctor` is read-only and can be built early, alongside M0, to help collect evidence.

---

## 4. Milestone 0: on-device feasibility ladder (no code)

### 4.0 Prerequisites

- **Quest 3:** developer mode, adb authorized for this Mac, battery above 50%.
- **Cable:** a 5 Gb/s USB-C data cable plugged **directly** into a built-in Mac port. No hub or dock.
- **Mac:** **unlocked** for all of Session 1. Unplug the iPhone and all other USB NICs.
- **Terminals:** four Terminal.app windows, which are LNP-exempt. T1 control, T2 logs, T3 tcpdump, T4 spare.
- **Temporary changes.** M0 deliberately changes things; §4.2 lists how to undo each one:
  - Mac: a service, `ipconfig`, pf.
  - Quest: USB function, `usb0` config, settings.
- **Optional, keep the headset awake off-head:** `adb -s $Q shell am broadcast -a com.oculus.vrpowermanager.prox_close` [L, community-documented]. Revert with `…automation_disable`.

### 4.1 Shell helpers

Paste these into every zsh window. They are saved later as `scripts/m0/lib.sh`.

```zsh
export NCM=~/projects/personal/ncm
export EV=$NCM/docs/evidence/$(date +%Y%m%d-%H%M); mkdir -p "$EV"     # absolute path: survives cd
export Q=<usb-serial>             # USB line of `adb devices -l` (USB serial == adb serial)
export QW=<quest-wifi-ip>:5555    # set in E0; used for every composition switch
export QIP=192.168.42.2 MIP=192.168.42.1
export ALVRS="$HOME/Library/Application Support/OXRSys/alvr/session.json"
qif() {   # BSD name(s) of network interfaces under any VID 0x2833 device
  ioreg -a -r -c IOUSBHostDevice -l -w0 | python3 -c '
import plistlib,sys
raw=sys.stdin.buffer.read(); devs=plistlib.loads(raw) if raw.strip() else []
def walk(n):
    b=n.get("BSD Name")
    if isinstance(b,str) and b.startswith("en"): yield b
    for c in n.get("IORegistryEntryChildren",[]): yield from walk(c)
for d in devs:
    if d.get("idVendor")==0x2833: print(*sorted(set(walk(d))))'; }
qusb() {  # VID/PID/serial/product + interface triples + attached driver classes
  ioreg -a -r -c IOUSBHostDevice -l -w0 | python3 -c '
import plistlib,sys
raw=sys.stdin.buffer.read(); devs=plistlib.loads(raw) if raw.strip() else []
def ifs(n):
    if "bInterfaceClass" in n:
        drv=[c.get("IOObjectClass") for c in n.get("IORegistryEntryChildren",[])]
        yield (n.get("bInterfaceNumber",0),n["bInterfaceClass"],n.get("bInterfaceSubClass",0),n.get("bInterfaceProtocol",0),drv)
    for c in n.get("IORegistryEntryChildren",[]): yield from ifs(c)
for d in devs:
    if d.get("idVendor")!=0x2833: continue
    print("VID %04x PID %04x serial=%s product=%s bcdUSB=%x" % (d["idVendor"],d.get("idProduct",0),
          d.get("kUSBSerialNumberString") or d.get("USB Serial Number"),d.get("kUSBProductString") or d.get("USB Product Name"),d.get("bcdUSB",0)))
    for i in sorted(ifs(d)): print("  if%d %02x/%02x/%02x %s" % (i[0],i[1],i[2],i[3],i[4]))'; }
qncm() { ioreg -r -c AppleUSBNCMData -l -w0 | grep -E '"BSD Name"|IOLinkStatus|IOControllerEnabled|IOMACAddress|InputSize|OutputSize|NTBFormat|DatagramSizeMax|HiddenInterface'; }
qtrm() { ioreg -r -c IOPortTransportState -l -w0 | grep -E 'TRM_TransportRestricted|HashStatusDescription|AuthorizationStatusDescription'
         ioreg -r -c AppleCredentialManager -l -w0 | grep -oE '"TRM_(DeviceLocked|CacheMissCount|CacheMiss|RelaxedPeriod|UnlockedPeriod)" = [A-Za-z0-9]+' | sort -u; }
qnet() { route -n get default | grep -E 'gateway|interface'; scutil --nwi | head -20; scutil --dns | grep nameserver | sort -u; }
qbulk() { # qbulk <send|recv> <port> <seconds>: TCP bulk test pinned to $IF with IP_BOUND_IF (25)
  python3 - "$QIP" "$2" "$IF" "$1" "${3:-10}" <<'EOF'
import socket,sys,time
host,port,ifn,mode,secs=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4],float(sys.argv[5])
s=socket.socket(); s.setsockopt(socket.IPPROTO_IP,25,socket.if_nametoindex(ifn)); s.connect((host,port))
n=0; t0=time.time(); buf=b"\0"*(1<<20)
while time.time()-t0<secs:
    if mode=="send": s.sendall(buf); n+=len(buf)
    else:
        d=s.recv(1<<20)
        if not d: break
        n+=len(d)
dt=time.time()-t0; s.close(); print(f"{mode} via {ifn}: {n*8/dt/1e6:.0f} Mbit/s over {dt:.1f}s")
EOF
}
```

The `qif` walk has been checked only against an empty registry [U]. At E1, cross-check it with `networksetup -listallhardwareports`.

### 4.2 Recovery kit (read before starting)

| Undo | Command |
|---|---|
| Quest USB back to Default | Replug (primary). Or `adb -s $QW reboot`. `svc usb setFunctions` with no argument is [U] |
| Force re-enumeration of the current composition | `adb -s $QW shell svc usb resetUsbGadget` [L] or replug |
| Quest `usb0` config | `adb -s $QW shell cmd ethernet set-ip-configuration usb0 dhcp` |
| Quest Wi-Fi / linger | `adb shell svc wifi enable`; `adb shell settings delete global wifi_always_requested` (or restore the recorded prior value) |
| Mac temporary IP | `sudo ipconfig set $IF NONE`; `sudo ipconfig set $IF NONE-V6`. Overrides do not survive detach [L] |
| Mac service created in M0 | `sudo networksetup -removenetworkservice "Quest NCM"` (only services you created) |
| pf | `sudo pfctl -a com.apple/questlink -F all; sudo pfctl -X $TOKEN`. **Never** `pfctl -d`, never flush the main ruleset |
| ALVR | `cd ~/projects/personal/wine-vr && ./demo.sh stop --bottle <b>`, then `cp "$ALVRS.bak-ncm" "$ALVRS"`. Never delete `session.json` |
| Headset proximity | `adb shell am broadcast -a com.oculus.vrpowermanager.automation_disable` |
| adb gone on both USB and Wi-Fi | Reboot the Quest with the power button, then replug. If the link was up: `adb connect 192.168.42.2:5555` |

### 4.3 Session 1: Quest mode, Gate 3, IPv4, ALVR (about 2 h)

#### E0: Baseline, confounders, recovery channel (15 min)

```zsh
{ date; sw_vers; kmutil showloaded 2>/dev/null | grep -i cdc.ncm
  ifconfig -l; networksetup -listallhardwareports; networksetup -listallnetworkservices
  networksetup -listnetworkserviceorder; qnet; netstat -rn -f inet | head -40
  scutil --allow-new-interfaces; qtrm; sudo lsof -nP -iUDP:67; lsof -nP -iTCP:8082 -sTCP:LISTEN
  echo 'show Plugin:InterfaceNamer' | scutil; sudo pfctl -s References; sudo pfctl -sr
  systemextensionsctl list; scutil --nc list; } > $EV/E0-mac.txt 2>&1
cp "$ALVRS" "$ALVRS.bak-ncm"
adb devices -l
{ for p in ro.hzos.build.display_name ro.vros.build.version ro.product.device ro.build.fingerprint \
           persist.ovr.usb.xrsp_enabled sys.usb.config sys.usb.state; do echo "$p=$(adb -s $Q shell getprop $p)"; done
  adb -s $Q shell svc usb getFunctions 2>&1; adb -s $Q shell svc usb getGadgetHalVersion 2>&1; adb -s $Q shell svc usb 2>&1 | head -30
  adb -s $Q shell dumpsys tethering | grep -iE 'regex|ncm'
  adb -s $Q shell device_config get hzos_system_sessionless adc_ethernet_over_usb_enabled
  adb -s $Q shell settings get global wifi_always_requested
  adb -s $Q shell 'toybox nc --help 2>&1 | head -5'
  adb -s $Q shell pm list packages | grep -iE 'virtualdesktop|steamlink|valve|wivrn|alvr|vpn|proton|tailscale'
  adb -s $Q shell ip -4 addr show wlan0; } > $EV/E0-quest.txt 2>&1
adb -s $Q shell dumpsys ethernet > $EV/E0-dumpsys-ethernet.txt          # regex ((eth\d)|(usb\d))? usb0 IpConfiguration / STATIC?
adb -s $Q shell dumpsys connectivity > $EV/E0-dumpsys-connectivity.txt; grep -n 'Transports: USB' $EV/E0-dumpsys-connectivity.txt
adb -s $Q shell cmd ethernet help > $EV/E0-cmd-ethernet-help.txt 2>&1   # record exact set-ip-configuration + --gateway/--dns syntax
adb -s $Q shell am force-stop <each VD / Steam Link / WiVRn package found above>
WIP=$(adb -s $Q shell ip -4 addr show wlan0 | awk '/inet /{sub("/.*","",$2);print $2}')
adb -s $Q tcpip 5555; sleep 3; adb connect $WIP:5555; export QW=$WIP:5555; adb -s $QW shell echo ok
```

Always pass `-s`: from here on there are two transports for the same Quest.

**Pass when:**
- HzOS is 2.6 or later (2.7 expected).
- The Ethernet regex includes `usb\d`.
- There is no `Transports: USB` request.
- No STATIC config is stored for `usb0`.
- `cmd ethernet help` lists `set-ip-configuration`.
- toybox `nc` is present.
- `adb -s $QW` works.

**Outcomes:**

| Outcome | Action |
|---|---|
| `E0.STATIC_LEFTOVER` (e.g. 10.86.13.37/29) | Note it; E3 overwrites it |
| `E0.NO_CMD_ETHERNET` | E3 takes the DHCP branch |
| `E0.OLD_HZOS` (<2.6) | Mode B still applies; E6 may be unavailable |
| `E0.USB_REQUEST_PERSISTS` | Find the holder uid (`adb shell cmd package list packages -U \| grep <uid>`) and disable that app for the session |

#### E1: Mode B enumeration (TRM, driver, naming, service auto-creation) (15 min)

T2:

```zsh
/usr/bin/log stream --style compact --predicate 'subsystem == "com.apple.SystemConfiguration" OR process == "configd" OR process == "UserEventAgent" OR (process == "kernel" AND (eventMessage CONTAINS[c] "ncm" OR eventMessage CONTAINS[c] "restrict" OR eventMessage CONTAINS[c] "authoriz"))' | tee $EV/E1-log.txt
```

T1 (Mac unlocked):

```zsh
qtrm > $EV/E1-trm-before.txt
adb -s $QW shell svc usb setFunctions ncm; date     # over Wi-Fi: the USB transport is the one being torn down
# If "Allow accessory to connect?" appears on the Mac, click Allow. Record whether it appeared (RelaxedPeriod=Yes today).
adb -s $Q wait-for-device; adb -s $Q shell svc usb getFunctions 2>&1
qusb | tee $EV/E1-qusb.txt; qncm | tee $EV/E1-qncm.txt; qtrm | tee $EV/E1-trm-after.txt
ioreg -r -c AppleUSBNCM11Control -w0 | head -3                 # expect nothing (NCM 1.0 path)
ioreg -l -w0 -r -c IOPortTransportState > $EV/E1-trm-tree.txt   # where TRM state sits vs the device (for M1)
ioreg -a -r -l -w0 -c IOUSBHostDevice > $EV/E1-ioreg-usb.plist  # fixture for M1 tests
export IF=$(qif); echo "IF=$IF"
networksetup -listallhardwareports | grep -B1 -A2 "Device: $IF"   # Hardware Port name ("Quest 3"? [U])
networksetup -listnetworkserviceorder | grep -B1 "Device: $IF"    # auto-created service? (U4)
ifconfig -v $IF | grep -E 'flags|status|ether|inet'               # already UP?
echo 'show Plugin:InterfaceNamer' | scutil; qnet                  # default route unchanged?
system_profiler SPUSBHostDataType > $EV/E1-usb.txt                 # negotiated speed
```

**Pass when:**
- VID 10291 with PID 20490 or 20504 (record which).
- Interfaces 02/0D/00 and 0A/00/01 are present.
- The driver is `AppleUSBNCMControl`/`AppleUSBNCMData`, not NCM11.
- `$IF` is named.
- TRM shows authorized.
- adb over USB comes back.

Also record whether a service was auto-created, whether `$IF` is already UP, the hardware port name, the speed, and the NTB property names.

**Outcomes:**

| Outcome | Symptom | Action |
|---|---|---|
| `E1.TRM_BLOCK` | Device present with no interfaces; TransportRestricted | Unlock, click Allow, re-run `qtrm`. If no prompt ever appears and RelaxedPeriod=Yes, record it and re-test in E10 |
| `E1.NCM11` | NCM11 driver bound | Continue; flag it (alt-0 bug watch) [U] |
| `E1.NO_BIND` | 02/0D present, no AppleUSBNCM* | Save the full ioreg dump and descriptors, run **E6 now** as the control, then go to §4.8 |
| `E1.UNNAMED` | AppleUSBNCMData present, no BSD name | InterfaceNamer `_Locked_`? Unlock, then `adb -s $QW shell svc usb resetUsbGadget` [L] or replug |
| `E1.ADB_LOST` | USB adb gone | Continue with `adb -s $QW` |
| `E1.REVERTS` | Composition falls back to Default on its own | Record how long it lasted; `watch` must re-arm it |

#### E2: Gate 3 causality and the Quest's DHCP client (10 min)

T3:

```zsh
sudo tcpdump -ni $IF -e -vv 'udp port 67 or udp port 68 or icmp6 or arp' | tee $EV/E2-tcpdump.txt
```

T1:

```zsh
adb -s $Q shell ip link show usb0                      # expect NO-CARRIER if $IF is not UP
sudo ifconfig $IF up                                   # temporary; skip if an auto-service already raised it
ifconfig -v $IF | grep -E 'flags|status'               # need RUNNING
ioreg -r -c AppleUSBNCMData -l -w0 | grep -E 'IOControllerEnabled|IOLinkStatus'   # Yes / 3
adb -s $Q shell ip link show usb0                      # expect ...LOWER_UP
export QMAC=$(adb -s $Q shell cat /sys/class/net/usb0/address | tr -d '\r'); echo $QMAC   # fallback: `ip link show usb0` link/ether [L]
sudo tcpdump -ni $IF -e -c 3 ether src $QMAC           # PROOF OF LIFE
adb -s $Q shell dumpsys ethernet | grep -iE -A6 'usb0' | tee $EV/E2-ethernet.txt
adb -s $Q logcat -d -b all | grep -iE 'EthernetTracker|EthernetNetworkFactory|IpClient.*usb0|DhcpClient' | tail -40 > $EV/E2-logcat.txt
ping6 -c3 ff02::1%$IF                                  # bonus: Quest fe80 answers [L]
sudo ifconfig $IF down; sleep 3; adb -s $Q shell ip link show usb0    # expect NO-CARRIER
sudo ifconfig $IF up;   sleep 3; adb -s $Q shell ip link show usb0    # expect LOWER_UP again
```

**Pass when:**
- `$IF` is UP and RUNNING with `IOControllerEnabled=Yes`.
- The Quest's carrier follows `$IF` up and down.
- A frame from `$QMAC` is captured.
- tcpdump shows DHCPDISCOVER (flags 0x0000) from `$QMAC`. That is outcome `E2.DISCOVER_SEEN`.
- dumpsys shows `usb0` tracked in GLOBAL mode.

If the Mac service is DHCP, its own DISCOVER and a 169.254 address after about 15–19 s are the expected "two clients" symptom.

**Outcomes:**

| Outcome | Symptom | Action |
|---|---|---|
| `E2.NOT_RUNNING` | UP but not RUNNING, or IOControllerEnabled=No: enable() failed | `log show --last 2m --predicate 'process == "kernel"' \| grep -i ncm`, replug, try `sudo ipconfig set $IF AUTOMATIC-V6`. If it persists, run E6, then §4.8 |
| `E2.NO_CARRIER` | Mac RUNNING, Quest NO-CARRIER | Save `ioreg -r -c IOUSBHostInterface -l -w0 \| grep -i alternate`, replug. If it persists, run E6, then §4.8 |
| `E2.LOCAL` | A USB request is held | Find it (`dumpsys connectivity \| grep -B3 -A12 'Transports: USB'`), force-stop it, repeat |
| `E2.STATIC` | Carrier, no DISCOVER, STATIC stored | Go to E3, which overwrites it |
| `E2.UNTRACKED` | Carrier, but `usb0` is not in EthernetTracker | Try E3 anyway. If E0 showed `adc_ethernet_over_usb_enabled=false`, one try of `device_config put hzos_system_sessionless adc_ethernet_over_usb_enabled true` + replug [U; Meta may re-sync it; undo with `device_config delete …`] |
| `E2.NO_DISCOVER` | Tracked but no DISCOVER, and none of the above | Record it; decided by E3 |

#### E3: Static IPv4, Mac-dialled TCP, route safety, 10-minute hold, persistence (35 min)

E3a is the first proof:

```zsh
qnet > $EV/E3-pre.txt
sudo ipconfig set $IF MANUAL $MIP 255.255.255.0                   # temporary, no router
adb -s $Q shell cmd ethernet set-ip-configuration usb0 static $QIP/24   # exact syntax from E0 help [U for usb0]; a typo'd mode word stores UNASSIGNED
adb -s $Q shell ip -4 addr show usb0                              # inet 192.168.42.2/24 ... usb0
adb -s $Q shell dumpsys ethernet | grep -iE -A6 usb0 > $EV/E3-ethernet.txt
ping -b $IF -c 10 $QIP                                            # <-- FIRST PROOF (bound to $IF)
route -n get $QIP | grep -E 'interface|gateway'                   # interface: $IF (not utunN, not en0)
adb -s $Q shell 'echo hello-from-quest | toybox nc -l -p 5201' & sleep 1; nc -w 3 $QIP 5201
adb -s $Q shell 'toybox nc -l -p 5202' & sleep 1; echo hello-from-mac | nc -w 3 $QIP 5202; wait
adb -s $Q shell ip route get $MIP > $EV/E3-quest-route.txt; adb -s $Q shell ip rule > $EV/E3-quest-rules.txt   # expect dev wlan0 (record only)
```

E3b, the 10-minute hold:

```zsh
for i in $(seq 20); do date +%T; adb -s $Q shell ip -4 addr show usb0 | grep -c $QIP; ping -b $IF -c1 -t1 -q $QIP | tail -1; sleep 30; done | tee $EV/E3-hold.txt
qnet > $EV/E3-post.txt; diff $EV/E3-pre.txt $EV/E3-post.txt       # expect no differences
```

E3c, throughput. This is a crude figure: the toybox pipeline may be CPU-bound. iperf3 comes in E11.

```zsh
ping -b $IF -i 0.01 -c 2000 -q $QIP | tail -2
adb -s $Q shell 'toybox nc -l -p 5203 > /dev/null' & sleep 1; qbulk send 5203 10; wait
adb -s $Q shell 'toybox nc -l -p 5204 < /dev/zero' & sleep 1; qbulk recv 5204 10; kill %1 2>/dev/null
netstat -I $IF -b | tail -1; netstat -I en0 -b | tail -1
```

E3d, persistence: does a persistent service raise `$IF` on its own? This settles U5.

```zsh
SVC=$(networksetup -listnetworkserviceorder | grep -B1 "Device: $IF" | head -1 | sed -E 's/^\([0-9*]+\) //')   # auto-created service, if any
if [ -z "$SVC" ]; then
  HWPORT=$(networksetup -listallhardwareports | awk -v d="Device: $IF" '/^Hardware Port:/{p=substr($0,16)} $0==d{print p}')
  sudo networksetup -createnetworkservice "Quest NCM" "$HWPORT"; SVC="Quest NCM"      # log it; removed at R-CLEAN unless kept
fi
sudo networksetup -setmanual "$SVC" $MIP 255.255.255.0      # router omitted [U]; if rejected, use System Settings > Network > $SVC > TCP/IP: Manual, Router empty
networksetup -getinfo "$SVC"                                # must show no router; if a router appears, revert
sudo networksetup -setv6LinkLocal "$SVC"
# replug the cable (drops the temporary ipconfig override and resets the composition), then:
adb -s $QW shell svc usb setFunctions ncm; adb -s $Q wait-for-device; export IF=$(qif)
ifconfig $IF | grep -E 'flags|inet '                        # expect UP,RUNNING and inet 192.168.42.1 with no manual command
ping -b $IF -c3 $QIP                                        # Quest static persisted across the replug
```

**Pass when:**
- `usb0` has .2.
- Ping gives 0% loss.
- Mac-dialled TCP works both ways while Quest Wi-Fi stays the default network.
- The `qnet` diff is empty.
- The address survives the 10-minute hold.
- After the replug the link returns with only `setFunctions ncm`.

Also record the RTT and Mbit/s figures.

**Outcomes:**

| Outcome | Symptom | Action |
|---|---|---|
| `E3.CMD_REJECTED` | SecurityException, unknown command, or no address | See §4.8 |
| `E3.NO_PING` | Both ends addressed, no reply | Check RUNNING, `arp -an -i $IF`, the T3 tcpdump. Check `route get` for a utun. Disconnect ProtonVPN, Tailscale, TripMode, Cisco and Pangolin one at a time. `sudo pfctl -sr` |
| `E3.NO_INBOUND` | Ping works, TCP fails (U2 false) | Run E4 so `usb0` becomes the default, then retest |
| `E3.DECAY` | Address or network dropped during the hold (U3 false) | Record the timing and dumpsys reason. `watch` must re-apply the address, or rely on share validation |
| `E3.ROUTE_CHANGED` | `qnet` diff not empty | `sudo ipconfig set $IF NONE` immediately, and find where a router came from |
| `E3.PERSIST_FAIL` | enX not raised, or not addressed, after the replug | The CLI uses per-attach `ipconfig set` (§2.8) |

Leave the E3 state in place for E5.

#### E5: wine-vr + stock ALVR over the cable (30 min)

Follow **§9.1 steps 1–8 exactly**: stop the core, edit offline, start from Terminal.app, launch the client by hand, verify.

**Pass when:**
- `lsof` shows ESTABLISHED connections to `192.168.42.2:9943` and `:9944`.
- `quest.ncm.current_ip == "192.168.42.2"`.
- `$IF` byte counters grow at about the ALVR bitrate while en0 stays flat.
- 5 minutes of Beat Saber with no disconnects.
- Network latency p50 is at or below the adb baseline (2.7 ms) plus 1 ms.

**Outcomes:**

| Outcome | Action |
|---|---|
| `E5.LOOPBACK` (current_ip 127.0.0.1) | `client.wired` or a forward survived: stop, redo step 2, `adb forward --remove-all` |
| `E5.LNP` (`nc -vz $QIP 9943` gives EHOSTUNREACH from the same terminal app) | Relaunch from Terminal.app. Then try `sudo defaults write com.apple.network.local-network AllowedEthernetLocalNetworkAddresses -array 192.168.42.0/24` + reboot [L; macOS 27 bug r.181140179]. Then F1 |
| `E5.WIFI` (connects over Wi-Fi) | A pin or discovery is still active; recheck step 2 |
| `E5.STALL` | Confirm `Tcp` in `session.json`; `sudo tcpdump -ni $IF tcp port 9944`; then retry after E4 |

### 4.4 Session 2: sharing, VD Mode A, static in LOCAL (about 1.5 h)

#### E4: Mac-to-Quest internet: pf recipe first, zero-code only if triggered (25 min)

E4-B, the primary recipe. Wi-Fi is kept for the recovery channel, and the prior value is recorded.

```zsh
adb -s $Q shell settings get global wifi_always_requested > $EV/E4-wifi-prior.txt
adb -s $Q shell settings put global wifi_always_requested 1
adb -s $Q shell cmd ethernet set-ip-configuration usb0 static $QIP/24 --gateway $MIP --dns 1.1.1.1   # flag names per E0 [U]
export EG=$(echo 'show State:/Network/Global/IPv4' | scutil | awk '/PrimaryInterface/{print $3}'); echo "egress=$EG"   # VPNs off for this baseline
echo "nat on $EG inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> ($EG)" | sudo pfctl -a com.apple/questlink -f -
sudo pfctl -a com.apple/questlink -s nat                        # rule present
export TOKEN=$(sudo pfctl -E 2>&1 | awk -F': ' '/Token/{print $2}'); echo "token=$TOKEN"
sudo pfctl -s References | grep "$TOKEN"; sysctl net.inet.ip.forwarding   # = 1
sudo tcpdump -ni $IF -c 40 'port 53 or port 443 or port 80' > $EV/E4-probes.txt &
for t in 1 2 3 4; do sleep 15; date +%T; adb -s $Q shell dumpsys connectivity | grep -iE 'Active default network|ETHERNET.*VALIDATED' | cut -c1-200; done | tee $EV/E4-validation.txt
adb -s $Q shell ip route get 1.1.1.1                            # expect dev usb0 once usb0 is default
adb -s $Q shell ping -c3 1.1.1.1; adb -s $Q shell ping -c3 www.google.com
adb -s $Q shell dumpsys wifi | grep -iE 'mNetworkInfo|Supplicant state' | head -3   # still connected (keep-wifi on)
qnet; orb list 2>/dev/null || docker ps                          # Mac default unchanged; OrbStack healthy
# Quest browser: load any site.
# Optional E4c (Wi-Fi teardown timing): `settings delete global wifi_always_requested`, wait 60 s, check dumpsys wifi; recover with `adb connect $QIP:5555`.
```

UDP phase (F4 check), after validation:
1. Stop the core and set `stream_protocol` to `{"variant":"Udp"}` offline (§9.1), keeping the pin.
2. Restart and reconnect.
3. `sudo tcpdump -ni $IF -c 20 udp port 9944`.

Teardown of the sharing pieces only (the link stays up):

```zsh
sudo pfctl -a com.apple/questlink -F all; sudo pfctl -X $TOKEN
adb -s $Q shell cmd ethernet set-ip-configuration usb0 static $QIP/24
adb -s $Q shell settings delete global wifi_always_requested       # or put back the value in E4-wifi-prior.txt
```

**Pass (`E4.VALIDATED`):**
- `usb0` is VALIDATED and the default network within about 15–30 s.
- The Quest browser works.
- The Mac default route and OrbStack are unaffected.
- UDP 9944 shows on `$IF`.

**Outcomes:**

| Outcome | Action |
|---|---|
| `E4.NOT_VALIDATED` | `sudo tcpdump -ni $EG host www.google.com`. Disable the ProtonVPN kill switch and transparent proxy, TripMode and Cisco one at a time; look for TLS interception. Then try E4-A. TCP streaming is unaffected either way |
| `E4.PF_FAIL` (`-s nat` empty, or pfctl errors) | E4-A |
| `E4.WIFI_WINS` | Check for a Wi-Fi network accepted as "no internet" and for a VPN on the Quest |

E4-A, zero-code F3. Run it only on `E4.NOT_VALIDATED`, `E4.PF_FAIL` or `E3.CMD_REJECTED`:
1. Revert the Quest to `dhcp`.
2. System Settings > General > Sharing > Internet Sharing: share Wi-Fi to the Quest port. This needs an enabled service for `$IF`.
3. Check:
   - `ifconfig | grep -B12 "member: $IF"` (bridge106 at 192.168.2.1 expected [L]);
   - `cat /var/db/dhcpd_leases`;
   - `adb -s $Q shell ip -4 addr show usb0`;
   - OrbStack still healthy.
4. Turn it off afterwards.

`E4A.FAIL` means no bridge, no lease, or OrbStack breaks.

#### E6: Virtual Desktop over Mode A, zero code (25 min)

1. `adb -s $QW shell cmd ethernet set-ip-configuration usb0 dhcp`, then replug to get the Default composition. Keep the Mac service; it applies while the host MAC is the same within this Quest boot [L].
2. Headset: VD tile > Settings > Release Channels > **Beta** (confirm "Beta" in the VD menu). Enable VD "Allow to connect over USB" and the system "USB connection for apps" consent. The consent needs VD in the foreground.
3. Mac: VD Streamer 1.34.22 running.
4. Launch VD and accept the consent. Click **Allow** on the Mac for the new composition, then:

```zsh
qusb | tee $EV/E6-qusb.txt; qtrm; export IF=$(qif)
ifconfig -v $IF | grep -E 'flags|inet6 fe80|status'   # UP,RUNNING, fe80::…%$IF
ping6 -c3 ff02::1%$IF; ndp -an | grep $IF              # Quest fe80 answers
adb devices -l; adb -s $QW shell dumpsys ethernet | grep -iE 'usb0|LOCAL|GLOBAL'   # did USB adb survive?
```

5. Headset: confirm "USB 3 5,120Mbps". Pull to refresh Computers up to 3 times and pick the blue USB entry. Turn Quest Wi-Fi off. On the Mac, run `netstat -I $IF -b` twice, 10 s apart.

**Pass (`E6.PASS`):** the desktop stream runs with Quest Wi-Fi off and enX counters growing. Record the Mode A PID and interface set.

**`E6.FAIL` checklist:**
- enX not up, or no fe80: that is Gate 3. Run `sudo ipconfig set $IF AUTOMATIC-V6`.
- No USB entry: restart the Streamer, disconnect Tailscale and ProtonVPN, confirm the Beta channel, try another cable or port.
- No consent dialog: VD must be in the foreground.

#### E6b: Does a STATIC config give Mode A IPv4? (15 min; decides `--sticky` and whether F1 needs a relay)

```zsh
adb -s $QW shell cmd ethernet set-ip-configuration usb0 static $QIP/24
adb -s $QW shell ip -4 addr show usb0                 # 192.168.42.2 while LOCAL? [U]
adb -s $QW shell dumpsys ethernet | grep -iE 'usb0|LOCAL|STATIC'
ping -b $IF -c3 $QIP
adb -s $QW shell 'echo quest-hello | toybox nc -l -p 5201' & sleep 1; nc -w3 $QIP 5201
# Disconnect and reconnect VD in the headset: does VD still work with IPv4 present?
```

| Outcome | Meaning |
|---|---|
| `E6b.STATIC_IN_LOCAL` | IPv4 present, TCP OK, VD fine. `--sticky` becomes allowed; F1 needs only a request holder |
| `E6b.STATIC_BREAKS_VD` | `--sticky` is never offered; `down` always reverts |
| `E6b.NO_IPV4_IN_LOCAL` | F1 keeps the relay |

Finish with `cmd ethernet … usb0 dhcp` and a replug.

### 4.5 Session 3: lock matrix, interference, performance, regression (about 2 h; must precede M3)

#### E10: Lock, TRM, naming and MAC-churn matrix (45 min)

The Mac cannot be typed into while locked, so every locked step is **pre-armed**: start the script, then lock with Ctrl-Cmd-Q. Run this logger alongside each case:

```zsh
while :; do date +%T; I=$(qif); echo "if=$I"; [ -n "$I" ] && ifconfig $I | grep -E 'status|inet '; ping -c1 -t1 -q $QIP | tail -1; qtrm; sleep 5; done | tee $EV/E10-<case>.log
```

1. **Approvals.** Record `qusb` and `qtrm` for Default (after a replug), Mode B, and XRSP+NCM+ADB if applicable. Note whether each one prompted, and the RelaxedPeriod/UnlockedPeriod values.
2. **MAC within one Quest boot.** Compare `ifconfig $IF ether` before and after: a replug + `setFunctions ncm`, and a `resetUsbGadget`. Expect the same MAC and the same `enN` [V static].
3. **Quest reboot while unlocked.** Run `adb -s $Q reboot`, wait, `adb -s $Q shell svc usb setFunctions ncm`, then `export IF=$(qif)`. Record:
   - the new `enN` and MAC;
   - whether the E3 service is now bound to a missing interface;
   - whether a new service was auto-created;
   - whether the new enX came up by itself.

   Expect a new `enN` [L]: outcome `E10.NEW_ENN_PER_BOOT`.
4. **Locked, approved composition.** Pre-arm `sleep 20; adb -s $QW shell svc usb setFunctions ncm` (starting from Default), then lock. Expect enX to return with the same name and the ping loop to show replies.
5. **Quest reboot while locked.** Pre-arm `sleep 20; adb -s $Q reboot; adb -s $Q wait-for-device; sleep 40; adb -s $Q shell svc usb setFunctions ncm`, then lock. After unlocking:
   - `echo 'show Plugin:InterfaceNamer' | scutil` should list the new MAC under `_Locked_`.
   - `qif` should be empty.
   - Force re-enumeration with `resetUsbGadget` [L] or a replug; expect the interface to be named.
   - If it is still unnamed: outcome `E10.UNNAMED_PERSISTS`.
6. **One controlled cache miss.** This step is disruptive, so it needs explicit consent. Plug in a non-critical canary accessory (a USB flash drive). Pre-arm `sleep 20; adb -s $QW shell svc usb setFunctions ptp`: PTP+ADB is a composition never approved. Lock, wait 30 s, unlock, and record:
   - `TRM_CacheMissCount` (expect +1);
   - whether adb over USB died;
   - whether the canary was restricted.

   If it was: outcome `E10.ESCALATE_1`. The built-in keyboard and trackpad are not TRM accessories [L]. Recover by replugging.
7. **Optional.** `adb -s $Q shell svc usb setScreenUnlockedFunctions ncm`, then replug and reboot. Does Mode B persist, and do Link and MTP still work? Clear it afterwards.

**Output:** a rule table in `docs/decisions.md` covering:
- what re-arms while locked;
- enN churn;
- escalation, 1 miss or 5;
- whether a service persists and re-raises enX;
- prompt behaviour under the relaxed periods.

Repeat case 1 after `TRM_RelaxedPeriod` becomes `No`.

#### E11: Interference and performance (45 min; use `questlink test` if M1 exists)

- **Extension matrix.** Enable each one alone:
  - ProtonVPN (kill switch on/off, Allow LAN off);
  - Tailscale (exit node on);
  - Cisco Secure Client;
  - TripMode;
  - Pangolin;
  - Shadowrocket.

  For each, record `route -n get $QIP`, `scutil --nwi` and `sudo pfctl -sr`, plus ping and `nc` to 5201. With share on, record validation, re-rendering `EG` to the VPN utun if it became primary.
- **LNP.** Run the ALVR server from Terminal.app, from iTerm2, and via the CrossOver GUI, with `/usr/bin/log stream --predicate 'process == "nehelper" OR process == "nesessionmanager"'` running.
- **Latency.** `ping -b $IF -i 0.01 -c 2000 -q $QIP`, idle and under load. Record p50 and p99.
- **Throughput.** `qbulk` both ways. Optionally iperf3: Mac from nix or Homebrew; Quest built with NDK 28.2 (`aarch64-linux-android32-clang`) and pushed to `/data/local/tmp`. Run TCP `-P4`, `-R`, and UDP `-u -b 1G -l 1400`, on USB 3 and on a USB 2 cable.
- **MTU.** `ping -D -s 1472 -c3 $QIP` should pass and `-s 1473` should fail. `sudo ifconfig $IF mtu 4000` is expected to be refused or capped.
- **Sleep and wake.** `pmset sleepnow`, then wake: `$IF` should be RUNNING and ping should resume. Also test Quest proximity sleep (revert `prox_close` first).

**Expectations [U]:**
- 0.3–1 Gb/s; idle RTT under 1 ms.
- If under 300 Mb/s on USB 3: check the speed in `SPUSBHostDataType` and the NTB values from `qncm`.

#### E12: Virtual Display regression and restore (15 min)

1. Replug. Confirm with `qusb` that the PID is in {0x5010–0x5013, 0x5017–0x501A} and that the ff/8B and ff/8C interfaces are present.
2. Start Meta Quest Virtual Display, then:
   ```zsh
   grep -hE 'discoEnabled=|Client Connected on RTC' "$(ls -t ~/Library/Application\ Support/Meta\ Quest\ Remote\ Desktop/mqrd_*.log | head -1)"
   ```
3. The optional share-mode side test is in §9.3.

### 4.6 Conditional rungs (need the M5 Quest app)

- **E7, probe APK.** Record:
  - onAvailable / LinkProperties (interface, fe80, any IPv4 on 2.7), capabilities, bandwidth;
  - whether USB adb survives while the request is held;
  - reachability from a second, unbound app;
  - survival while the immersive ALVR client has focus for 10 minutes, and through proximity sleep;
  - pre-emption of Mode B (`usb0` loses IPv4 and goes LOCAL), then recovery after release.
- **E8, F1 relay.** See §8.
  - Pass: the stream runs with `current_ip` 127.0.0.1 while traffic is on `$IF`, and it survives `adb kill-server`.
  - `E8.RELAY_FROZEN` means F1 is not viable.
- **E9, F2.** Run Steam Link USB once, then check `dumpsys ethernet` for a stored 10.86.13.37/29. Capture the broadcast with `adb shell dumpsys activity broadcasts history | grep -n -B2 -A10 SET_LOCAL_IP`, and replay it from the Keeper [U]. Always clean up with `cmd ethernet … usb0 dhcp`.

### 4.7 R-CLEAN (end of every session)

```zsh
cd ~/projects/personal/wine-vr && ./demo.sh stop --bottle <b>
lsof -nP -iTCP:8082 -sTCP:LISTEN | awk 'NR>1 && $9=="*:8082"'     # must print nothing (ALVR gone; OrbStack's 127.0.0.1 line is expected)
cp "$ALVRS.bak-ncm" "$ALVRS"
adb -s $QW shell cmd ethernet set-ip-configuration usb0 dhcp
adb -s $QW shell settings delete global wifi_always_requested      # or the recorded prior value
adb -s $QW shell am broadcast -a com.oculus.vrpowermanager.automation_disable   # if prox_close was used [L]
[ -n "$TOKEN" ] && { sudo pfctl -a com.apple/questlink -F all; sudo pfctl -X $TOKEN; }
sudo ipconfig set $IF NONE 2>/dev/null; sudo ipconfig set $IF NONE-V6 2>/dev/null
# keep or remove the M0 service: sudo networksetup -removenetworkservice "Quest NCM"
adb -s $Q usb                                                     # adbd back to USB-only (closes :5555)
# replug -> Default composition; qusb shows a PID in {0x5010-0x5013,0x5017-0x501A} with ff/8B + ff/8C
sudo pfctl -s References                                          # no leftover token of ours
```

### 4.8 Decision gate (after Session 1; refined after Sessions 2 and 3)

| Observed | Decision |
|---|---|
| E3 pass and E5 pass | **GO Mode B.** Build M1 as specified. No DHCP responder, no Quest app |
| `E3.CMD_REJECTED` and `E2.DISCOVER_SEEN` | GO Mode B with DHCP. In M0, reach E5 through E4-A (Internet Sharing). M1 includes the DHCP responder (T8). If `E4A.FAIL`, M1 builds the responder first and re-runs E3–E5 with it |
| `E3.CMD_REJECTED` and (`E2.UNTRACKED` or `E2.NO_DISCOVER`) | Mode B addressing is dead. Run E6. If E6 passes, go **F1**: M5 Quest app (probe + relay) plus the CLI relay; the CLI keeps `doctor`, `status` and `alvr pin --relay` |
| `E3.NO_INBOUND` | Run E4 early. `E4.VALIDATED` → **F4** (share is mandatory for ALVR). `E4.NOT_VALIDATED` → try `svc wifi disable`; if that also fails → F1 |
| `E1.NO_BIND`, or persistent `E2.NO_CARRIER`/`E2.NOT_RUNNING`, **and** `E6.FAIL` | **F5** (Ethernet adapter). The CLI shrinks to `doctor` + `alvr pin` |
| `E1.NO_BIND` or `E2.NO_CARRIER` but `E6.PASS` | The problem is specific to the Mode B composition → F1 |
| `E3.PERSIST_FAIL` | CLI Gate 3 strategy becomes per-attach `ipconfig set` (in `up`/`watch`) |
| `E3.DECAY` | `watch` must re-apply the address; recommend `--share` |
| `E5.LNP` only | Fix the launch context; no code change |
| `E6b.STATIC_IN_LOCAL` (Session 2) | Enable `--sticky` in M2; F1 would need no relay |
| `E10.ESCALATE_1` (Session 3) | M3 hard-blocks every switch while locked |
| `E10.UNNAMED_PERSISTS` | M4 offers the `--allow-new-interfaces` opt-in prominently |

### 4.9 M0 deliverables

- `docs/evidence/<date>/E*/`: raw outputs. The ioreg plists, dumpsys and `ip` text become M1 parser fixtures.
- `docs/m0-results.md`, with one row per question:
  - PIDs and interfaces per composition; driver class;
  - auto-service; naming; TRM prompt and relaxed periods;
  - carrier follows enX; DISCOVER; `cmd ethernet` on usb0;
  - Mac-dialled TCP; hold; route diff; persistence;
  - ALVR and LNP;
  - MAC/enN churn; lock rules; escalation;
  - NAT validation time; Wi-Fi teardown;
  - VPN matrix; throughput, RTT and MTU;
  - VD Mode A; E6b.
- `docs/decisions.md`: the §4.8 outcomes and which fallbacks fired.

---

## 5. Milestone 1: `questlink` Swift CLI

### 5.1 Principles

- **One binary.**
  - Mutating subcommands require root (`sudo` from Terminal.app, which is also LNP-exempt).
  - `doctor`, `status`, `mode`, `snapshot` and `alvr` run unprivileged. `doctor` skips the pcap step without root.
- **Never run adb as root.**
  - Exec `/usr/bin/sudo -u "$SUDO_USER" -H <adb> -s <serial> …`.
  - adb binary: `$ADB`, else `~/Library/Android/sdk/platform-tools/adb` (wine-vr's choice), else `/run/current-system/sw/bin/adb`.
  - A root-started server would use root's adbkey (a new headset prompt) and take port 5037 away from the user.
  - Every call has a timeout. The transport drop after a composition switch is expected.
- **Write-ahead journal.** Each change and its undo are recorded **before** acting, in `/Library/Application Support/QuestLink/state.json` (root, 0600).
  - `down` and `repair` replay undos in reverse; `repair` also runs at the start of `up`.
  - Everything is idempotent.
- **`--dry-run`** on `up`, `share` and `down` prints the exact planned SC, pf and adb actions.
- **Hard prohibitions:**
  - `pfctl -d`, or flushing or editing the main ruleset;
  - editing, reordering or deleting services questlink did not create;
  - writing NetworkInterfaces.plist;
  - touching any interface but the Quest's enX;
  - binding UDP 67 outside DHCP mode;
  - switching composition while locked unless the target is approved.
- **Identity.** The Quest is VID 0x2833 + USB serial (equal to the adb serial). The interface is found by IORegistry ancestry every time; `enN` is never trusted across a Quest boot.
- **User files under sudo.** Resolve the user via `SUDO_USER`/`getpwnam`, perform ALVR edits as that user, and `chown` any file written into their home.
- **Fault injection (debug builds).** `QUESTLINK_FAULT=after:<stage>` aborts after a stage, for V9.

### 5.2 Package layout (`mac/`)

```
mac/
  Package.swift                 // swift-tools-version:6.0; platforms [.macOS(.v15)]; products: questlink (exe), QuestLinkCore (lib)
                                // deps: swift-argument-parser (Apache-2.0) only; QuestLinkCore in Swift 5 language mode
                                // (or @preconcurrency import IOKit) to avoid strict-concurrency friction with C callbacks
  Sources/
    CQuestShims/                // C: SIOCGIFFLAGS/SIOCGIFMEDIA (_IOWR macros Swift can't import), PF_ROUTE RTM_GET helper,
      include/CQuestShims.h     //   #include <pcap/pcap.h>; links libpcap from the SDK
      shims.c
    QuestLinkCore/
      Model/     Stage.swift ExitCode.swift Composition.swift LinkSnapshot.swift
      USB/       USBMonitor.swift RegistryWalker.swift NCMInterface.swift
      Gate/      ConsoleLock.swift TRMState.swift InterfaceNamer.swift ApprovedStore.swift
      ADB/       ADBExec.swift QuestShell.swift Parsers/{DumpsysEthernet,DumpsysConnectivity,IpAddr,Getprop}.swift
      Net/       ServiceManager.swift StoreWatcher.swift IfProbe.swift RouteGuard.swift SubnetPicker.swift PeerSniffer.swift
      Addr/      QuestStaticAddr.swift
      DHCP/      DHCPPacket.swift DHCPResponder.swift        // conditional (§4.8)
      NAT/       PFAnchor.swift EgressWatcher.swift           // M2
      LinkTest/  LinkTest.swift
      ALVR/      ALVRSession.swift ALVRDashboard.swift
      Doctor/    Doctor.swift Report.swift
      State/     Journal.swift Paths.swift
      Relay/     TCPRelay.swift                               // F1 only
      Daemon/    Daemon.swift SocketServer.swift              // M4
    questlink/   main.swift Commands/{Doctor,Status,Snapshot,Mode,Up,Down,Repair,Test,Share,Alvr,VD,Watch,Relay,Daemon}.swift
  Tests/QuestLinkCoreTests/     // Fixtures/ copied from docs/evidence (ioreg plists, dumpsys, getFunctions, ip, lsof)
```

**Build:** `cd mac && swift build -c release`. The binary is `mac/.build/release/questlink`.

### 5.3 Subcommands

| Command | Root | Behaviour |
|---|---|---|
| `questlink doctor [--json] [--serial S]` | no | Walks S0–S16 read-only; prints each stage with evidence; the first failure carries a remedy; exit code = failing stage |
| `questlink status [--watch]` | no | One-line status: mode, addresses, counters |
| `questlink snapshot [--out DIR]` | no | The E0-style evidence bundle, Mac and Quest |
| `questlink mode` | no | `default` / `A` / `B` / `unknown`, with evidence |
| `questlink up [--share] [--addr static\|dhcp] [--sticky] [--subnet CIDR] [--serial S] [--force-stop-holders] [--reset-usb0] [--keep-quest-wifi] [--dry-run]` | yes | §5.5 |
| `questlink down [--restore-usb] [--forget] [--dry-run]` | yes | Replays the journal: pf, Quest `usb0` → dhcp (unless sticky), settings, composition. `--forget` also removes questlink services |
| `questlink repair` | yes | Replays pending undos after a crash |
| `questlink test [--seconds N] [--serve]` | no (`--serve` binds enX) | ICMP p50/p99/loss, TCP both ways pinned with `IP_BOUND_IF`, enX vs en0 counters |
| `questlink share on\|off [--dns IP] [--keep-quest-wifi] [--dry-run]` | yes | §6 (M2) |
| `questlink alvr pin [--ip A] [--udp] [--relay] \| unpin \| launch \| status` | no | §9.1 automation; offline by default |
| `questlink vd prepare` | yes | Mode A readiness (§9.2) (M2) |
| `questlink watch` | yes | Re-arm loop (§5.6.13) (M3) |
| `questlink relay [--ports 9943,9944] [--offset 10000]` | no | F1 only |
| `questlink daemon run\|install\|uninstall` | yes | M4 |

### 5.4 Link stage machine

This is the backbone of `doctor`, `up`, `status` and the menu bar.

| # | Stage | Check | On failure: automatic step, then manual | Exit |
|---|---|---|---|---|
| S0 | Mac unlocked | IOConsoleUsers `CGSSessionScreenIsLocked` absent (the key appears only when locked [V-here]); AppleCredentialManager `TRM_DeviceLocked=No` | Never switch; `watch` waits; `up` exits unless no switch is needed or the target is approved | 10 |
| S1 | adb server, exactly one Quest | `adb devices -l` as the user | Start the server as the user; ask for headset authorization; `--serial` if more than one | 11 / 12 |
| S2 | Quest mode clean | `svc usb getFunctions` (stderr); `dumpsys connectivity` (USB requests + uid); `dumpsys ethernet` (usb0 mode and config) | Holders → `--force-stop-holders`; foreign STATIC → `--reset-usb0` | 60 |
| S3 | NCM composition present | Device has 02/0D/00 + 0A/00/01 | If allowed by S0: `setFunctions ncm` via the Wi-Fi transport if present; await re-enumeration by serial (≤20 s) | 20 |
| S4 | TRM authorized | IOPortTransportState `TRM_TransportRestricted=No`, AuthorizationStatus | Notify "Unlock and click Allow"; poll 120 s; then ApprovedStore.add | 21 |
| S5 | Driver bound | AppleUSBNCMControl + AppleUSBNCMData under the device (NCM11 flagged) | Dump interfaces; advise the E6 control / F5 | 22 |
| S6 | Named | Child IOEthernetInterface has "BSD Name" | `_Locked_` and now unlocked → `resetUsbGadget` once [L] → else prompt a replug | 23 |
| S7 | Service owned | Service for enX: Manual .1/len, no Router, v6 LinkLocal (PrimaryRank Never) | Create or edit (journaled) | 30 |
| S8 | UP + RUNNING | `SIOCGIFFLAGS` IFF_UP and IFF_RUNNING; `IOControllerEnabled=Yes` | Wait 5 s → `ipconfig set` fallback → advise replug | 31 |
| S9 | Link hint | `IOLinkStatus`/media active; Quest `ip link` LOWER_UP | Informational only | — |
| S10 | Peer seen | libpcap `ether src <QMAC>` frame within 10 s | Quest NO-CARRIER → Gate 3 or driver; LOCAL → S2 | 32 |
| S11 | IPv4 both ends | Quest `ip -4 addr show usb0` = .2; `getifaddrs` .1 on enX | `cmd ethernet` static (journaled), or the DHCP responder with `--addr dhcp` | 40 |
| S12 | Reachable, correctly scoped | RTM_GET for .2 → enX; ICMP bound to enX; TCP to a Quest listener with IP_BOUND_IF | Route resolves to a utun → VPN warning naming the extension | 41 |
| S13 | Route safety | Global IPv4/IPv6/DNS + default route equal the pre-`up` snapshot | Roll back the last change, exit, print the diff | 42 |
| S14 | Sharing (optional) | Anchor loaded, token held, egress current; Quest usb0 VALIDATED + default | §6 | 50 |
| S15 | ALVR (optional; user context) | `client.wired` absent; `quest.ncm` pinned; protocol; `*:8082` owner; `current_ip`; `lsof` peers | §9.1 | 70 |
| S16 | Environment warnings | `systemextensionsctl list`, `scutil --nc list`; 127.0.0.1:8082 owner; Quest VPN | Named warnings (ProtonVPN kill switch/transparent proxy, TripMode, Cisco, Tailscale exit node, Pangolin, Shadowrocket) | — |

### 5.5 `up`, `down`, `repair`

```
up:
  repair()                                     // settle leftovers first
  S0 lock   -> exit 10 if locked AND a switch is needed AND target not approved
  S1 adb    -> resolve serial; prefer <wifi-ip>:5555 transport for switches when present
  S2 quest  -> mode(); holders? (--force-stop-holders); foreign usb0 STATIC? (--reset-usb0); else exit 60
  snap = RouteGuard.capture(); subnet = SubnetPicker.choose(--subnet)    // includes Quest wlan0 subnet
  S3 comp   -> journal(undo: replug prompt); setFunctions ncm; await re-enumeration by serial
  S4 trm    -> restricted? notify "Unlock + Allow"; poll 120 s; ApprovedStore.add(signature)
  S5 bind   -> await AppleUSBNCMData (10 s) else exit 22 (+ dump)
  S6 name   -> await BSD name (10 s); _Locked_ -> resetGadget once -> else exit 23 "replug"
  S7 svc    -> ServiceManager.ensure(enX, subnet) [journal]; RouteGuard.check(snap)
  S8 up     -> await UP+RUNNING+IOControllerEnabled (5 s) -> ipconfig fallback [journal] -> else exit 31
  S10 peer  -> PeerSniffer(QMAC, 10 s) -> else exit 32 with Quest ip-link evidence
  S11 addr  -> QuestStaticAddr [journal undo: dhcp unless --sticky] | DHCPResponder(--addr dhcp)
  S12 reach -> RTM_GET==enX; ICMP; TCP 5201 -> else exit 41
  S13 safe  -> RouteGuard.check(snap) -> else rollback + exit 42
  S14 share -> if --share: §6 -> exit 50 on failure (link stays up)
  print: LINK UP mode=B if=enN mac=192.168.42.1 quest=192.168.42.2 rtt_p50=… share=on|off
down: replay journal in reverse (pf token/anchor, wifi_always_requested prior, usb0 -> dhcp unless sticky,
      ipconfig overrides); --restore-usb prompts a replug (or `svc usb setFunctions` if E1/E10 showed it restores Default);
      Mac service kept by default (harmless).
```

Expected `up` output:

```
[S0 ] unlocked; TRM relaxed=Yes unlocked=Yes (recorded)
[S1 ] adb <serial> authorized (wifi transport 10.x.x.x:5555 available)
[S2 ] mode default; no TRANSPORT_USB requests; usb0 config: none
[S3 ] setFunctions ncm -> re-enumerated 2833:500A
[S4 ] accessory authorized
[S5 ] AppleUSBNCMControl/AppleUSBNCMData (NCM 1.0)
[S6 ] en17 host MAC xx:xx:..
[S7 ] service "Quest NCM (questlink) en17": Manual 192.168.42.1/24, no router, IPv6 link-local
[S8 ] UP,RUNNING IOControllerEnabled=Yes  5 Gb/s
[S10] first Quest frame after 0.3 s
[S11] usb0 192.168.42.2/24 (static via cmd ethernet; revert on down)
[S12] ping 3/3 via en17; TCP ok
[S13] default route unchanged (en0)
LINK UP mode=B if=en17 mac=192.168.42.1 quest=192.168.42.2 rtt_p50=0.4ms share=off
```

### 5.6 Modules and key APIs

**5.6.1 USB (IOKit).**
- `IONotificationPortCreate(kIOMainPortDefault)` plus `IONotificationPortSetDispatchQueue`.
- `IOServiceAddMatchingNotification` for `kIOFirstMatchNotification` and `kIOTerminatedNotification`:
  - on `IOServiceMatching("IOUSBHostDevice")` with `idVendor = 0x2833`;
  - separately, first-match on `IOServiceMatching("AppleUSBNCMData")`.
  - Drain the iterators immediately.
- Read with `IORegistryEntryCreateCFProperty`: `idProduct`, `kUSBSerialNumberString`/`USB Serial Number`, `kUSBProductString`/`USB Product Name`, `bcdUSB`, and the speed key named in E1 [U].
- **Composition signature:** VID + serial + sorted unique child `IOUSBHostInterface` triples (`bInterfaceClass/SubClass/Protocol`). This mirrors the TRM hash inputs; the PID is informational only.
- **NCM check:** `IOObjectConformsTo(obj, "AppleUSBNCMData")`, also accepting and flagging NCM11. Cross-check with VD's idea: `IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "CFBundleIdentifierKernel", nil, kIORegistryIterateRecursively | kIORegistryIterateParents)` contains `usb.cdc.ncm`.
- **Controller properties:** `IOLinkStatus` (bit0 valid, bit1 active), `IOControllerEnabled`, `IOMACAddress` (host MAC), plus the NTB keys from E1.

**5.6.2 Registry mapping, both directions.**
- Device → name: walk children of IOUSBHostDevice → AppleUSBNCMData → IOEthernetInterface "BSD Name".
- Name → device: `IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, "enX"))`, then `IORegistryEntryGetParentEntry(…, kIOServicePlane, …)` until `IOUSBHostDevice`, then check the VID.
- The Mac's own device-mode interfaces (en4–6, anpi* under AppleT8122USBXDCI) fail this check.

**5.6.3 Gatekeeper (lock, TRM, naming).**
- **Lock:** IOConsoleUsers `CGSSessionScreenIsLocked` plus `TRM_DeviceLocked`. Poll every 2 s; this works in a root daemon, whereas distributed notifications don't.
- **TRM:** IOPortTransportState `TRM_TransportRestricted`, `HashStatusDescription` and `AuthorizationStatusDescription`. They are mapped to the Quest's port using the E1 tree capture [U]. Also track `TRM_CacheMissCount`, `TRM_RelaxedPeriod` and `TRM_UnlockedPeriod`.
- **Naming:** `SCDynamicStoreCopyValue(store, "Plugin:InterfaceNamer")`, entry `_Locked_`.
- **ApprovedStore** (`/Library/Application Support/QuestLink/approved.json`): signature, first-seen, last-authorized. Entries older than 30 days are treated as unknown, because the Mac TRM expiry is [U].
- **Policy (M3, encoded from E10):**
  - Refuse a switch while locked unless the target is approved, within grace, and `TRM_CacheMissCount` has not risen.
  - On `E10.ESCALATE_1`, refuse every switch while locked.
  - After unlock, if the Quest NCM is unnamed: `resetUsbGadget` once, otherwise a replug prompt.

**5.6.4 ADB (exec as user).** `QuestShell` wraps typed commands:
- `getFunctions()` (reads stderr), `setFunctions(.ncm)` (never `ncm,adb`), `resetGadget()` [L].
- `ethernetSetIP(iface:, .static(cidr, gw?, dns?) | .dhcp)`: the mode word and flag names are validated against the E0 help capture, then read back.
- `dumpsysEthernet()`: regex, tracked interfaces, per-interface GLOBAL/LOCAL, stored IpConfiguration.
- `dumpsysConnectivity()`: requests with `Transports: USB` plus uid, and the usb0 network's VALIDATED and default status.
- `ipAddr/ipLink/mac("usb0")`, `uidToPackage()`, `forceStop(pkg)`.
- `settingsGlobal(get|put|delete, "wifi_always_requested")`.
- `listen(port)` (`toybox nc -l -p`), `launch(pkg)` (`monkey -p <pkg> -c android.intent.category.LAUNCHER 1`).
- Hotplug: a long-running `adb track-devices -l` subprocess.

Parsers are built from the M0 fixtures; formats are [U] until captured. If `M1.ADB_FLAKY` fires, build the smart-socket client:
- 127.0.0.1:5037, 4-hex length prefix, OKAY/FAIL;
- `host:track-devices-l`, `host:transport:<serial>`, `shell,v2,raw:`;
- references: ya-webadb (MIT), dadb (Apache-2.0).

**5.6.5 NetConfig (SystemConfiguration).**
1. As root: `SCPreferencesCreate(nil, "questlink", nil)`, `SCPreferencesLock(prefs, true)`.
2. `SCNetworkSetCopyCurrent` → `SCNetworkSetCopyServices` → `SCNetworkServiceGetInterface` → `SCNetworkInterfaceGetBSDName == enX`.
3. If an auto-created service exists, reconfigure it in place and journal its prior config.
4. If missing: take the interface from `SCNetworkInterfaceCopyAll()`, then `SCNetworkServiceCreate`, `SCNetworkServiceEstablishDefaultConfiguration`, `SCNetworkServiceSetName("Quest NCM (questlink) enX")`, `SCNetworkSetAddService`.
5. IPv4 via `SCNetworkServiceCopyProtocol(svc, kSCNetworkProtocolTypeIPv4)` → `SCNetworkProtocolSetConfiguration([kSCPropNetIPv4ConfigMethod: kSCValNetIPv4ConfigMethodManual, kSCPropNetIPv4Addresses: ["192.168.42.1"], kSCPropNetIPv4SubnetMasks: ["255.255.255.0"]])`, with **no Router key**.
6. IPv6: `kSCValNetIPv6ConfigMethodLinkLocal`. Enable the protocols and the service.
7. Optional belt-and-braces: raw `PrimaryRank = "Never"` merged into `/NetworkServices/<id>` via `SCPreferencesPathGetValue`/`SetValue`. This is private schema [L]; check with `scutil <<< "show Setup:/Network/Service/<id>"`. Safety never depends on it.
8. `SCPreferencesCommitChanges`, `SCPreferencesApplyChanges`, `SCPreferencesUnlock`.

Rules:
- Never disable our service; that would lose the automatic UP.
- Never use `PrimaryRank Scoped`.
- GC deletes only journaled questlink services whose interface is gone.

**StoreWatcher** (`SCDynamicStoreCreate` + `SetNotificationKeys` + `SetDispatchQueue`) watches:
- `State:/Network/Global/IPv4|IPv6|DNS`
- `State:/Network/Interface/<enX>/Link|IPv4|IPv6`
- `Plugin:InterfaceNamer`
- the pattern `Setup:/Network/Service/.*`

**5.6.6 IfProbe and PeerSniffer.**
- IfProbe: `SIOCGIFFLAGS` (shim), `SIOCGIFMEDIA`, `getifaddrs` (addresses and `if_data` counters), `if_nametoindex`. `IFF_UP` alone never counts: `ifconfig up` exits 0 even when enable() failed [V].
- PeerSniffer: `pcap_open_live(enX)` with filter `ether src <QMAC>`, where QMAC comes from `/sys/class/net/usb0/address` via adb, or from the first DISCOVER. It passes on the first frame within 10 s.

**5.6.7 RouteGuard and SubnetPicker.**
- Snapshot `State:/Network/Global/IPv4` (PrimaryService, PrimaryInterface, Router), IPv6, DNS, the service order, and the default route via RTM_GET.
- Re-check after every change. On any difference: roll back that change and exit 42 with a diff.
- RTM_GET for the Quest address must return enX; a `utunN` result names the likely extension.
- SubnetPicker implements §2.6.

**5.6.8 Addressing.**
- Primary: `QuestStaticAddr`, journaled, polling `ip -4 addr show usb0` for 15 s.
- Conditional DHCP responder (libpcap):
  - Receive on enX with filter `udp dst port 67 and ether src <QMAC>`, plus a `chaddr` match in code.
  - Transmit with `pcap_inject` of full Ethernet/IPv4/UDP frames: dst MAC = chaddr, 192.168.42.1:67 → 192.168.42.2:68, valid checksums, BOOTP payload of at least 300 bytes with the magic cookie. Verify with tcpdump that the source MAC is enX's [L on libpcap header-complete handling].
  - DISCOVER → OFFER. REQUEST (selecting, or renewing with ciaddr .2) → ACK. Wrong address → NAK. Log DECLINE and RELEASE.
  - Options 53, 54 (.1), 1 (255.255.255.0) and 51 (3600 s) always; 3 and 6 only when sharing. **Never 108** (the Quest honours it by dropping IPv4 for 300 s or more [V]), and never 80 or 114. Keep the mask constant across renewals.
  - Unicast renewals are also seen via pcap. Bind a UDP socket to `192.168.42.1:67` with `IP_BOUND_IF`, only to suppress ICMP port-unreachable, and only when `lsof -iUDP:67` is empty; otherwise skip the bind.
  - Refuse to run while Internet Sharing covers enX. Treat `ENETDOWN` on inject as "enX not UP".
  - Port the option set from UbootVRC `QuestNcmLink.ps1` (MIT).

**5.6.9 NAT (M2).** `PFAnchor` shells out to `/sbin/pfctl`, which keeps it auditable:
- `-a com.apple/questlink -f -` (rule on stdin);
- `-E` (parse `Token : N`, journal it);
- `-X N`;
- `-a com.apple/questlink -F all`;
- `-s References`.

`EgressWatcher` re-renders the rule when `PrimaryInterface` changes.

**5.6.10 IPv6 link-local.**
- Every fe80 socket sets `sin6_scope_id = if_nametoindex(enX)`.
- Addresses print as `fe80::x%enX`, and in URLs as `[fe80::x%25enX]`.
- The Quest's fe80 comes from `adb shell ip -6 addr show usb0 scope link`, or from `ping6 ff02::1%enX` + `ndp -an`.
- ALVR cannot use IPv6: `manual_ips` has no scope field and the client binds IPv4 only [V]. So Mode B uses IPv4, and Mode A needs the relay.

**5.6.11 LinkTest.**
- ICMP: `/sbin/ping -b enX -i 0.01 -c 500 -q`, parsed.
- TCP: POSIX sockets with `IP_BOUND_IF`. The Quest listener is `toybox nc` over adb (5201 sink, 5202 `< /dev/zero` source). Read `TCP_CONNECTION_INFO` `tcpi_srtt`.
- Counters: enX vs en0 `if_data` deltas. Warn below 200 Mbit/s.
- `--serve`: listen on 192.168.42.1:5201 and `[fe80::%enX]:5201` for the Quest app's tests.

**5.6.12 ALVR helper** (runs as the user; details in §9.1).
- **Core-running detection:** a `*:8082` listener (`lsof -nP -iTCP:8082 -sTCP:LISTEN`, `NAME == "*:8082"`). The 127.0.0.1:8082 owner is reported separately; today it is OrbStack.
- `pin` (default offline): refuse unless the core is stopped. Back up to `~/Library/Application Support/QuestLink/alvr/session.json.<ts>`, edit, and read back.
- `pin --live`: only when a `*:8082` listener exists. POST to `http://<MIP>:8082/api/dashboard-request`, never 127.0.0.1; read `session.json` back after 1–2 s.
- `unpin`: restore the backup offline, or apply the inverse sequence live.
- `launch`: `monkey -p alvr.client …`, with the package resolved from `wired_client_type` [V-here: Store → `alvr.client`].
- `status`: `current_ip`, `lsof` peers on 9943/9944.

**5.6.13 `watch` (M3).**
- Triggers: IOKit attach/detach, InterfaceNamer changes, unlock (2 s poll), wake (`IORegisterForSystemPower`), egress change.
- Rules:
  - Default composition attached, auto-connect enabled for this serial, and S0 permits → `setFunctions ncm`.
  - NCM attached and named → ensure the service (create for a new `enN`, GC stale ones), UP, peer, and address (re-apply if lost).
  - Unnamed while unlocked → `resetUsbGadget` or a replug prompt.
  - Locked and the target is not approved → do nothing and log.
  - Any TRANSPORT_USB request present (Mode A) → stand down.

**5.6.14 Relay (F1).**
- Network.framework: an `NWListener` on 127.0.0.1:9943 and :9944.
- Per connection, an `NWConnection` to `[fe80::quest%enX]:19943/19944` with `requiredInterface` = enX and `noDelay`.
- Refuse to start if `adb forward --list` holds 9943 or 9944.

### 5.7 Route-safety measures (summary)

1. Subnet collision check before any change (§2.6).
2. The Mac service never has a Router key; IPv6 is LinkLocal only (no RA/SLAAC).
3. Snapshot before `up`, compare after each step, and roll back automatically (S13).
4. RTM_GET for the Quest address must be enX. A utun is a named warning.
5. Only our own service is touched; GC applies only to journaled questlink services.
6. pf only through the `com.apple/questlink` anchor with an `-E` token and `-X`.
7. No UDP 67 receive socket. The DHCP responder is pcap-only on enX and answers only the Quest's MAC.
8. Every Quest-side persistent change is journaled and reverted. `up` detects leftovers, including Steam Link's.
9. No composition switch while locked unless approved.
10. `up` and `down` are idempotent.

### 5.8 Build order

| Task | Deliverable | Acceptance |
|---|---|---|
| T1 | `git init` (your call), package skeleton, ArgumentParser, `--version` | `swift build` clean |
| T2 | RegistryWalker + USBMonitor + `doctor` USB stages | Detects the Quest from E1 fixtures in tests. Optional live check on the RTL8156 with `--vid 0x0bda`, if you plug it in |
| T3 | Gatekeeper readers | `doctor` shows lock, all TRM keys and InterfaceNamer; unit tests on captured plists |
| T4 | ADBExec + QuestShell + parsers | `questlink mode` on a live Quest; parser tests on E0–E4 fixtures; port 5037 never root-owned |
| T5 | ServiceManager (dry-run first) | Dry-run prints the exact SC changes; a live run gives Manual, no router, v6 LinkLocal; `down --forget` restores `networksetup -listallnetworkservices` byte-for-byte |
| T6 | IfProbe, PeerSniffer, RouteGuard, SubnetPicker | RouteGuard detects an injected router change in a test harness; SubnetPicker rejects 192.168.138.x and an aliased 192.168.42.9 |
| T7 | QuestStaticAddr + Journal + `repair` | Set and revert on the headset; undo works after `kill -9` |
| T8 | DHCPResponder (**only if** §4.8 requires it) | Golden-byte OFFER/ACK/NAK tests; a live lease; no replies to any other MAC |
| T9 | `up` / `down` / `repair` orchestration + fault hook | V3–V6, V9 |
| T10 | LinkTest | Within 10% of the E3c/E11 manual figures |
| T11 | ALVR helper | V12; `unpin` restores `session.json` (JSON diff empty) |
| T12 | `doctor --json` schema frozen | Schema test (the menu bar app consumes it) |

### 5.9 Testing without the headset

- **Unit tests** on M0 fixtures: ioreg plists, dumpsys text, adb outputs, pf rule rendering, DHCP golden packets, ALVR JSON bodies checked against the serde shapes, `session.json` round-trips, subnet collisions, stage transitions with fake providers.
- **Optional hardware fixtures:**
  - The RTL8156 adapter (runs NCM under AppleUSBNCM, not attached today) exercises IOKit detection, the service lifecycle and Gate 3 with `--vid 0x0bda` on a free subnet.
  - A Raspberry Pi 5 configfs `ncm.usb0` gadget (stock f_ncm) exercises carrier, pcap and DHCP.

---

## 6. Mac-to-Quest internet sharing (Mode B only; M2)

**Why it matters beyond internet access.** Validation, meaning an HTTPS 204 from `www.google.com/generate_204` through the Mac, makes `usb0` the Quest's default network [L]. Unmodified apps then use the cable for traffic they start themselves: ALVR UDP and discovery, the browser, Moonlight/VNC, system services.

**`questlink share on`:**
1. The Mac service stays router-less (.1/24, IPv6 LL), so the Mac default route cannot move.
2. **DNS R.** The first IPv4 server in `State:/Network/Global/DNS` that is not loopback, not link-local, not in 100.64/10 and not reached via a utun. That excludes Tailscale MagicDNS 100.100.100.100, which is unreachable through the NAT. Otherwise use `1.1.1.1`. Override with `--dns`.
3. **Quest.** `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 --gateway 192.168.42.1 --dns R` [U flag syntax until E0]. In DHCP mode, options 3 and 6 carry the same values. Never 108, 80 or 114.
4. **NAT.** `EG` = `State:/Network/Global/IPv4 PrimaryInterface`; it may be a VPN utun.
   - Rule: `nat on $EG inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> ($EG)`, loaded into `com.apple/questlink`.
   - `pfctl -E`, with the token journaled. EgressWatcher re-renders the rule when `EG` changes.
   - `net.inet.ip.forwarding` is already 1. If it is 0 on another Mac, set it and journal the change.
5. **Validation wait.** Up to 45 s, then report `VALIDATED` and `default=usb0`.
6. **Wi-Fi linger [L].** About 30 s after validation, Quest Wi-Fi is torn down, taking the adb-over-Wi-Fi recovery channel with it.
   - `--keep-quest-wifi` sets `wifi_always_requested=1`, with the prior value journaled.
   - Without it, `share on` prints a warning and switches its recovery channel to `adb connect 192.168.42.2:5555` if tcpip is active.
7. **Must pass Mac filters** (ProtonVPN, TripMode, Cisco, Pangolin) without TLS interception:
   - DNS 53 (TCP and UDP; 853 if Private DNS is on);
   - TCP 443 to `www.google.com`, which alone decides VALIDATED;
   - TCP 80 to `connectivitycheck.gstatic.com`;
   - Meta's captive fallbacks (`captive.apple.com`, `www.msftconnecttest.com`).

**`share off`:** `pfctl -a com.apple/questlink -F all`, `pfctl -X <token>`, Quest back to a static with no gateway or DNS, `wifi_always_requested` restored.

**UX notes:**
- All Quest traffic, including to other LAN hosts, now goes through the Mac.
- A Wi-Fi network the user explicitly accepted as "no internet" still wins.
- A VPN on the Quest captures everything.
- Re-issuing `set-ip-configuration` restarts `usb0` briefly, so don't toggle sharing mid-stream.

**Fallback F3.** Only on `E4.PF_FAIL`, or `E4.NOT_VALIDATED` where E4-A validates: the manual Internet Sharing procedure (E4-A). It is never automated, and never run alongside the DHCP responder.

**Out of scope:** Quest-to-Mac internet; sharing over Mode A, except the M6 stretch.

---

## 7. Milestone 4: menu bar app

**M4.0 signing spike (first; about half a day).**
- Build a hello-world `SMAppService.daemon` (`Contents/Library/LaunchDaemons/app.questlink.daemon.plist` with `BundleProgram`), signed with the Apple Development identity you have.
- Pass: `register()` succeeds, the daemon launches after approval in System Settings > General > Login Items & Extensions, and an IPC round trip works.
- `M4.0.SIGNING_FAIL` (register throws, or the status stays `.notFound`/`.requiresApproval` under Personal Team [U]) → `sudo questlink daemon install`, which copies the binary to `/Library/PrivilegedHelperTools/` and a plist to `/Library/LaunchDaemons/`.

**Structure:**
- **`QuestLinkBar.app`:** SwiftUI `MenuBarExtra` (`.window` style), `LSUIElement=YES`, launch at login via `SMAppService.mainApp`. It runs as the user and owns the ALVR helper (the user's home), notifications (`UNUserNotificationCenter`), and lock/unlock hints (`com.apple.screenIsLocked`/`screenIsUnlocked` distributed notifications forwarded to the daemon).
- **Root daemon** (`questlink daemon run`, same QuestLinkCore): owns IOKit, Gatekeeper, NetConfig, pcap, pf, `watch`, relay and the journal. launchd daemons are LNP-exempt [V TN3179], so the app itself never triggers a Local Network prompt. `NSLocalNetworkUsageDescription` is still included as a safety net.
- **IPC** (same for both install paths): a Unix socket `/var/run/questlink.sock` (root:admin 0660) carrying newline-delimited JSON, with a `getpeereid` check (console user or admin group). Messages: `status`, `subscribe`, `up(opts)`, `down`, `share(bool)`, `doctor`, `approvals`.

**UI:**
- Stage list mirroring `doctor --json`, collapsed to one line when green.
- Mode chip: Default / NCM (B) / App-USB (A).
- Banners: "Unlock your Mac and click Allow for Quest 3", "Quest rebooted: unlock or replug to rename", "VPN X is capturing 192.168.42.0/24".
- Buttons: Connect, Disconnect, "Restore USB for Link & Virtual Display", Share-internet toggle (with a "Keep Quest Wi-Fi" sub-toggle), ALVR Pin/Unpin/Launch, Run link test.
- Per-serial "Auto-connect on plug-in" (opt-in).

**Opt-in admin toggles**, each with an explanation and explicit consent, all off by default:
- `scutil --allow-new-interfaces on|off`;
- `AllowedEthernetLocalNetworkAddresses`;
- a link to Privacy & Security > "Allow accessories to connect" (not scriptable).

**Zero-touch flow after setup:**
1. Plug in.
2. The daemon sees the Default composition, the Mac is unlocked (or the Mode B composition is approved), and there is no Mode A request, so it switches to NCM.
3. The service raises enX, the address is applied, and the test runs.
4. The menu shows "Connected 192.168.42.2 · 5 Gb/s · 0.4 ms".

No kext, DriverKit, NetworkExtension or vmnet entitlement is used.

---

## 8. Milestone 5: Quest app "NCM Keeper" (conditional)

**Built only when triggered:** F1 per §4.8, a wish for E7 characterisation, the F2 spike, or the M6 stretch. The primary path needs no Quest app.

**Project:**
- `quest/`, Android Studio with the Gradle wrapper. AGP 8.x, Kotlin 2.x, JDK 21.
- `compileSdk 35`, `targetSdk 34`, `minSdk 32`. Package `app.questlink.keeper`. Install with `adb install -r -g`.
- Manifest meta-data: `com.oculus.supportedDevices = quest3|quest3s|quest2|questpro`.
- Permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE` (also satisfies the Android 14 connectedDevice FGS prerequisite [L]), `CHANGE_WIFI_MULTICAST_STATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`.
- No Meta SDK. No WRITE_SETTINGS or WRITE_SECURE_SETTINGS.

**(a) LinkActivity (2D panel).**
- Status: HzOS build, `ro.product.device`.
- Mode B view: a **listen-only** `registerNetworkCallback` for TRANSPORT_ETHERNET showing `usb0` IPv4, VALIDATED and default. It never requests, because that would pre-empt Mode B.
- Mode A view: interface, fe80, any IPv4, `NOT_RESTRICTED`/`FOREGROUND`, and `getLinkDownstreamBandwidthKbps` (warn below 1,000,000, which means USB 2).
- "Use USB link" button, foreground only. The consent appears only in the foreground; background requests are dropped after 30 s [V].
  ```kotlin
  val req = NetworkRequest.Builder()
      .addTransportType(NetworkCapabilities.TRANSPORT_USB)          // 8
      .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) // 12
      .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)  // 14
      .build()
  cm.requestNetwork(req, callback)   // onUnavailable: allow retry; onLost: clear + re-request
  ```
- Refuses to request while a Mode B ETHERNET network on `usb0` exists, and explains why.
- Link test against `questlink test --serve`, with sockets from `network.socketFactory` or `network.bindSocket`.

**(b) KeeperService.** A `connectedDevice` foreground service that holds the callback. Persistent notification with a prominent **Release** button (holding the request pre-empts other USB networking [V]). It stops when released and never uses `bindProcessToNetwork`.

**(c) Inbound relay (F1).**
- `ServerSocket`s bound to the Network on `[fe80::own%usb0]:19943/19944`, plus `192.168.42.2` if E6b gave IPv4. Never `[::]:9943`, which collides with ALVR's 0.0.0.0 listeners.
- Each accept is piped to `127.0.0.1:9943/9944` with `TCP_NODELAY` and about 256 KiB buffers.
- Mac side: `questlink relay`. ALVR: `alvr pin --relay` (removes `client.wired` and adb forwards; entry `quest.relay` → `127.0.0.1`, so wired and TCP).
- If `E6b.STATIC_IN_LOCAL`, skip the relay: the Keeper only holds the request and ALVR pins 192.168.42.2 directly.

**(d) Outbound local-forward (optional).** For Quest-initiated IPv4-only apps in Mode A (Moonlight 47984/47989/48010 TCP and 47998–48000 UDP, VNC 5900): listen on Quest `127.0.0.1:N` and dial the Mac through sockets bound to the USB Network.

**(e) Experimental F2 flag.** `Intent("horizonos.net.ethernet.SET_LOCAL_IP").setPackage("android")` with the extras captured in E9, sent before requesting. Log any SecurityException [U; may be allowlisted to Steam Link].

**(f) M6 stretch: VpnService internet over Mode A** [U on Horizon]. Fork gnirehtet (Apache-2.0):
1. Dial the tunnel from a socket passed to `usbNetwork.bindSocket()` plus `protect()`, to `[fe80::mac%usb0]:31416`.
2. `addDisallowedApplication` for the Keeper, `alvr.client`, VD, Steam Link and WiVRn.
3. `addRoute("0.0.0.0",0)`.
4. `excludeRoute` (API 33) for 192.168.42.0/24, 10.86.13.32/29, fe80::/10 and the current Wi-Fi LAN.
5. `setUnderlyingNetworks(arrayOf(usbNetwork))`, `setMetered(false)`, and `addDnsServer` = the relay's resolver.
6. Mac side: the gnirehtet relay on 127.0.0.1:31416, bridged by `questlink relay --map '[fe80::mac%enX]:31416=127.0.0.1:31416'`.

**Lifecycle tests (E7/E8):** survival while the immersive ALVR client has focus and through proximity sleep, and whether USB adb survives a held request. `E8.RELAY_FROZEN` → F1 is not viable; stay on Mode B or F5.

**References, read only and never copied:** WiVRn commit 8738131 and moonlight-android-xr PR #31 (GPL-3.0).

---

## 9. App-compat procedures

### 9.1 ALVR / wine-vr manual proof (Mode B, TCP; no wine-vr or ALVR code changes)

**Facts** [V-here]:
- The server dials the client: TCP 9943 control, 9944 stream. The client listens on IPv4 `0.0.0.0` only.
- `wired = client_ip.is_loopback()` forces TCP; otherwise the `stream_protocol` setting applies.
- If `client.wired` exists and adb sees the Quest, ALVR itself creates the 9943/9944 forwards and autolaunches `alvr.client` (Ready, 127.0.0.1), or returns `NotReady`, which skips manual IPs. Removing it **before** start is mandatory.
- `NoDevice` falls through to manual IPs (oxrsys patch). Manual IPs are dialled before discovery.
- **Do not use `127.0.0.1:8082`**: OrbStack listens there. ALVR's dashboard listens on `*:8082`.

**Steps:**
1. **Link up:** `sudo questlink up` (or the E3 state). Check `ping -b $IF -c3 192.168.42.2` and that `route -n get 192.168.42.2` shows enX.
2. **Stop the core and confirm it is stopped** (by the ALVR listener, not by port occupancy):
   ```zsh
   cd ~/projects/personal/wine-vr && ./demo.sh stop --bottle <b>
   lsof -nP -iTCP:8082 -sTCP:LISTEN | awk 'NR>1 && $9=="*:8082"'    # must print nothing
   ```
3. **Pin offline.** `questlink alvr pin` automates this; the manual equivalent:
   ```zsh
   cp "$ALVRS" "$ALVRS.bak-ncm-$(date +%Y%m%d-%H%M%S)"
   python3 - "$ALVRS" <<'PY'
   import json, sys
   p = sys.argv[1]; s = json.load(open(p)); cc = s['client_connections']
   cc.pop('client.wired', None)                         # else ALVR re-creates adb forwards (Mode B keeps adb)
   for v in cc.values(): v['manual_ips'] = []           # clear stale Wi-Fi pins (<lan-ip>)
   cc['quest.ncm'] = {'display_name': 'Quest 3 (NCM)', 'current_ip': None,
                      'manual_ips': ['192.168.42.2'], 'trusted': True, 'connection_state': 'Disconnected'}
   c = s['session_settings']['connection']
   c['stream_protocol'] = {'variant': 'Tcp'}
   c['client_discovery']['enabled'] = False             # no Wi-Fi fallback during the proof
   json.dump(s, open(p, 'w'), indent=2)
   PY
   ```
   Edit in place; never delete the file. A regenerated one streams a black 800x900 frame and re-seeds `client.wired`.
4. **Clear forwards:** `adb forward --list` must show nothing on 9943/9944 (`adb forward --remove-all` if it does).
5. **Start wine-vr from Terminal.app** (LNP-exempt; iTerm2 is also allowed here), **without** `--wired`:
   ```zsh
   cd ~/projects/personal/wine-vr && ./demo.sh run --bottle <b>
   lsof -nP -iTCP:8082 -sTCP:LISTEN            # now shows both 127.0.0.1:8082 (OrbStack) and *:8082 (ALVR)
   adb forward --list                          # still empty
   ```
   `./demo.sh doctor` will warn about the IP pin; that is expected.
6. **Launch the client by hand.** Autolaunch stopped when `client.wired` was removed.
   ```zsh
   adb -s $Q shell pm list packages | grep -i alvr     # expect alvr.client (session wired_client_type = Store)
   adb -s $Q shell monkey -p alvr.client -c android.intent.category.LAUNCHER 1    # or: questlink alvr launch
   ```
7. **Verify:**
   ```zsh
   lsof -nP -iTCP:9943 -iTCP:9944 | grep ESTABLISHED           # peers 192.168.42.2:9943 and :9944
   python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/Library/Application Support/OXRSys/alvr/session.json')));print(d['client_connections']['quest.ncm']);print(d['session_settings']['connection']['stream_protocol'])"
   netstat -I $IF -b | tail -1; sleep 10; netstat -I $IF -b | tail -1   # ~bitrate x 10 s / 8 (80 Mbit/s ≈ 100 MB)
   netstat -I en0 -b | tail -1; sleep 10; netstat -I en0 -b | tail -1  # roughly flat
   sudo tcpdump -ni $IF -c 20 'tcp port 9944'
   adb kill-server; sleep 30; adb start-server                   # optional: stream unaffected (no adb dependency)
   ```
   `current_ip` may lag if the session has not been flushed; `lsof` is authoritative [L].
8. **Latency.** Compare ALVR `[GRAPH]`/`[STATS]` network latency with the baselines: adb 2.7 ms p50; Wi-Fi about 6–7.4 ms p50 (`wine-vr/docs/bridge-findings.md`). Play 5–10 minutes of Beat Saber.

**UDP phase** (F4; only after E4 or `share on` shows VALIDATED): stop the core, set `stream_protocol` to `{"variant":"Udp"}` offline (or `questlink alvr pin --udp`), restart, and check `sudo tcpdump -ni $IF udp port 9944`. Before validation, UDP fails silently, because the client's UDP socket follows Wi-Fi.

**Live API (mid-session changes only).**
- Use it only when a `*:8082` listener exists: `API=http://192.168.42.1:8082/api/dashboard-request`. ALVR binds 0.0.0.0 and checks only the header.
- One-time sanity check that the two listeners differ: `curl -sI --max-time 3 http://127.0.0.1:8082/` (OrbStack / paperless) vs `curl -sI --max-time 3 http://192.168.42.1:8082/` (ALVR / hyper) [L].
- Bodies match the ALVR v20.14.1 serde shapes [V static; not yet executed live]:
  ```zsh
  curl -s --max-time 5 -H 'X-ALVR: true' -d '{"UpdateClientList":{"hostname":"client.wired","action":"RemoveEntry"}}' $API
  for h in 3051.client 1857.client 4253.client; do curl -s --max-time 5 -H 'X-ALVR: true' -d "{\"UpdateClientList\":{\"hostname\":\"$h\",\"action\":{\"SetManualIps\":[]}}}" $API; done
  curl -s --max-time 5 -H 'X-ALVR: true' -d '{"UpdateClientList":{"hostname":"quest.ncm","action":{"AddIfMissing":{"trusted":true,"manual_ips":["192.168.42.2"]}}}}' $API
  curl -s --max-time 5 -H 'X-ALVR: true' -d '{"SetValues":[{"path":[{"Name":"session_settings"},{"Name":"connection"},{"Name":"stream_protocol"},{"Name":"variant"}],"value":"Tcp"}]}' $API
  curl -s --max-time 5 -H 'X-ALVR: true' -d '{"SetValues":[{"path":[{"Name":"session_settings"},{"Name":"connection"},{"Name":"client_discovery"},{"Name":"enabled"}],"value":false}]}' $API
  ```
- Always re-read `session.json` about 1–2 s later: `SetValues` errors are swallowed (`.ok()`).
- `RemoveEntry` on a connected client first becomes `Disconnecting`. Protocol and discovery changes apply at the next connection.
- Security note (pre-existing in ALVR): the dashboard API is reachable on every interface, including the cable, guarded only by the header.

**Restore:**
1. `./demo.sh stop --bottle <b>`.
2. Copy the newest `session.json.bak-ncm-*` back, or `questlink alvr unpin`.
3. `questlink down` (Quest `usb0` → dhcp, pf released).
4. Replug to restore the Default composition.

**Troubleshooting:**

| Symptom | Cause and fix |
|---|---|
| `current_ip` 127.0.0.1 / wine connected to 127.0.0.1 | `client.wired` or a forward survived: stop, redo step 3, `adb forward --remove-all` |
| No connection | `nc -vz 192.168.42.2 9943` from the same terminal app while the client is in its lobby. EHOSTUNREACH → LNP (see E5 outcomes) |
| Connects over Wi-Fi | Discovery or a Wi-Fi pin is still active |
| Live API "does nothing" | You hit 127.0.0.1:8082 (OrbStack), or no `*:8082` listener exists: use offline mode |
| UDP stalls | Use Tcp, or finish share validation |

### 9.2 Virtual Desktop (Mode A, desktop streaming)

1. `sudo questlink vd prepare`: Mode B down (`usb0` → dhcp unless `--sticky` is allowed and set), Default composition restored, the Quest service present with IPv6 LinkLocal, then wait for the Mode A composition.
2. Headset: VD on the **Beta** channel; VD "Allow to connect over USB" plus the system "USB connection for apps" consent, given in the foreground. Mac: VD Streamer 1.34.22 running; it already has Local Network permission.
3. First time only: click **Allow** on the Mac for VD's composition. The companion records it, checks that enX is UP/RUNNING with fe80, and that the Quest answers `ping6 ff02::1%enX`.
4. Headset: expect "USB 3 5,120Mbps". Pull to refresh Computers 2–3 times and choose the blue USB entry. Optionally turn Quest Wi-Fi off to prove the path.

**Caveats:**
- Mac hosts get desktop streaming only; VD PCVR is Windows-only.
- VD's request pre-empts Mode B; `watch` stands down.
- The Streamer appears to skip adapters named "Tailscale" [L].
- Minimum HzOS 2.4 vs 2.5 is disputed [C].
- Only one first-hand Mac success report exists [V].

### 9.3 Meta Quest Virtual Display / Remote Desktop (Mac app 107.0.0.1.108)

- **Supported path:** the Default composition over Wi-Fi.
  - Run `questlink down --restore-usb` (or replug) first: Mode B drops the ff/8B and ff/8C vendor interfaces its dormant "Disco USB" transport needs.
  - That transport is server-gated off anyway (`discoServerEnabled=false`) [V].
  - Check with E12.
- **Optional side test** (untested, and uses the cable only incidentally):
  1. `sudo questlink up --share`, without `--keep-quest-wifi`, so `usb0` becomes the only Quest network.
  2. Re-enable Local Network for "Meta Quest Virtual Display" in System Settings > Privacy & Security > Local Network. It currently reads Denied.
  3. Start a session.
  4. Watch `nettop -m route -p "Meta Quest Virtual Display"` and `netstat -I $IF -b`.

  Tell the user before changing that toggle, and restore it afterwards. Both ends still need internet for signalling.

### 9.4 Others

- **Steam Link / SteamVR USB** (Windows/Linux hosts): a confounder only. On 2.7 it can leave `usb0` STATIC 10.86.13.37/29 and hold a USB request. `doctor` and `up` detect both and offer force-stop plus `--reset-usb0`.
- **WiVRn:** Linux-only server. GPL reference code only.
- **Moonlight/Sunshine, Screen Sharing (VNC 5900), Quest browser:** under Mode B + share (`usb0` is the default), connect to 192.168.42.1. In Mode A, only via the Keeper local-forward (Sunshine `address_family=both` if IPv6 is needed).

---

## 10. Reusable components and licenses

| Component | License | Use |
|---|---|---|
| AppleUSBNCM.kext, pf (`com.apple/*` anchors), SystemConfiguration, IOKit, Network.framework, libpcap (SDK), networksetup/ipconfig/scutil | macOS in-box | Runtime; nothing to install |
| swift-argument-parser | Apache-2.0 | The only Swift dependency |
| apple-oss-distributions/configd (InterfaceNamer, SCMonitor, IPMonitor, SCNetworkService PrimaryRank) | APSL-2.0 | Behaviour and key-name reference only |
| apple-oss-distributions/bootp (`udp_transmit.c`) | APSL-2.0 | Raw-frame transmit pattern (re-implement, don't copy) |
| UbootVRC/Wired-Steam-Link-VR (`QuestNcmLink.ps1`) | MIT | Port the DHCP option set and Mode B lessons. **Avoid the Siken9013 fork** (looks like a malware repackage) |
| szcharlesji/AnyTeleop `docs/glove.md` | check before quoting | `cmd ethernet` usage and Quest routing observations |
| AngelDark92/steamlink-patches diagnostics | check | SET_LOCAL_IP / TRANSPORT_USB sequence (F2 reference) |
| VD Streamer `IsUsbAdapter` idea | proprietary binary | Idea only (`CFBundleIdentifierKernel` contains `usb.cdc.ncm`) |
| ya-webadb / dadb | MIT / Apache-2.0 | adb wire protocol, only if `M1.ADB_FLAKY` |
| gnirehtet | Apache-2.0 | M6 VpnService stretch |
| netanelc305/mac_internet_sharing | license unverified | `com.apple.nat.plist` pattern, reference only (don't copy its hardcoded bridge100 check) |
| WiVRn (8738131), moonlight-android-xr PR #31 | GPL-3.0 | Read-only references; never copied |
| ALVR (wine-vr `ext/ALVR`) | MIT | Dashboard API and session schema only |
| AndroidX core/appcompat | Apache-2.0 | Quest app |
| iperf3 | BSD-3-Clause | Optional benchmarking (E11) |
| dnsmasq | GPL | Optional external DHCP in experiments; not installed, and not needed if E3 passes |

Repo license is your choice. Nothing GPL is copied. MPL-2.0 would match wine-vr's SPDX headers.

---

## 11. Repo layout

```
~/projects/personal/ncm/
  README.md                    what it is; quick start (sudo questlink up); safety notes; cleanup
  LICENSE
  .gitignore                   .build/, quest/**/build/, *.apk, local.properties, docs/evidence/**/raw-pcap
  docs/
    PLAN.md                    this plan
    gates.md                   the six gates with evidence
    m0-results.md              filled during M0
    decisions.md               §4.8 outcomes, E10 rule table, triggered fallbacks
    runbooks/                  recovery.md alvr-wine-vr.md virtual-desktop.md virtual-display.md internet-sharing.md
    evidence/<date>/           E0..E12 raw captures (source of test fixtures)
  scripts/m0/lib.sh            §4.1 helpers (the only M0 script)
  mac/                         SwiftPM package (§5.2)
  menubar/                     QuestLinkBar.xcodeproj (links ../mac QuestLinkCore), daemon plist
  quest/                       Android project "NCM Keeper" (only if M5 triggers)
```

`git init` at M1 (your call).

---

## 12. Risks and mitigations

| Risk | Likelihood / impact | Mitigation | Detected at |
|---|---|---|---|
| Quest 3 `usb0` takes no IPv4 in Mode B (U1) | Medium / High | E2/E3 in the first hour; §4.8 routes to DHCP, F1 or F5; F6 stays working | E2, E3 |
| Mode A holder or Steam Link STATIC leftover makes Mode B look broken | Medium / Medium | Preflight S2 detection, force-stop, `--reset-usb0`; `watch` never fights Mode A | E0, S2 |
| Gate 3 silent failure (`ifconfig up` exits 0; stale "active") | Medium / Medium | Require RUNNING + IOControllerEnabled + a pcap peer frame | E2, S8/S10 |
| Persistent service doesn't re-raise enX (U5) | Low–Med / Medium | E3.persist; per-attach `ipconfig set` fallback | E3d |
| Unapproved composition while locked kills USB adb; possible all-accessory escalation (1 vs 5) | Medium / High | Switch over Wi-Fi adb; lock gate; ApprovedStore; E10 before M3; hard block on `E10.ESCALATE_1` | E10 |
| TRM relaxed/unlocked periods hide the prompt this week | High / Low | Record keys every run; re-test after relaxation ends; UX designed from E10 | E1, E10 |
| Quest reboot → new host MAC → new `enN`, orphaned service, unnamed while locked | High / Low | Never cache `enN`; `watch` creates and GCs services; re-enumerate after unlock; opt-in AllowNewInterfaces | E10, V11 |
| `usb0` decays while unvalidated (U3) | Low–Med / Medium | 10-minute hold; `watch` re-applies; share validation | E3b |
| `cmd ethernet` STATIC persists after a crash or typo | Medium / Medium | Write-ahead journal; `repair` at every `up`; typed mode words; revert-by-default; `--sticky` gated on E6b | V9 |
| ALVR dashboard on 127.0.0.1:8082 is OrbStack's | Certain today / Medium | Offline pin by default; live API only via `*:8082` + a non-loopback address; `doctor` S16 names the owner | S15/S16 |
| `client.wired` race gives a false-positive proof over adb | High if naive / High | Remove before start; verify `lsof` peers + enX counters + `adb kill-server` test | E5, V12 |
| adb run as root (new RSA prompt, root-owned server) | High if naive / Medium | Exec as `$SUDO_USER`; V2 checks port 5037's owner | V2 |
| pf mistake breaks OrbStack or InternetSharing | Low / High | Anchor + token only; never `-d` or main flush; V8 checks OrbStack | V8 |
| Rogue DHCP or a UDP 67 clash | Low / High | pcap on enX only; Quest-MAC-only; refuse when Internet Sharing is active; conditional bind | T8 |
| VPN/filter extensions block, divert or fake success | Medium / Medium | RTM_GET = enX check; `IP_BOUND_IF`/`ping -b` in all tests; E11 matrix; S16 warnings | E11, V13 |
| LNP blocks the Wine process (macOS 27 grant bug r.181140179; CrossOver GUI attribution unknown) | Medium / Medium | Terminal.app launch; root/daemon companion I/O; defaults-key fallback; F1 keeps Wine on loopback | E5, E11 |
| Sharing side effects (Wi-Fi teardown, all Quest traffic via the Mac, adb-over-Wi-Fi recovery lost) | Medium / Low | `--keep-quest-wifi` with journaled revert; UX text; recovery via `adb connect 192.168.42.2:5555` | E4 |
| Mode B drops Meta vendor interfaces (Link, future Virtual Display USB) | Certain / Low | `down --restore-usb`, replug, E12 | E12, V14 |
| Firmware/OS drift (Meta DeviceConfig pushes, NetworkStack option-108 rebase, monthly HzOS DHCP regressions, macOS NCM → DriverKit) | Medium over time | `doctor --json` records builds, the regex and `adc_ethernet_over_usb_enabled`; re-run E1–E3 after any update; never send option 108 | per update |
| Menu bar daemon signing insufficient | Unknown | M4.0 spike first; legacy install fallback | M4.0 |
| Evidence thinness (single-source RE, one Quest 2 report, one Mac VD report) | n/a | Every [U] has a named experiment (§14); decisions recorded | M0 |
| Small latency gain over adb forward (about 1–2 ms) | Likely / Low | The claim is robustness, no adb dependency and freed Wi-Fi; keep F6 as the A/B baseline | E5, E11 |

---

## 13. Verification (end to end)

Numeric targets are estimates [U] until E11.

| ID | Test | Commands | Expected |
|---|---|---|---|
| V1 | Build + unit tests | `cd ~/projects/personal/ncm/mac && swift build -c release && swift test` | `Test Suite 'All tests' passed`: SubnetPicker rejects 192.168.138.0/23; the ALVR offline edit removes `client.wired` and sets `{"variant":"Tcp"}`; ALVR bodies equal §9.1; pf render equals the golden string; parsers pass on M0 fixtures; DHCP golden bytes (if built) |
| V2 | Doctor, no Quest, no side effects | `.build/release/questlink doctor; echo $?; networksetup -listallnetworkservices; lsof -nP -iTCP:5037 -sTCP:LISTEN` | `[--] USB: no device with VID 0x2833` (exit 20); `[warn] 127.0.0.1:8082 owned by OrbStack`; filters listed; service list unchanged; no questlink state dir created; the 5037 listener owned by the user, not root |
| V3 | Cold bring-up (composition approved) | Plug in (Default); `sudo questlink up` | Ends `LINK UP mode=B …` in under 30 s. `ifconfig enN`: `flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST>`, `inet 192.168.42.1 netmask 0xffffff00`, `inet6 fe80::…%enN`, `status: active`. `ioreg -r -c AppleUSBNCMData -l -w0 \| grep IOControllerEnabled` gives `Yes`. `adb -s $Q shell ip -4 addr show usb0` gives `inet 192.168.42.2/24` |
| V4 | Route safety | `questlink snapshot` before and after V3; `diff` | `route -n get default` identical (en0); `scutil --dns` identical; service order the same plus one appended "Quest NCM (questlink) enN"; `sudo pfctl -sr` byte-identical; `route -n get 192.168.42.2` gives `interface: enN`. Negative test: `sudo ifconfig lo0 alias 192.168.42.9/32` makes `up` refuse (or pick `--subnet`); undo with `sudo ifconfig lo0 -alias 192.168.42.9` |
| V5 | Link test | `sudo questlink test --seconds 10` | ICMP loss 0%, p50 under 1 ms; TCP at least 300 Mbit/s each way on USB 3; enN byte delta ≥ bytes moved; en0 delta under 1% |
| V6 | Idempotency + teardown | `sudo questlink up` ×2; `sudo questlink down --restore-usb` ×2 | Second `up` reports no changes. `down` returns usb0 to dhcp (`dumpsys ethernet` has no usb0 STATIC). Second `down` is a no-op. After the replug prompt, `qusb` shows a Default PID with ff/8B and ff/8C |
| V7 | Sharing | `sudo questlink share on --keep-quest-wifi` | `sudo pfctl -a com.apple/questlink -s nat` shows `nat on en0 inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> (en0) round-robin`. Within 45 s the usb0 ETHERNET network is VALIDATED and default. `adb shell ip route get 1.1.1.1` gives `dev usb0`. `adb shell ping -c3 www.google.com` works. The Quest browser loads a page. Quest Wi-Fi is still connected after 60 s. Mac default route unchanged; OrbStack containers reachable |
| V8 | Sharing off | `sudo questlink share off` | Anchor empty; our token gone from `sudo pfctl -s References`; the Quest static has no gateway; `settings get global wifi_always_requested` back to the prior value; OrbStack unaffected |
| V9 | Crash recovery | `QUESTLINK_FAULT=after:S14 sudo questlink up --share`, then `sudo questlink repair` | Same end state as V6 + V8 (no anchor, no token, usb0 dhcp, settings restored) |
| V10 | Lock policy (M3) | Pre-armed `sleep 15; sudo -n questlink up` with an unapproved composition target, then lock; repeat with an approved one | Unapproved: exit 10, no switch, `TRM_CacheMissCount` unchanged. Approved: proceeds, and the link comes up while locked |
| V11 | Quest reboot churn (M3) | `sudo questlink watch` running; `adb reboot`; unlock if prompted | New `enN` detected; new service created; the old questlink service GC'd; link back within 60 s of the device returning. Locked case: `doctor` reports `_Locked_` and it recovers after unlock + re-enumeration |
| V12 | ALVR proof via CLI | Stop the core → `questlink alvr pin` → `./demo.sh run --bottle <b>` (Terminal.app) → `questlink alvr launch` | `quest.ncm.current_ip == "192.168.42.2"`; `lsof` ESTABLISHED to .2:9943 and .2:9944; stream bytes on enN, en0 flat; 10 minutes of play; survives `adb kill-server`; `questlink alvr unpin` gives an empty JSON diff against the backup |
| V13 | Mode conflict and interference | While Mode B is up, start VD Beta USB; then the E11 extension rows | `doctor` shows an S2 conflict naming the VD package; `up` refuses without `--force-stop-holders`. For each extension, pass or a named S16 warning matching the observed failure; no silent success via a wrong route |
| V14 | VD Mode A and Virtual Display regression | §9.2; E12 | VD stream over enN with Quest Wi-Fi off, and `questlink mode` reports `A (app-held), fe80 only`. After restore, Virtual Display connects and the newest `mqrd_*.log` contains `Client Connected on RTC` |
| V15 | Menu bar (M4) | Install and approve the daemon; plug in; Connect / Share / Release from the menu; lock the screen during a Release | Stages match `questlink doctor --json`; the Allow banner appears for a new composition; no switch is attempted while locked (daemon log); the daemon survives app quit (`launchctl print system/app.questlink.daemon` shows `state = running`) |
| V16 | Quest app (only if M5) | E7, E8 | The probe shows fe80, bandwidth and capabilities; the F1 stream runs with wine connected to 127.0.0.1:9943/9944 and the relay connected to `[fe80::…%enN]:19943/19944`; it survives `adb kill-server` |

---

## 14. Unverified and contested register

| Item | Tag | Settled by |
|---|---|---|
| Quest 3 current build tracks `usb0`, sends DISCOVER, accepts `cmd ethernet … usb0 static`; exact `--gateway`/`--dns` flag names | U | E0 help text, E2, E3 |
| Mac-dialled TCP answered over a non-default `usb0` (shell uid; ALVR app uid) | L | E3, E5 |
| Unvalidated `usb0` stays up indefinitely | L | E3b |
| SCMonitor auto-creates, prompts, or does nothing for the Quest enX | C | E1 |
| A persistent router-less service re-raises enX on re-attach and after wake | L | E3d, E11 |
| `networksetup -setmanual` accepted without a router | U | E3d (the CLI uses SCPreferences) |
| PrimaryRank raw-key placement takes effect | L | T5 (`scutil show Setup:/Network/Service/<id>`) |
| `svc usb resetUsbGadget` available on HzOS; `svc usb setFunctions` with no argument restores Meta's Default | L / U | E0, E1, E10 |
| PID and interface set per composition; separate TRM prompt each; effect of RelaxedPeriod/UnlockedPeriod | U | E1, E6, E10 |
| New `enN` per Quest boot; InterfaceNamer `_Locked_` behaviour | L / V | E10 |
| TRM escalation (1 vs 5 misses); Mac approval lifetime (`TRM_PolicyTimeout` 604800 s?) | C / U | E10; lifetime observed over time |
| pf NAT validates `usb0`, how fast, and with a VPN utun as egress; `wifi_always_requested` keeps Wi-Fi | U / L | E4, E11 |
| Internet Sharing alongside OrbStack's six vmnet bridges | U | E4-A (only if triggered) |
| VD Mode A end to end on macOS 27 with Streamer 1.34.22; minimum HzOS 2.4 vs 2.5 | L / C | E6 |
| STATIC `usb0` applies in LOCAL mode and doesn't break VD | U | E6b |
| 127.0.0.1:8082 requests reach OrbStack rather than ALVR while both are bound | L | `curl -sI` comparison in §9.1 during E5 |
| libpcap `pcap_inject` on macOS sends frames with enX's source MAC | L | T8 tcpdump check |
| SMAppService daemon under the available signing identity | U | M4.0 |
| Keeper survives while the immersive ALVR client has focus; USB adb survives a held request; IPv4 on 2.7 for third parties | U | E7, E8 |
| Third-party `SET_LOCAL_IP` honoured; persistence across reboots | U | E9 |
| Throughput, RTT, jitter of AppleUSBNCM with Quest f_ncm; ALVR jitter at 80–150 Mbit/s | U | E11, V5, V12 |
| Virtual Display WebRTC uses the cable in share mode with Local Network re-enabled | U | §9.3 optional |

---

**Execution order:**
1. M0 Session 1 → decision gate (§4.8).
2. M1.
3. M0 Session 2.
4. M2 (share, `vd prepare`, `--sticky` if E6b passes).
5. M0 Session 3 (E10 before any lock-gate code; E11 with `questlink test`; E12).
6. M3 (`watch`, lock gate).
7. M4 (signing spike first).
8. M5 and M6 only if their triggers fire.

**Rough effort:**

| Milestone | Estimate |
|---|---|
| M0 | about 5.5 headset-hours over three sessions |
| M1 | 3–4 days (+1–2 if DHCP) |
| M2 | 1–1.5 days |
| M3 | 2 days |
| M4 | 3–4 days |
| M5 | 3–4 days (conditional) |
