# Mac-Quest-NCM

A direct **USB network link between a Meta Quest and a Mac**. It uses the CDC-NCM class driver that
already ships with macOS, so there is no kext, no DriverKit extension and no app on the Quest.

```
Mac 192.168.42.1  ◀──── USB-C cable (CDC-NCM) ────▶  Quest 192.168.42.2
```

Once the link is up, anything that speaks IP can use the cable:
- PC-VR streamers ([ALVR](https://github.com/alvr-org/ALVR) /
  [wine-vr](https://github.com/dingyifei/wine-vr) + [oxrsys](https://github.com/dingyifei/oxrsys));
- desktop streaming;
- `adb` over TCP, iperf, SSH and so on.

Optionally, the Mac can also share its internet with the Quest over the same cable.

It comes as a menu bar app (**Mac-Quest-NCM.app**) and a CLI (**`mqncm`**) with the same features.

**Measured** on a Quest 3 (Horizon OS 2.7) and a MacBook Pro M3 Max (macOS 27), over a **USB 2** cable:

| Metric | Result |
|---|---|
| Latency | 0.84 ms average RTT idle, 1.6 ms while carrying 150 Mbit/s |
| Throughput | ~315 Mbit/s Mac → Quest, ~335 Mbit/s Quest → Mac |

A USB 3 cable raises the ceiling.

## Install

```sh
brew install --cask dingyifei/tap/mac-quest-ncm   # app + mqncm CLI (signed and notarized)
brew install dingyifei/tap/mqncm                  # CLI only
brew install --cask android-platform-tools        # adb, if you don't have it
```

Or download the zip from [Releases](https://github.com/dingyifei/mac-quest-ncm/releases).

### Requirements

- macOS 15 or later (tested on macOS 27).
- A Quest with **developer mode** on, and USB debugging authorized for this Mac (accept the prompt in the headset once).
- A USB-C **data** cable. Use USB 3 for full speed.

## Use

**App:** click the cable icon in the menu bar.
- **Start NCM** brings the link up.
- The dropdown and window show link state, USB link speed and live traffic in each direction.
- Other controls: **Share internet**, **Speed test**, **Restore USB mode**, **Copy Quest IP**.

**CLI:**

```sh
mqncm up                    # switch the Quest to NCM and bring the link up (~5 s)
mqncm status [--json]       # both ends: USB mode and speed, interface, addresses, Quest network state
mqncm monitor [--json]      # live traffic rates on the link
mqncm test [--json]         # latency + throughput over the cable
sudo mqncm share on|off     # share this Mac's internet with the Quest (NAT)
mqncm share status
mqncm restore-usb           # Quest back to its default USB mode (~2 s; or just replug)
mqncm down                  # Quest usb0 back to DHCP
```

**The first time**, macOS asks **"Allow accessory to connect?"** for the Quest's new USB mode.
- Click **Allow** while the Mac is unlocked. `mqncm up` waits for you.
- After that, re-arming the link after a replug is a single `mqncm up`.

### Use it from other apps

| App | How |
|---|---|
| **ALVR / wine-vr** | Pin the client to `192.168.42.2`. See [docs/alvr-wine-vr.md](docs/alvr-wine-vr.md) |
| **Virtual Desktop** | Has its own USB mode (Meta's app API; see below). Use that instead, not this link at the same time |
| **Anything else** | Connect the Mac to `192.168.42.2`, or the Quest to `192.168.42.1` |

Apps on the Quest only send their *own* traffic over the cable while it is the Quest's default
network. That is the case with `share on`, or with the Quest's Wi‑Fi turned off. Connections the
Mac opens to the Quest always work.

## How it works

The Quest's Android stack can expose a standard **CDC-NCM** USB function (`svc usb setFunctions ncm`).
macOS's in-box `AppleUSBNCM` driver binds it as an ordinary Ethernet interface (`enN`). The driver
was never the problem. What tripped up earlier attempts ("macOS weirdness") is everything around it:

| # | Gate | What happens | What Mac-Quest-NCM does |
|---|---|---|---|
| 1 | Accessory security | Apple-silicon laptops block a new USB composition until you click Allow | Detects the block and waits for your approval |
| 2 | Interface naming | A new interface that appears while the Mac is locked is ignored | Tells you to unlock and replug |
| 3 | Link carrier | The Quest only gets carrier once the Mac brings `enN` up | macOS's auto-created service does this; checked |
| 4 | Addressing | Both ends are DHCP clients, so the Mac falls back to 169.254 and the Quest gets nothing | Static `192.168.42.1` (Mac, **no router**) and `192.168.42.2` (Quest, via `cmd ethernet`) |
| 5 | Routing | The Quest prefers Wi‑Fi for its own traffic | Optional NAT so the cable validates and becomes the Quest's default network |
| 6 | App policy | Local Network privacy, VPN/filter extensions | Documented below |

Horizon OS also has an **official app API** for USB networking (`ConnectivityManager` with
`TRANSPORT_USB`, Horizon OS 2.5+). Virtual Desktop and Steam Link use it.
- That mode is IPv6 link-local only, with no internet, and is usable only by the app that requests it.
- It **pre-empts** this mode. `mqncm up` refuses while an app holds it, unless you pass `--force-stop-holders`.

Research notes and raw results are in [docs/research/](docs/research/).

## Safety

- **The Mac's default route never moves.** The Mac-side network service has no router. `up` checks that the Mac's primary interface and router are unchanged afterwards.
- **NAT is confined to its own pf anchor** (`com.apple/mqncm`) and enabled with a pf reference token. The main ruleset is never touched, and pf is never globally disabled.
- **adb never runs as root.** When `mqncm` runs under `sudo`, adb still runs as you, so there's no root adb server and no new RSA prompt.
- **The app asks for your admin password only for `share on/off`.** It uses the standard macOS prompt to run the bundled `mqncm`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `adb sees … as 'unauthorized'` | Accept USB debugging in the headset |
| "macOS is blocking this USB mode" | Unlock the Mac and click **Allow**. If no prompt appears, replug |
| NCM present but no interface | The Mac was locked when the Quest attached. Unlock and replug |
| Ping works from Terminal but an app can't connect | macOS **Local Network** privacy: allow the app in System Settings → Privacy & Security → Local Network |
| Sharing on, but the Quest says "no internet" | A VPN kill switch or content filter (ProtonVPN, TripMode, Cisco…) may block forwarded traffic. Test with it off |
| Throughput ~330 Mbit/s max | You're on USB 2 (`mqncm status` shows 480 Mb/s). Use a USB 3 data cable and port |
| Quest Link / Virtual Display over USB stopped | Run `mqncm restore-usb` or replug: NCM mode replaces Meta's own USB functions |

## Revert and uninstall

1. Stop sharing: `sudo mqncm share off`.
2. Return the Quest to DHCP: `mqncm down`.
3. `mqncm restore-usb`, or replug the cable, to return the Quest to its default USB mode.
4. Optionally, remove the Mac's network service named after the Quest: System Settings → Network.
5. `brew uninstall --zap --cask mac-quest-ncm` removes the app and `/Library/Application Support/Mac-Quest-NCM`.

## Limitations

- **Developer mode and adb are required** to switch the Quest's USB mode.
- **One mode at a time.** An app that holds Meta's official USB network (e.g. Virtual Desktop's USB mode) and this mode exclude each other.
- **Quest Wi‑Fi while sharing:** once the cable is the Quest's validated default, Android stops routing over Wi‑Fi, so adb-over-Wi‑Fi to its Wi‑Fi address stops working. Use `adb connect 192.168.42.2:5555` instead.
- **Tested hardware:** Quest 3 with Horizon OS 2.7 only. Reports from other headsets and versions are welcome.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Not affiliated with Meta or Apple.
