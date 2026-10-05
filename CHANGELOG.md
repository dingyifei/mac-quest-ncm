# Changelog

## Unreleased

- App: no longer slows the game it monitors. Measured: ~11% CPU → 1.6% with the window visible, 0.13% when hidden; while streaming wine-vr, the game's Mac frame time had gone from 13.7 ms with the app quit to 28.9 ms with it open (#1).
  - Traffic chart and rate labels update only while the window or menu is visible.
  - Visibility tracking follows the window's occlusion state, so a covered, minimised or closed window counts as hidden.
  - 1 Hz traffic updates redraw only the chart, not the whole window; status updates only redraw when something changed; chart animations are off.
- Core: interface and route state are read natively (getifaddrs, SCDynamicStore) instead of spawning ifconfig/scutil. The Quest's state is read with one `dumpsys connectivity` per refresh instead of two, and polled every 10–60 s instead of 6 s.
- App: reopening the app brings back a minimised or closed window.
- `mqncm up` while internet sharing is active keeps the Quest's gateway and DNS. Before, the Quest silently lost internet while the Mac still reported sharing on.
- `mqncm restore-usb` verified on hardware (back to the default USB mode in ~2 s); docs and `down` now point to it instead of a replug.

## 0.1.0 — 2026-10-05

- First release:
  - `mqncm` CLI: `up`, `down`, `status [--json]`, `monitor [--json]`, `test [--json]`, `share on|off|status`, `restore-usb`.
  - Mac-Quest-NCM.app, a menu bar app plus window:
    - live USB link speed and traffic chart, and both IPs shown up front;
    - Start/Stop NCM, internet sharing (admin prompt), speed test and USB-mode restore;
    - banners for the Mac accessory prompt and the in-headset USB debugging approval, and an event log.
- Signed with Developer ID and notarized; universal (Apple silicon + Intel).
- Verified on Quest 3 (Horizon OS 2.7.0) with macOS 27.0.
