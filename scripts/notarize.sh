#!/bin/zsh
# Notarizes and staples dist/ (from bundle-app.sh --sign …) into release/ with SHA256SUMS.
#   scripts/notarize.sh <version> --key notary.p8 --key-id KEYID --issuer ISSUER   # CI (App Store Connect API key)
#   scripts/notarize.sh <version> --profile mqncm-notary                           # local (notarytool store-credentials)
set -euo pipefail
cd "${0:A:h}/.."
V=$1; shift
AUTH=()
while (( $# )); do
  case $1 in
    --key) AUTH+=(--key "$2"); shift 2 ;;
    --key-id) AUTH+=(--key-id "$2"); shift 2 ;;
    --issuer) AUTH+=(--issuer "$2"); shift 2 ;;
    --profile) AUTH+=(--keychain-profile "$2"); shift 2 ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
done
(( ${#AUTH} )) || { print -u2 "need --key/--key-id/--issuer or --profile"; exit 2; }

rm -rf release && mkdir release
APPZIP=release/Mac-Quest-NCM-$V.zip
CLIZIP=release/mqncm-$V-macos.zip

ditto -c -k --keepParent dist/Mac-Quest-NCM.app $APPZIP
xcrun notarytool submit $APPZIP $AUTH --wait
xcrun stapler staple dist/Mac-Quest-NCM.app
rm $APPZIP && ditto -c -k --keepParent dist/Mac-Quest-NCM.app $APPZIP   # re-zip with the ticket stapled

# A bare Mach-O can't be stapled; Gatekeeper checks its notarization online on first run.
(cd dist && ditto -c -k mqncm ../$CLIZIP)
xcrun notarytool submit $CLIZIP $AUTH --wait

(cd release && shasum -a 256 *.zip > SHA256SUMS)
spctl -a -vv -t exec dist/Mac-Quest-NCM.app
cat release/SHA256SUMS
