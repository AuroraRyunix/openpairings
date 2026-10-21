#!/bin/sh
# Developer ID signing and notarisation for OpenPairings.app.
#
#   rel/macos/sign_and_notarize.sh <path to OpenPairings.app>
#
# The workflow runs this only when the secrets below exist (an organisation
# secret in teapot-chess; a fork has none) and skips it otherwise - the app
# then ships ad-hoc signed by build_app.sh, which macOS opens after the arbiter
# says so once (docs/macos.md).
#
#   MACOS_CERT_P12        the "Developer ID Application" certificate and its
#                         private key, exported as .p12, base64
#   MACOS_CERT_PASSWORD   the .p12's password
#   APPLE_TEAM_ID         the ten-character team id
#   ASC_KEY_ID            App Store Connect API key id
#   ASC_ISSUER_ID         App Store Connect API issuer id
#   ASC_KEY_P8            the API key's .p8 file, base64
#
# The notary service is asked with the API key, not with an Apple ID and an
# app-specific password: a key can be revoked without touching an account.
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

for name in MACOS_CERT_P12 MACOS_CERT_PASSWORD APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || {
    echo "::error::$name is not set" >&2
    exit 1
  }
done

work=$(mktemp -d)
# A fixed place, so that the workflow's `if: always()` step can delete the
# keychain even when this script died before its own trap ran.
keychain="${RUNNER_TEMP:-$work}/signing.keychain-db"
keychain_password=$(openssl rand -hex 24)

cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

printf '%s' "$MACOS_CERT_P12" | base64 --decode >"$work/cert.p12"
printf '%s' "$ASC_KEY_P8" | base64 --decode >"$work/asc.p8"
# Word-split on purpose below: mktemp paths have no spaces.
notary_auth="--key $work/asc.p8 --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID"
# Ask OpenSSL first: Apple's importer says "wrong password?" for any reason
# at all, and a fingerprint of the file tells which certificate CI was given.
if ! openssl pkcs12 -in "$work/cert.p12" -passin env:MACOS_CERT_PASSWORD -noout 2>"$work/openssl.err"; then
  echo "::error::MACOS_CERT_PASSWORD does not open MACOS_CERT_P12 (p12 sha256 $(shasum -a 256 "$work/cert.p12" | cut -c1-16))" >&2
  cat "$work/openssl.err" >&2
  exit 1
fi
echo "p12 opens; sha256 $(shasum -a 256 "$work/cert.p12" | cut -c1-16)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/cert.p12" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
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
# scripts (launcher.sh among them) are not Mach-O; the bundle's seal covers
# them as resources. The app's own executable, Contents/MacOS/<name> - the
# compiled Launcher.swift - is signed by the last `sign`, the one on the
# bundle, with the same hardened runtime and entitlements: codesign signs a
# bundle's main executable as part of signing the bundle.
# Contents/Frameworks exists only in the Intel build, where the Swift runtime
# is copied in for old macOS; Apple signed those dylibs, the notary wants ours.
inner="$app/Contents/Resources"
[ -d "$app/Contents/Frameworks" ] && inner="$inner $app/Contents/Frameworks"
# Unquoted on purpose: two directories, and the build path has no spaces.
find $inner -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 |
  while IFS= read -r binary; do
    sign "$binary"
  done
sign "$app"
codesign --verify --deep --strict --verbose=2 "$app"
# Notarisation refuses an executable without the hardened runtime; asking
# here names the culprit instead of a notary log.
main=$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")
codesign --display --verbose=2 "$app/Contents/MacOS/$main" 2>&1 | grep -q 'flags=.*runtime' || {
  echo "::error::Contents/MacOS/$main is not signed with the hardened runtime" >&2
  exit 1
}

ditto -c -k --keepParent "$app" "$work/notarise.zip"
# --wait returns when Apple has decided, and a refusal is a decision: the
# status is what says whether it was a yes.
result=$(xcrun notarytool submit "$work/notarise.zip" \
  $notary_auth \
  --wait --timeout 30m --output-format json)
echo "$result"
status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
if [ "$status" != "Accepted" ]; then
  id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
  echo "::error::notarisation said $status" >&2
  xcrun notarytool log "$id" \
    $notary_auth || true
  exit 1
fi
# "Accepted" and "ticket published" are two different moments at Apple; the
# stapler asks for the ticket and gets error 68 in between. Ask again.
tries=0
until xcrun stapler staple "$app"; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || exit 1
  echo "No ticket yet; asking again in 30 s ($tries/10)"
  sleep 30
done
# Apple's ticket server drops connections now and then; the ticket is fine.
for i in 1 2 3 4 5; do xcrun stapler validate "$app" && break; [ "$i" -lt 5 ] || exit 1; sleep 20; done

spctl -a -vvv -t exec "$app"
echo "Signed, notarised and stapled: $app"
