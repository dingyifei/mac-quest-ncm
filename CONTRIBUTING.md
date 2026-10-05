# Contributing

Bug reports with real-device results are the most useful contribution. Please include:
- the output of `mqncm status --json`;
- your macOS version, headset model and Horizon OS version (`adb shell getprop ro.hzos.build.display_name`);
- whether you're on a USB 2 or USB 3 cable.

Development:

```sh
swift build && swift test
.build/debug/mqncm status
scripts/bundle-app.sh --native && open dist/Mac-Quest-NCM.app
```

All link logic lives in `Sources/MQNCMCore`, and the CLI and the app are thin front-ends over it, so
keep new features in the core and expose them in both.

Never commit raw device captures. They contain serial numbers and MAC addresses; `docs/evidence/` is gitignored.
