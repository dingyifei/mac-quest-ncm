#!/bin/zsh
# Writes the cask and formula for <version> into a homebrew-tap checkout.
#   scripts/render-tap.sh <version> <release-dir> <tap-dir>
set -euo pipefail
ROOT="${0:A:h}/.."
V=$1; REL=$2; TAP=$3
APP_SHA=$(shasum -a 256 "$REL/Mac-Quest-NCM-$V.zip" | cut -d' ' -f1)
CLI_SHA=$(shasum -a 256 "$REL/mqncm-$V-macos.zip" | cut -d' ' -f1)
mkdir -p "$TAP/Casks" "$TAP/Formula"
sed -e "s/@VERSION@/$V/g" -e "s/@SHA256@/$APP_SHA/g" "$ROOT/packaging/homebrew/Casks/mac-quest-ncm.rb" > "$TAP/Casks/mac-quest-ncm.rb"
sed -e "s/@VERSION@/$V/g" -e "s/@SHA256@/$CLI_SHA/g" "$ROOT/packaging/homebrew/Formula/mqncm.rb" > "$TAP/Formula/mqncm.rb"
[[ -f "$TAP/README.md" ]] || cp "$ROOT/packaging/homebrew/README.md" "$TAP/README.md"
mkdir -p "$TAP/.github/workflows"
cp "$ROOT/packaging/homebrew/.github/workflows/tap.yml" "$TAP/.github/workflows/tap.yml"
print "rendered mac-quest-ncm $V into $TAP"
