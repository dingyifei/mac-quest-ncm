# Releasing (signed and notarized)

Distribution outside the Mac App Store needs:
- a **Developer ID Application** certificate (paid Apple Developer Program);
- **notarization**.

An "Apple Development" certificate isn't enough.

## One-time setup

1. **Developer ID certificate.**
   1. Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority* → save the CSR to disk.
   2. <https://developer.apple.com/account/resources/certificates> → **+** → **Developer ID Application** (G2 Sub-CA) → upload the CSR → download → double-click to install.
   3. Check it: `security find-identity -v -p codesigning` lists `Developer ID Application: Yifei Ding (TEAMID)`.
   4. Export it with its private key as `devid.p12`: Keychain Access → My Certificates → right-click → Export, and set a password.
2. **Notary API key.** App Store Connect → Users and Access → Integrations → **Team Keys** → **+**, role *Developer*. Download `AuthKey_XXXX.p8` (you can only download it once) and note the **Key ID** and **Issuer ID**.
3. **Local notary profile**, for `scripts/release-local.sh`:
   ```sh
   xcrun notarytool store-credentials mqncm-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
   ```
4. **GitHub secrets**, for the release workflow:
   ```sh
   R=dingyifei/mac-quest-ncm
   base64 -i devid.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R $R
   gh secret set DEVELOPER_ID_P12_PASSWORD -R $R          # the export password
   gh secret set KEYCHAIN_PASSWORD -R $R -b "$(openssl rand -hex 16)"
   base64 -i AuthKey_XXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 -R $R
   gh secret set NOTARY_KEY_ID -R $R -b XXXX
   gh secret set NOTARY_ISSUER_ID -R $R -b <issuer-uuid>
   gh secret set TAP_GITHUB_TOKEN -R $R    # fine-grained PAT: dingyifei/homebrew-tap, Contents read+write
   ```
   Then delete `devid.p12` and the `.p8` from disk, or keep them in a password manager.

## Each release

1. Bump `Sources/MQNCMCore/Version.swift` and add a `## x.y.z` section to `CHANGELOG.md`.
2. Optional dry run: Actions → **Release** → *Run workflow* with `dry_run` checked. The signed and notarized zips appear as a workflow artifact.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`. The workflow then signs, notarizes and staples, creates the GitHub release, and updates `dingyifei/homebrew-tap`.
4. Check it:
   ```sh
   brew update && brew install --cask dingyifei/tap/mac-quest-ncm
   spctl -a -vv -t exec /Applications/Mac-Quest-NCM.app   # "source=Notarized Developer ID"
   mqncm --version
   ```

Without CI secrets you can release locally instead: `scripts/release-local.sh --publish`.
