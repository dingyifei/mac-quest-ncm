#!/bin/zsh
# Builds a universal Mac-Quest-NCM.app (with the mqncm CLI embedded) into dist/.
#
#   scripts/bundle-app.sh                     # ad-hoc signed (local testing / CI)
#   scripts/bundle-app.sh --sign "Developer ID Application: Name (TEAMID)"
#   scripts/bundle-app.sh --native            # host arch only (faster local builds)
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="-"
ARCHS=(--arch arm64 --arch x86_64)
while (( $# )); do
  case $1 in
    --sign) IDENTITY=$2; shift 2 ;;
    --native) ARCHS=(); shift ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
done

VERSION=$(sed -nE 's/.*string = "([^"]+)".*/\1/p' Sources/MQNCMCore/Version.swift)
APP=dist/Mac-Quest-NCM.app

swift build -c release $ARCHS --product mqncm
swift build -c release $ARCHS --product MacQuestNCMApp
BIN=$(swift build -c release $ARCHS --show-bin-path)

rm -rf dist && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/MacQuestNCMApp $APP/Contents/MacOS/Mac-Quest-NCM
cp $BIN/mqncm $APP/Contents/Resources/mqncm
cp $BIN/mqncm dist/mqncm
cp assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mac-Quest-NCM</string>
  <key>CFBundleDisplayName</key><string>Mac-Quest-NCM</string>
  <key>CFBundleIdentifier</key><string>com.dingyifei.MacQuestNCM</string>
  <key>CFBundleExecutable</key><string>Mac-Quest-NCM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Mac-Quest-NCM pings and speed-tests the Quest over the USB network link (192.168.42.0/24).</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yifei Ding. MIT License.</string>
</dict>
</plist>
EOF

# Inside-out signing: embedded CLI first, then the app. Hardened runtime is required for notarization.
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
[[ $IDENTITY != "-" ]] && SIGN+=(--timestamp)
$SIGN dist/mqncm
$SIGN $APP/Contents/Resources/mqncm
$SIGN $APP
codesign --verify --strict --verbose=2 $APP
print "built $APP ($VERSION, signed with: $IDENTITY)"
