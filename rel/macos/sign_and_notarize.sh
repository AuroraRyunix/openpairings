#!/bin/sh
# Developer ID signing and notarisation for OpenPairings.app.
#
#   rel/macos/sign_and_notarize.sh <path to OpenPairings.app>
#
# NOT USED YET: there is no Apple Developer account. The workflow runs this
# only when the secrets below exist, and skips it otherwise - the app then
# ships ad-hoc signed by build_app.sh, which macOS opens after the arbiter
# says so once (docs/macos.md). Adding the account is adding these five
# repository secrets; nothing in the workflow changes.
#
#   APPLE_CERTIFICATE_P12_BASE64   the "Developer ID Application" certificate
#                                  and its private key, exported as .p12, base64
#   APPLE_CERTIFICATE_PASSWORD     the .p12's password
#   APPLE_TEAM_ID                  the ten-character team id
#   APPLE_ID                       the Apple ID that notarises
#   APPLE_APP_PASSWORD             an app-specific password for that Apple ID
#
# What it does: a throwaway keychain with the certificate in it; every
# Mach-O file signed from the inside out with the hardened runtime and the
# BEAM's entitlements (entitlements.plist says which and why); the bundle
# signed last; the bundle sent to Apple's notary service and waited for; the
# ticket stapled to the bundle, so that a Mac with no network at the venue
# still opens it without a question. Then Gatekeeper is asked, here, whether
# it agrees - before anyone downloads it.

set -eu

app=${1:?usage: sign_and_notarize.sh <path to OpenPairings.app>}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

for name in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_ID APPLE_APP_PASSWORD; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || {
    echo "::error::$name is not set" >&2
    exit 1
  }
done

work=$(mktemp -d)
keychain="$work/signing.keychain-db"
keychain_password=$(openssl rand -hex 24)

cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode >"$work/cert.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/cert.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
# The search list gets this keychain added, not replaced: codesign looks
# there, and the login keychain stays where it was.
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity=$(security find-identity -v -p codesigning "$keychain" |
  awk -F'"' '/Developer ID Application/ { print $2; exit }')
[ -n "$identity" ] || {
  echo "::error::no 'Developer ID Application' identity in the certificate" >&2
  exit 1
}
echo "Signing as: $identity"

sign() {
  codesign --force --timestamp --options runtime \
    --entitlements "$here/entitlements.plist" --sign "$identity" "$1"
}

# Inside out: the innermost code first, the bundle last, so that the
# bundle's seal covers signatures that will not change afterwards. Shell
# scripts are not Mach-O; the bundle's seal covers them as resources.
find "$app/Contents/Resources" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 |
  while IFS= read -r binary; do
    sign "$binary"
  done
sign "$app"
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$work/notarise.zip"
# --wait returns when Apple has decided, and a refusal is a decision: the
# status is what says whether it was a yes.
result=$(xcrun notarytool submit "$work/notarise.zip" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m --output-format json)
echo "$result"
status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
if [ "$status" != "Accepted" ]; then
  id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
  echo "::error::notarisation said $status" >&2
  xcrun notarytool log "$id" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" || true
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"

spctl --assess --type execute --verbose=2 "$app"
echo "Signed, notarised and stapled: $app"
