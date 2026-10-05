#!/bin/zsh
# Local signed + notarized release, for when CI secrets aren't set up.
# One-time: xcrun notarytool store-credentials mqncm-notary --key <p8> --key-id <id> --issuer <issuer>
#   scripts/release-local.sh            # build, sign, notarize into release/
#   scripts/release-local.sh --publish  # also create the GitHub release and update ../homebrew-tap (then push it)
set -euo pipefail
cd "${0:A:h}/.."
V=$(sed -nE 's/.*string = "([^"]+)".*/\1/p' Sources/MQNCMCore/Version.swift)
IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { print -u2 "no 'Developer ID Application' identity in your keychain (see docs/RELEASING.md)"; exit 1; }
scripts/bundle-app.sh --sign "$IDENTITY"
scripts/notarize.sh "$V" --profile mqncm-notary
if [[ ${1:-} == --publish ]]; then
  gh release create "v$V" release/* --title "Mac-Quest-NCM $V" --notes-file <(sed -n "/^## $V/,/^## /p" CHANGELOG.md | sed '$d')
  [[ -d ../homebrew-tap ]] || gh repo clone dingyifei/homebrew-tap ../homebrew-tap
  scripts/render-tap.sh "$V" release ../homebrew-tap
  print "review and push ../homebrew-tap"
fi
