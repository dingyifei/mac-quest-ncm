# M0 results

## Session 1 — 2026-10-05 (Quest 3 HzOS 2.7.0 / vros 207, Android 14; macOS 27.0 26A428)

| Question | Result |
|---|---|
| Quest default composition | 2833:5013, ff/8A ff/8B ff/8C + adb ff/42 |
| `svc usb setFunctions ncm` (via adb-over-Wi-Fi) | OK → 2833:**5018** (persist.ovr.usb.xrsp_enabled=1): ff/8A ff/8B ff/8C, **02/0D/00 + 0A/00/01**, adb ff/42 |
| Gate 1 TRM | **Hit**: new composition `TRM_TransportRestricted=Yes/Unauthorized`, no data, USB adb gone. Clicking Allow on the Mac unblocked it |
| Driver | **AppleUSBNCMData (NCM 1.0)** bound, NTB16, In/Out 16384, DatagramSizeMax 1514, IOLinkStatus 3, IOControllerEnabled Yes. No driver work needed |
| Gate 2 naming | Named `en16` immediately (Mac unlocked) |
| Service auto-creation (U4) | **Yes**: SCMonitor silently created service "Quest 3" (IPv4 DHCP + IPv6 Automatic), inserted 4th, below Wi-Fi |
| Gate 3 carrier | en16 UP,RUNNING, status active; Quest usb0 UP,LOWER_UP with no manual step (auto-service raised it) |
| Quest Ethernet (U1) | EthernetTracker tracks usb0 as ETHERNET/INTERNET with an IpClient (DHCP client), GLOBAL mode. Regex `((eth\d)|(usb\d))` |
| Gate 4 | Mac got 169.254.x only (two DHCP clients). IPv6 fe80 present both ends, but **unreachable until usb0 is provisioned** (no networkAgent → no Quest routing) |
| `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24` | **Works** from adb shell; networkAgent created (Ethernet CONNECTED). Persists (written to file) — revert with `… usb0 dhcp` |
| Mac addressing | `networksetup -setmanual "Quest 3" 192.168.42.1 255.255.255.0` worked **without sudo**; Router (null) |
| Route safety | Default route stays en0; `route get 192.168.42.2` → en16 |
| Mac→Quest ICMP | 0% loss; 500×10 ms: min/avg 0.53/0.81 ms |
| IPv6 LL after provisioning | works |
| Mac-dialled TCP (U2) | **Works both directions** while Quest default = Wi-Fi |
| Quest-initiated | Goes via wlan0 (table 1015) — as predicted (gate 5) |
| Throughput (toybox nc, Python) | 317 Mbit/s Mac→Quest, 337 Mbit/s Quest→Mac — **link negotiated at 480 Mb/s (USB 2)**: cable/port is USB 2 |

Open: E3 10-min hold, E3d persistence across replug, E4 sharing (needs sudo for pf), E5 ALVR, E6 VD, E10 lock matrix, USB 3 cable retest.

### E4 — Mac→Quest internet (2026-10-05)
| Item | Result |
|---|---|
| Mac NAT | `scripts/m0/share-on.sh` (sudo): anchor `com.apple/questlink`, `nat on en0 … -> (en0)`, pf token-enabled; forwarding already 1 |
| Quest | `cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 --gateway 192.168.42.1 --dns 1.1.1.1` |
| Validation | usb0 Ethernet **VALIDATED and default network within 10 s** |
| Quest internet | `ip route get 1.1.1.1` → usb0; ping 1.1.1.1 ~22 ms; DNS works |
| Mac default route | unchanged (en0) |
| Quest Wi-Fi with `wifi_always_requested=1` | stays associated (L3Connected, <quest-wifi-ip>) but its network agent is torn down after ~20 s → adb-over-Wi-Fi goes offline. Use `adb connect 192.168.42.2:5555` as recovery instead |
| Quest browser | Loads websites; **also with Quest Wi-Fi turned off** (user-confirmed). Counters: usb0 ~334 MB rx vs wlan0 ~85 KB |

### Speed test over USB 2.0 (480 Mb/s link), 2026-10-05
| Test | Result |
|---|---|
| Mac→Quest, 1 TCP stream (15 s) | 317 Mbit/s |
| Mac→Quest, 4 streams | 318 Mbit/s total (link-bound, not CPU-bound) |
| Quest→Mac, 1 / 4 streams | 335 / 335 Mbit/s |
| Both directions at once | 186 + 152 = 338 Mbit/s (USB 2 is half-duplex: shared) |
| Idle RTT (1000 pings @10 ms) | avg 0.84 ms, min 0.48 ms |
| RTT at 150 Mbit/s steady load (ALVR-like) | avg 1.6 ms |
| RTT with link saturated both ways | avg 15 ms (queueing; avoid >~300 Mbit/s total) |
Ceiling ≈ 335 Mbit/s ≈ 70% of USB 2 raw — typical for NCM over USB 2 bulk. USB 3 cable retest pending.

### Replug persistence (E3d), 2026-10-05
Replug → Default composition 2833:5013, en16 gone. Then `svc usb setFunctions ncm`:
en16 back in 2 s (same name — host MAC stable within one Quest boot), **no new TRM prompt** (approved composition cached), Mac service Manual 192.168.42.1 re-applied automatically (UP,RUNNING) at 4 s, ping at 5 s, Quest static (+gateway) persisted, NAT still loaded → Ethernet VALIDATED + default again. Mac default route en0. ⇒ After first setup, re-arming = one adb command.

### questlink v0.1 (2026-10-05)
`questlink up` from the default composition after a replug: switch → re-enumerate → en16 → service check → address → reach → route check, **4.8 s, rc 0**. `test`: 0.93 ms avg, 314/336 Mbit/s. Fixed during bring-up: adb exits non-zero when the switch tears down the USB transport (output `setCurrentFunctions` = applied); ifconfig lines are tab-prefixed.
