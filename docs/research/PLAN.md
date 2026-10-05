# Plan: `questlink`, a Quest 3 ↔ macOS USB CDC-NCM direct link (demo)

Date: 2026-09-29. Repo: `~/projects/personal/ncm` (empty, not yet a git repo).
Full detailed draft (pre-review; every exact command is in it): `docs/plan-detailed-draft.md` (copied from the workflow journal). This file supersedes it wherever they differ.
Tags: [V] verified, [V-here] checked on this Mac, [L] likely, [U] unverified (the experiment that settles it is named), [C] contested.

## 1. Context

**Goal.** A demo proving a direct USB network link between a Meta Quest 3 and this MacBook Pro (Mac15,9, M3 Max, macOS 27.0 26A428), using only macOS's in-box `com.apple.driver.usb.cdc.ncm`. Once the link is up, apps should be able to use it: wine-vr (embedded ALVR v20.14.1 server with the stock ALVR client), Virtual Desktop, and Meta Quest Virtual Display where possible. Optional: Mac → Quest internet sharing.

**User decisions.**
- Internet sharing: Mac → Quest only.
- Focus on the macOS side ("macOS weirdness").
- Swift CLI first, then a menu bar app.
- wine-vr: manual proof only. No wine-vr or ALVR code changes, and no ALVR automation in the companion.

**What the research found** (about 250 agents, adversarially verified):

1. **The Mac driver is not the problem.** AppleUSBNCM 5.0.0 matches any class 2/13/* interface with no VID/PID keys. The Quest 3 kernel (5.10.246) uses stock Linux `f_ncm` (NCM 1.0, NCAPS 0x11) [V]. What Windows handles for you, and what we must build, is the plumbing. There are six gates:
   1. **TRM accessory approval.** This Mac is set to "Ask for New Accessories". Each USB composition counts as a new accessory.
   2. **InterfaceNamer.** configd ignores a new interface that arrives while the Mac is locked, and never retries after unlock.
   3. **Nobody raises enX.** Until something brings enX UP, the Quest's `usb0` has NO-CARRIER. The driver reports the link only after f_ncm sends NETWORK_CONNECTION.
   4. **No address.** In adb mode the Quest is a DHCP *client*. The Mac falls back to 169.254, and on this Mac the 169.254 route is pinned to en0.
   5. **Routing.** The Quest sends its own traffic and UDP via Wi-Fi unless `usb0` is its validated default network. If a router is advertised to the Mac, the Mac's default route could move.
   6. **App gates.** Local Network Privacy (GUI apps and CrossOver are gated; Terminal.app, root and launchd daemons are exempt; macOS 27 has an LNP grant bug, r.181140179). Installed VPN/filter extensions: ProtonVPN, Tailscale, TripMode, Cisco, Pangolin, Shadowrocket.
2. **The Quest has two NCM modes, and they are mutually exclusive on one cable.**
   - **Mode A (official, Horizon OS 2.4/2.5+).** An app calls `ConnectivityManager.requestNetwork` with TRANSPORT_USB, removing INTERNET and TRUSTED. Confirmed on Meta's live "AOSP features on Horizon OS" page (Sep 8, 2026, read via Playwright):
     - The consent dialog is system-wide, one-time, and shown only while the app is in the foreground. A background request is dropped after 30 s: `onUnavailable()` fires, the callback is already unregistered, so call `requestNetwork()` again.
     - The link is IPv6 link-local with no internet. Apps bind sockets to the returned Network and find the peer over mDNS.
     - `getLinkDownstreamBandwidthKbps()` reports about 480,000 on USB 2 and about 5,120,000 on USB 3.
     - Holding the request pre-empts other USB networking. `unregisterNetworkCallback()` releases it.
     - Used by: Virtual Desktop Beta 1.34.19+, Steam Link, and WiVRn.
   - **Mode B (adb).** `adb shell svc usb setFunctions ncm` (never `ncm,adb`; adb is ORed back in).
     - On current HzOS 2.7 firmware, EthernetTracker claims `usb0` in GLOBAL mode (DHCP client, can validate and become the default network), *unless* any app holds a TRANSPORT_USB request [V static firmware analysis].
     - USB PIDs (VID 0x2833): 0x5009 ncm, **0x500A ncm+adb**, 0x5017 xrsp+ncm, 0x5018 xrsp+ncm+adb.
     - It is the only mode that gives stock IPv4-only ALVR a direct path, and the only one that allows Mac → Quest internet.
3. **Virtual Desktop.**
   - The VD macOS Streamer 1.34.22 already detects AppleUSBNCM interfaces and advertises their fe80 address [V, IL analysis].
   - There is one first-hand report of a Mac working over USB, using the VD Beta headset app.
   - Desktop streaming only; PCVR is Windows-only.
4. **Meta Quest Virtual Display has no USB mode.** Its dormant "Disco USB" libusb transport is server-gated off. It stays on Wi-Fi.
5. **Local gotchas [V-here].**
   - OrbStack (paperless-ngx) listens on **127.0.0.1:8082**. ALVR's dashboard binds `*:8082`, so loopback requests hit OrbStack.
   - An existing `client.wired` entry lets ALVR re-create adb forwards and connect over 127.0.0.1 before manual IPs are tried.
   - Use `system_profiler SPUSBHostDataType`; `SPUSBDataType` does not exist on 27.0.
   - Interactive zsh has INTERACTIVE_COMMENTS off, so pasted lines with `# … [U]` abort.
   - InternetSharing already runs for OrbStack's vmnet bridges.

**Unknowns that decide the plan (settled in M0):**
- U1: does a Quest 3 `usb0` take IPv4 in Mode B (DISCOVER, or `cmd ethernet set-ip-configuration usb0 static`)?
- U2: is Mac-dialled TCP answered over a non-default `usb0`?
- U5: does a persistent router-less Mac service re-raise enX on its own?
- Also: TRM and lock behaviour per composition, NAT validation, VD over Mode A, and whether STATIC applies in LOCAL mode (E6b).

## 2. Architecture (recommended)

```
Quest 3 usb0 ==== CDC-NCM (NTB16, MTU 1500, USB 3) ==== AppleUSBNCMControl/Data -> enX (Mac)
Mode B: 192.168.42.2/24 (cmd ethernet static)     Service "Quest NCM (questlink) enX":
  [share: gw .1, dns R]                             IPv4 Manual 192.168.42.1/24, NO router, IPv6 LinkLocal
ALVR client 0.0.0.0:9943/9944 <-- TCP dial ------ wine-vr ALVR core (launched from Terminal.app)
VD headset (Mode A, fe80)     <-- fe80 ---------- VD Streamer 1.34.22
[share] default via .1 ------> pf nat-anchor com.apple/questlink -> primary egress
Control plane: adb over Wi-Fi (<quest-wlan-ip>:5555) for composition switches; USB adb otherwise.
```

**One recommendation per concern.** Each fallback fires only on a named M0 outcome.

| Concern | Recommended | Fallback (trigger) |
|---|---|---|
| Link mode | Mode B, driven over adb by the Mac CLI. No Quest app | F1: Mode A + Quest "Keeper" relay app (Mode B addressing dead but `E6.LINK_PASS`); F5: USB-C Ethernet adapter on the Quest (`E1.NO_BIND`/`E2.NO_CARRIER` **and** `E6.LINK_FAIL`) |
| Raising enX (Gate 3) | Persistent SCPreferences service: Manual .1/24, no Router key, IPv6 LinkLocal, raw `PrimaryRank=Never` as extra safety | Per-attach `ipconfig set enX MANUAL` (`E3.PERSIST_FAIL`) |
| Quest IPv4 | `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24` | libpcap DHCP responder (BPF inject, Quest-MAC-only, never option 108) if `E3.CMD_REJECTED` + `E2.DISCOVER_SEEN`; macOS Internet Sharing as a zero-code stand-in during M0 |
| Quest-side persistence | `down` reverts `usb0` to dhcp | `--sticky` opt-in, only after `E6b.STATIC_IN_LOCAL` and without `E6b.STATIC_BREAKS_VD` |
| Mac → Quest internet | pf anchor NAT + Quest gateway/DNS set via adb, so `usb0` validates and becomes the Quest default | Internet Sharing (`E4.PF_FAIL`/`E4.NOT_VALIDATED`) |
| ALVR | Manual runbook: offline `session.json` edit, TCP to .2, discovery off | UDP only after validation; F1 relay if Mode B fails |
| adb | Exec `adb` as `$SUDO_USER`, never root | Swift smart-socket client (`M1.ADB_FLAKY`) |
| Menu bar privilege | `SMAppService.daemon` root helper | Legacy LaunchDaemon install (`M4.0.SIGNING_FAIL`) |

**Not pursued:**
- RNDIS: no macOS driver, and the Quest HAL rejects it.
- ECM: macOS 27 DriverKit TX stall.
- AOA: blocked by Horizon OS.
- Mac as USB device.
- A user-space NCM driver on the Mac.
- A kext or DriverKit dext.
- The Quest as tethering server.

## 3. Milestones

| M | Deliverable | Exit criteria |
|---|---|---|
| **M0-S1** | Headset session 1 (~2 h): E0–E3 + E5, run as scripts | Decision gate §4.4 resolved |
| **M1** | `questlink` CLI v0.1: `doctor/status/snapshot/mode/up/down/repair/test`, journal, `--dry-run`, PeerSniffer, RouteGuard (+ DHCP responder only if the gate says so) | V1–V6, V9 |
| **M0-S2** | E4 (sharing), E6/E6b (VD Mode A, STATIC in LOCAL) | Gate rows for sharing/sticky |
| **M2** | `share on/off`, EgressWatcher, `vd prepare`, `--sticky` (if E6b) | V7, V8, V14 |
| **M0-S3** | E10 (lock/TRM/naming/MAC-churn matrix), E11 (VPN/LNP/perf), E12 (Virtual Display regression) | Rule table in `docs/decisions.md` |
| **M3** | `watch` re-arm loop, lock gate, ApprovedStore | V10, V11, V13 |
| **M4** | Menu bar app + root daemon (M4.0 signing spike first) | V15 |
| **M5** (conditional) | Quest app "NCM Keeper" (F1 or wish) | V16 |
| **M6** (stretch) | VpnService internet over Mode A (gnirehtet fork) | not scheduled |

## 4. Milestone 0: on-device feasibility ladder (scripts, no product code)

### 4.1 How M0 is run (review fixes)

- **Scripts, not paste.** Write `scripts/m0/lib.sh` plus one file per experiment (`E0.sh` … `E12.sh`) before Session 1. Run them with `source`.
  - `lib.sh` starts with `setopt interactivecomments`.
  - Any manual line gets `setopt interactivecomments` typed first.
- **Session env file.**
  - Use a fixed `EV=$NCM/docs/evidence/S<n>-<date>`.
  - Every discovered value (`IF QMAC QW EG TOKEN`) is appended to `$EV/env`.
  - Every script starts with `source $EV/env`. This keeps multiple Terminal windows consistent.
  - Save the pf token to `$EV/pf-token`.
- **Guards.**
  - Every block using `$IF` starts with `: ${IF:?IF empty - rerun qif}`.
  - `qif` fails unless exactly one enN is found under VID 0x2833.
  - Service lookup uses `grep -F "Device: $IF)"`.
  - Before any `networksetup -setmanual`/`-setv6LinkLocal`, assert the service's device is `$IF` and that the service is not `Wi-Fi`.
- **adb.**
  - `qw(){ adb connect $QW >/dev/null 2>&1; adb -s $QW "$@"; }` is used for all Wi-Fi-transport commands, since the transport drops at reboots and at `adb kill-server`.
  - Background Quest listeners use `adb -s $Q shell -n '…' & P=$!`, with cleanup by saved PID (no `wait`/`%1`).
  - After every Quest reboot, re-run `adb tcpip 5555` + `qw`.
- **ALVR housekeeping first.** E0's first step is `./demo.sh stop --bottle <b>`, then confirm there is no `*:8082` listener. The core's `adb kill-server` on shutdown kills `$QW`.
- **Setup.** Terminal.app windows (LNP-exempt). Mac unlocked. Direct 5 Gb/s cable into a built-in port. The iPhone and other USB NICs unplugged.
- **Record `qtrm` on every run.** Treat `TRM_RelaxedPeriod`/`TRM_UnlockedPeriod` as rolling windows (likely always Yes during desk sessions). Judge approval by `HashStatusDescription`/`AuthorizationStatusDescription` before and after each composition.
- **Route-safety diff** compares only:
  - `route -n get default`;
  - `State:/Network/Global/IPv4` PrimaryService/PrimaryInterface/Router;
  - `scutil --dns` nameservers.

  `scutil --nwi` is recorded but not diffed, because enX legitimately appears there.

### 4.2 Helpers (`lib.sh`)

`qif`, `qusb` (VID/PID/serial + interface triples + drivers from `ioreg -a`), `qncm` (AppleUSBNCMData props), `qtrm`, `qnet` (the route-safety fields above), `qbulk` (Python TCP bulk test with `IP_BOUND_IF`), `qw`. Exact bodies are in the detailed draft §4.1; apply the guards above.

### 4.3 Experiments

| E | Goal | Key steps | Pass |
|---|---|---|---|
| **E0** Baseline (15 m) | Confounders + recovery channel | Stop ALVR core; back up `session.json`; Mac inventory (TRM, services, pf refs, 8082 owners, extensions). Quest getprops (`ro.hzos.build.display_name`), `svc usb getFunctions`, `dumpsys ethernet` (regex), `dumpsys connectivity` (any `Transports: USB` holder), `cmd ethernet help` (record `set-ip-configuration` syntax), `toybox nc`. Force-stop VD/Steam Link/WiVRn; `adb tcpip 5555` → `$QW` | HzOS ≥ 2.6, regex has `usb\d`, no USB request, no leftover STATIC (e.g. Steam Link 10.86.13.37/29), `cmd ethernet` present |
| **E1** Mode B enumeration (15 m) | TRM, driver, naming, auto-service | `log stream` (configd/kernel ncm/restrict) in T2; `qw shell svc usb setFunctions ncm`; click Allow if prompted; `qusb`, `qncm`, `qtrm`, `qif`, `networksetup -listnetworkserviceorder`, `system_profiler SPUSBHostDataType` | PID 0x500A/0x5018; 02/0D/00 + 0A/00/01; AppleUSBNCMControl/Data (not NCM11); named enX; adb back. Record auto-service (U4), speed |
| **E2** Gate 3 + DHCP client (10 m) | Carrier causality | tcpdump on `$IF` (67/68/icmp6/arp); `sudo ifconfig $IF up`; RUNNING + `IOControllerEnabled=Yes`; Quest `ip link show usb0` LOWER_UP; `QMAC` from `/sys/class/net/usb0/address`; `tcpdump ether src $QMAC` (proof of life); toggle down/up; `ping6 ff02::1%$IF` | Carrier follows enX; frame seen; `E2.DISCOVER_SEEN`; `usb0` GLOBAL in dumpsys |
| **E3** Static IPv4 + TCP + hold + persistence (35 m) | U1/U2/U3/U5 | `ipconfig set $IF MANUAL .1` (no router); `cmd ethernet … usb0 static .2/24`; `ping -b $IF`; `route get` = `$IF`; TCP both ways via `toybox nc` (with `shell -n`); 10-min hold loop; `qbulk` throughput; then a persistent service (guarded), replug, re-switch: enX comes up addressed with no manual command | 0% loss, TCP both ways while Wi-Fi stays the Quest default, route diff empty, address holds 10 min, persistence OK |
| **E5** wine-vr ALVR proof (30 m) | Manual runbook §6.1 | Follow §6.1 exactly | `lsof` ESTABLISHED to .2:9943/9944; `current_ip` .2; enX bytes ≈ bitrate, en0 flat; 5 min of play; network p50 ≤ adb baseline (2.7 ms) + 1 ms |
| **E4** Mac → Quest internet (25 m, S2) | NAT validation | Record the prior `wifi_always_requested` value, then set it to 1; `cmd ethernet … static .2/24 --gateway .1 --dns R`; `EG`=PrimaryInterface; `nat on $EG inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> ($EG)` into anchor `com.apple/questlink`; `pfctl -E` (save token); poll `dumpsys connectivity` for VALIDATED/default; Quest `ip route get 1.1.1.1` → usb0; browser; then UDP phase for ALVR | VALIDATED ≤ 30 s; Mac default and OrbStack unaffected; UDP 9944 on `$IF`. Teardown: `-F all` + `-X token`, restore settings |
| **E6** VD Mode A (25 m, S2) | Control experiment. **Split outcomes** | Revert `usb0` to dhcp, replug; VD Beta channel + "USB connection for apps" consent (foreground); Allow on Mac | `E6.LINK_PASS`: Mode A composition enumerates, AppleUSBNCM binds, enX UP/RUNNING with fe80, Quest fe80 answers `ping6 ff02::1%$IF`/`ndp`. `E6.VD_PASS`: desktop stream runs with Quest Wi-Fi off and enX counters growing. Only LINK_* feeds the transport decision |
| **E6b** STATIC in LOCAL (15 m, S2) | Mode A IPv4? | While VD holds Mode A: `cmd ethernet … static .2/24`; ping/TCP; reconnect VD | `STATIC_IN_LOCAL` / `STATIC_BREAKS_VD` / `NO_IPV4_IN_LOCAL` |
| **E10** Lock/TRM/naming/churn (45 m, S3, before M3) | Rules for `watch` | Pre-armed scripts started before Ctrl-Cmd-Q, with a logger loop: approvals per composition; MAC stable within one Quest boot; Quest reboot (unlocked, then locked) → new enN? `_Locked_`? `resetUsbGadget` re-names?; one controlled cache miss with a canary USB device (explicit consent) → `E10.ESCALATE_1`? | Rule table in `docs/decisions.md` |
| **E11** Interference + perf (45 m, S3) | VPN/LNP/throughput | Each extension alone (route get, ping, nc, share validation); ALVR server launched from Terminal.app vs iTerm2 vs CrossOver GUI with nehelper logging; ping p50/p99; `qbulk`/iperf3 both ways on USB 3 and USB 2; MTU 1472/1473; Mac and Quest sleep/wake | Expect 0.3–1 Gb/s, RTT < 1 ms [U] |
| **E12** Virtual Display regression (15 m, S3) | Default composition restore | Replug; `qusb` shows a Default PID with ff/8B + ff/8C; Virtual Display log shows `Client Connected on RTC` | — |
| E7–E9 | Conditional (need the M5 app) | Probe APK (LinkProperties, bandwidth, survival under immersive focus), F1 relay, Steam Link `SET_LOCAL_IP` replay [U] | — |

**R-CLEAN at the end of every session:**
1. `demo.sh stop` and verify there is no `*:8082` listener.
2. Restore `session.json.bak-ncm`.
3. `qw shell cmd ethernet … usb0 dhcp`.
4. Restore `wifi_always_requested`.
5. pf `-F all` + `-X $(cat $EV/pf-token)`.
6. `ipconfig set $IF NONE`/`NONE-V6`.
7. `adb -s $Q usb`.
8. Replug to return to the Default composition.

Never run `pfctl -d` or flush the main ruleset.

### 4.4 Decision gate

| Observed | Decision |
|---|---|
| E3 pass + E5 pass | **GO Mode B.** M1 as specified; no DHCP responder, no Quest app |
| `E3.CMD_REJECTED` + `E2.DISCOVER_SEEN` | GO Mode B with DHCP. Use Internet Sharing for M0; M1 builds the libpcap responder |
| `E3.CMD_REJECTED` + (`E2.UNTRACKED` or `E2.NO_DISCOVER`) | Run E6. If `E6.LINK_PASS` → **F1** (M5 Keeper + relay) |
| `E3.NO_INBOUND` | Run E4 early: validated → ALVR requires share (F4); otherwise try Quest Wi-Fi off; else F1 |
| `E1.NO_BIND` / persistent `E2.NO_CARRIER`, **and** `E6.LINK_FAIL` | **F5** Ethernet adapter; CLI shrinks to `doctor` |
| `E1.NO_BIND`/`E2.NO_CARRIER` but `E6.LINK_PASS` | Composition-specific problem → F1 |
| `E6.VD_FAIL` with `E6.LINK_PASS` | VD app issue only: document it, don't change transport |
| `E3.PERSIST_FAIL` / `E3.DECAY` | Per-attach `ipconfig set` / `watch` re-applies the address; recommend share |
| `E5.LNP` | Fix the launch context (Terminal.app); `AllowedEthernetLocalNetworkAddresses` + reboot as fallback |
| `E10.ESCALATE_1` | M3 hard-blocks every switch while locked |

**M0 deliverables:**
- `docs/evidence/<session>/` (becomes the M1 test fixtures);
- `docs/m0-results.md`;
- `docs/decisions.md`.

## 5. Milestone 1: `questlink` Swift CLI (`mac/`)

**Principles.**
- One binary.
  - Mutating commands run as root via `sudo` from Terminal.app.
  - `doctor`, `status`, `mode`, `snapshot` and `test` run unprivileged.
- adb is always exec'd as `$SUDO_USER` with timeouts, so port 5037 is never root-owned.
- Write-ahead journal: `/Library/Application Support/QuestLink/state.json`.
  - `repair` runs at the start of every `up`.
  - Everything is idempotent, and `--dry-run` is available.
  - Debug builds accept `QUESTLINK_FAULT=after:<stage>`.
- Hard prohibitions:
  - `pfctl -d` or main-ruleset edits;
  - touching services questlink didn't create;
  - writing NetworkInterfaces.plist;
  - any interface other than the Quest's enX;
  - switching composition while locked unless the target is approved.
- Identity is VID 0x2833 + USB serial (equal to the adb serial). enX is re-derived from IORegistry every time.

**Package.**
- SwiftPM, tools 6.0, macOS 15+. The only dependency is swift-argument-parser (Apache-2.0).
- Targets:
  - `CQuestShims`: C shims for SIOCGIFFLAGS/SIOCGIFMEDIA, PF_ROUTE RTM_GET, and libpcap from the SDK.
  - `QuestLinkCore`, with modules:
    - `USB/`, `Gate/`, `ADB/`, `Net/`, `Addr/`, `DHCP/` (conditional)
    - `NAT/` (M2), `LinkTest/`, `Doctor/`, `State/`
    - `Relay/` (F1), `Daemon/` (M4)
  - `questlink`: the executable.
- No `ALVR/` module (manual-proof decision).

**Subcommands.**

| Command | Purpose |
|---|---|
| `doctor [--json]` | Read-only S0–S16 stage walk with remedy and exit code |
| `status` | Current link status |
| `snapshot` | E0-style evidence bundle |
| `mode` | `default` / `A` / `B` |
| `up [--share] [--addr static\|dhcp] [--sticky] [--subnet] [--force-stop-holders] [--reset-usb0] [--keep-quest-wifi] [--dry-run]` | Bring the link up |
| `down [--restore-usb] [--forget]` | Tear the link down |
| `repair` | Replay pending undos |
| `test [--serve]` | ICMP via `ping -b enX`, TCP with IP_BOUND_IF, enX vs en0 counters |
| `share on/off` | M2 |
| `vd prepare` | M2 |
| `watch` | M3 |
| `relay` | F1 only |
| `daemon run/install` | M4 |

`doctor` only *reports* ALVR state as warnings in S16:
- the `*:8082` owner vs the 127.0.0.1:8082 owner (OrbStack);
- whether `client.wired` is present.

**Stage machine** (backbone of `doctor`, `up` and the menu bar):

| Stage | Checks |
|---|---|
| S0 | Mac unlocked |
| S1 | adb, exactly one Quest |
| S2 | No Mode A holder or foreign STATIC |
| S3 | NCM composition present (switch over the Wi-Fi transport) |
| S4 | TRM authorized ("Unlock + Allow") |
| S5 | AppleUSBNCM bound |
| S6 | Named (`_Locked_` → `resetUsbGadget` once → replug) |
| S7 | Our service (Manual .1, no router, v6 LL) |
| S8 | UP + RUNNING + IOControllerEnabled |
| S10 | Peer frame from QMAC (libpcap) |
| S11 | IPv4 both ends |
| S12 | RTM_GET → enX, ping/TCP bound to enX |
| S13 | Route safety |
| S14 | Share |
| S16 | Environment warnings |

Each stage has its own exit code (10–60).

**RouteGuard (review fix).**
- It snapshots PrimaryService/PrimaryInterface/Router for IPv4 and IPv6, the default route, and DNS.
- It compares the **relative order of pre-existing services only**, with questlink-owned service IDs filtered out. macOS inserts a new Ethernet-ranked service at its rank (probably 4th here), not at the end.
- Primary/default-route changes are hard failures (roll back, exit 42). DNS differences are warnings.

**Key APIs.**
- **IOKit:** `IOServiceAddMatchingNotification` on `IOUSBHostDevice` (idVendor 0x2833) and on `AppleUSBNCMData`. Name → device via `IOBSDNameMatching` plus a parent walk. Composition signature = VID + serial + interface triples.
- **SystemConfiguration:** `SCPreferencesCreate`/`Lock`, `SCNetworkServiceCreate`/`EstablishDefaultConfiguration`, IPv4 Manual without `Router`, `kSCValNetIPv6ConfigMethodLinkLocal`, `Commit`/`Apply`. `SCDynamicStore` watches Global and `Plugin:InterfaceNamer`.
- **libpcap:** PeerSniffer; the DHCP responder receives with BPF and sends with `pcap_inject` of full frames.
- **pf:** via `/sbin/pfctl` anchor + token.
- **IPv6:** fe80 always with `scope_id`, because `use_defaultzone=0`.

**Build order.**

| Task | Content |
|---|---|
| T1 | Skeleton |
| T2 | USB detection from E1 fixtures |
| T3 | Gate readers |
| T4 | adb + parsers |
| T5 | ServiceManager, dry-run first |
| T6 | IfProbe/PeerSniffer/RouteGuard/SubnetPicker |
| T7 | QuestStaticAddr + journal + repair |
| T8 | DHCP (conditional) |
| T9 | up/down orchestration |
| T10 | LinkTest |
| T11 | `doctor --json` schema |

Headset-free testing: M0 fixtures; optionally the RTL8156 NCM dongle or a Raspberry Pi configfs `ncm` gadget as stand-ins.

**Subnet.**
- Default 192.168.42.0/24 (Mac .1, Quest .2). The runtime collision check covers:
  - all local prefixes;
  - the Quest's wlan0 subnet;
  - the reserved list: 192.168.1–17, 192.168.64, OrbStack's 192.168.138/23 and 192.168.{107,117,148,155,156}, 100.64/10, 10.2.0/24, 10.86.13.32/29.
- Alternates: 192.168.231.0/24, 172.29.42.0/24.

## 6. App procedures

### 6.1 wine-vr / ALVR manual proof runbook (`docs/runbooks/alvr-wine-vr.md`; no automation)

1. Link up (`sudo questlink up`, or the E3 state). Check `ping -b $IF 192.168.42.2`.
2. `./demo.sh stop --bottle <b>`. Confirm `lsof -nP -iTCP:8082 -sTCP:LISTEN | awk '$9=="*:8082"'` prints nothing; OrbStack's 127.0.0.1 line is expected.
3. **Offline edit** of `~/Library/Application Support/OXRSys/alvr/session.json`, after a timestamped backup. Never delete the file.
   - Remove `client.wired`.
   - Clear all `manual_ips`.
   - Add `quest.ncm` with `manual_ips ["192.168.42.2"]` and `trusted` set.
   - Set `stream_protocol` to `{"variant":"Tcp"}`.
   - Set `client_discovery.enabled` to false.
   - (A Python snippet is in the detailed draft §9.1.)
4. `adb forward --list` must be empty on 9943/9944.
5. Start `./demo.sh run --bottle <b>` **from Terminal.app** (LNP-exempt), without `--wired`.
6. Launch the client by hand: `adb shell monkey -p alvr.client -c android.intent.category.LAUNCHER 1`.
7. Verify:
   - `lsof` ESTABLISHED to .2:9943/9944;
   - enX bytes grow and en0 stays flat;
   - `tcpdump tcp port 9944`;
   - optional `adb kill-server`, after which the stream should be unaffected.
8. Compare ALVR network latency with adb (2.7 ms p50) and Wi-Fi (6–7.4 ms).
9. UDP only after share validation (E4).
10. **Live API**, if ever needed mid-session: only `http://192.168.42.1:8082/api/dashboard-request` with `X-ALVR: true`, never 127.0.0.1. Re-read `session.json` afterwards, because `SetValues` errors are swallowed.
11. **Restore:**
    1. Stop the core.
    2. Restore the backup.
    3. `questlink down`.
    4. Replug.

### 6.2 Virtual Desktop (Mode A, desktop streaming)

1. `questlink vd prepare`: Mode B down, Default composition, IPv6 LinkLocal service kept.
2. Headset: VD on the Beta channel, "USB connection for apps" consent given in the foreground.
3. Mac: VD Streamer 1.34.22, which already has Local Network permission. Click Allow once for VD's composition.
4. Expect "USB 3 5,120Mbps". Pull to refresh Computers 2–3 times and pick the USB entry.

VD's request pre-empts Mode B, so `watch` stands down.

### 6.3 Meta Quest Virtual Display

- Default composition over Wi-Fi only. Run `down --restore-usb` or replug first, because Mode B drops the vendor interfaces ff/8B and ff/8C.
- Its Local Network permission reads Denied on this Mac. Tell the user before touching it.

### 6.4 Internet sharing (M2, `questlink share on`)

- The Mac service stays router-less.
- DNS R = the first non-loopback, non-link-local, non-100.64 resolver that is not routed via a utun (so Tailscale MagicDNS is excluded), else `1.1.1.1`.
- Quest: static .2/24 with gw .1 and dns R.
- pf anchor NAT on the current primary egress. EgressWatcher re-renders it when the egress changes.
- Wait up to 45 s for VALIDATED.
- `--keep-quest-wifi` keeps the adb-over-Wi-Fi recovery channel; the prior value is journaled.
- `share off` fully reverts.
- Quest → Mac sharing is out of scope.

## 7. Later milestones

- **M3 `watch`.**
  - Triggers: IOKit attach/detach, InterfaceNamer changes, unlock, wake, egress change.
  - It re-arms `setFunctions ncm` only when S0 allows it, creates and GCs services for new enN (Quest reboot means a new host MAC), and stands down when a Mode A holder exists.
- **M4 menu bar.**
  - `QuestLinkBar.app` (SwiftUI `MenuBarExtra`, user context) plus a root daemon (`SMAppService.daemon`, same core, LNP-exempt), connected by a Unix socket carrying JSON.
  - UI: stage list, mode chip, banners ("Unlock and click Allow", "Quest rebooted: replug", VPN warnings), Connect/Disconnect/Restore USB/Share toggle/Link test.
  - Opt-in admin toggles: `scutil --allow-new-interfaces`, `AllowedEthernetLocalNetworkAddresses`.
  - No ALVR buttons.
- **M5 "NCM Keeper"** (Kotlin 2D panel; `compileSdk 35`, `targetSdk 34`, `minSdk 32`; sideloaded with `adb install -r -g`).
  - `LinkActivity`: a listen-only view in Mode B; a Mode A request button, foreground only, which re-requests on `onUnavailable`; shows the interface, fe80/IPv4 and `getLinkDownstreamBandwidthKbps` (warns below 1,000,000, i.e. USB 2).
  - `KeeperService`: a connectedDevice foreground service with a Release button.
  - F1 relay: `[fe80::%usb0]:19943/19944` → `127.0.0.1:9943/9944`. It is skipped if E6b gives IPv4.
  - Experimental `SET_LOCAL_IP` flag [U].
  - GPL references (WiVRn, moonlight PR #31) are read-only and never copied.
- **M6.** VpnService internet over Mode A (gnirehtet fork) with `excludeRoute` for the link subnets and `addDisallowedApplication` for streaming apps.

## 8. Reuse and licenses

| Component | Use |
|---|---|
| In-box: AppleUSBNCM, SystemConfiguration, IOKit, Network.framework, libpcap, pf | Runtime; nothing to install |
| swift-argument-parser (Apache-2.0) | The only Swift dependency |
| UbootVRC/Wired-Steam-Link-VR `QuestNcmLink.ps1` (MIT) | DHCP option set and Mode B lessons. Avoid the Siken9013 fork |
| apple configd/bootp sources (APSL) | Behaviour reference only |
| ya-webadb/dadb | adb protocol, only if needed |
| gnirehtet (Apache-2.0) | M6 |
| ALVR (MIT) | Session schema reference |

## 9. Risks (top)

- **Quest 3 `usb0` takes no IPv4** → gate to DHCP, F1 or F5.
- **Mode A holders or a Steam Link STATIC leftover** → S2 detection.
- **Silent Gate 3 failure** → require RUNNING + IOControllerEnabled + a pcap frame.
- **Unapproved composition while locked** (adb loss; possible escalation) → lock gate, E10.
- **New enN per Quest reboot** → never cache enN.
- **OrbStack on 127.0.0.1:8082 and the `client.wired` race** → runbook §6.1.
- **LNP for Wine** → launch from Terminal.app.
- **pf mistakes** → anchor + token only.
- **VPN interference** → IP_BOUND_IF tests + E11 matrix.
- **Firmware drift** → `doctor --json` records builds; re-run E1–E3 after updates.
- **Latency gain over adb is small (~1–2 ms)**. The real value is robustness, UDP, no adb dependency, and other apps.

## 10. Verification

| ID | Test | Expected |
|---|---|---|
| V1 | `cd mac && swift build -c release && swift test` | Parser tests on M0 fixtures, pf render golden, SubnetPicker rejects OrbStack subnets, RouteGuard relative-order test, DHCP golden bytes (if built) |
| V2 | `questlink doctor` with no Quest | Exit 20; warns that OrbStack owns 127.0.0.1:8082; service list unchanged; port 5037 not root-owned |
| V3 | Plug in → `sudo questlink up` | `LINK UP mode=B if=enN mac=192.168.42.1 quest=192.168.42.2` in under 30 s; `ifconfig enN` UP,RUNNING + fe80; Quest `usb0` .2/24 |
| V4 | Snapshot before/after | Default route, Global primary and DNS unchanged; pre-existing services keep relative order (ours inserted at rank); `route get .2` → enN; aliased 192.168.42.9 on lo0 makes `up` refuse |
| V5 | `questlink test` | 0% loss, p50 < 1 ms, ≥ 300 Mbit/s each way on USB 3, bytes on enN not en0 |
| V6 | `up` ×2, `down --restore-usb` ×2 | Idempotent; `usb0` back to dhcp; Default PID with ff/8B + ff/8C after replug |
| V7/V8 | `share on --keep-quest-wifi` / `share off` | Anchor rule present; `usb0` VALIDATED and default in ≤ 45 s; Quest browser works; Mac default route and OrbStack unaffected / everything reverted |
| V9 | `QUESTLINK_FAULT=after:S14 up --share`, then `repair` | Clean state |
| V10/V11 | Lock policy; Quest reboot under `watch` | No switch while locked for unapproved compositions; new enN handled; old service GC'd |
| V12 | Runbook §6.1 by hand | ALVR over .2 via TCP, 10 min of play, survives `adb kill-server`, restore gives an empty JSON diff |
| V13 | VD running while Mode B up; extension matrix | S2 conflict names VD; named warnings, no silent success over a wrong route |
| V14 | §6.2 and §6.3 | VD streams over enN with Quest Wi-Fi off; Virtual Display reconnects after restore |
| V15 | Menu bar | Stages match `doctor --json`; daemon survives app quit |
| V16 | M5 app (if built) | Shows fe80, bandwidth and capabilities; F1 stream runs via relay |

**Execution order:**
1. Write `scripts/m0/*`.
2. M0-S1 → gate.
3. M1.
4. M0-S2.
5. M2.
6. M0-S3.
7. M3.
8. M4.
9. M5/M6 only on their triggers.

**Estimate:** M0 about 5.5 headset-hours; M1 3–4 days; M2 1–1.5 days; M3 2 days; M4 3–4 days.
