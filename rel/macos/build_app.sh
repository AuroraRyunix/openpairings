#!/bin/sh
# Builds OpenPairings.app around a finished portable release, on a Mac.
#
#   rel/macos/build_app.sh <portable release dir> <output dir>
#
# Run from the repository root, by .github/workflows/binaries.yml on the
# macOS runners; it works the same on any Mac with the Xcode command line
# tools. Writes <output dir>/OpenPairings.app, ad-hoc signed. Developer ID
# signing and notarisation are a separate step (sign_and_notarize.sh) that
# only runs when the certificate exists.
#
# The bundle:
#
#   OpenPairings.app/Contents/Info.plist        rel/macos/Info.plist, filled in
#   OpenPairings.app/Contents/MacOS/OpenPairings rel/macos/Launcher.swift, compiled
#   OpenPairings.app/Contents/Resources/launcher.sh  rel/macos/launcher.sh
#   OpenPairings.app/Contents/Resources/app/    the portable release, whole
#   OpenPairings.app/Contents/Resources/OpenPairings.icns  from the logo
#
# The executable is a small AppKit program (the Dock icon and the window)
# compiled here with swiftc for arm64 and macOS 11; launcher.sh beside the
# release is the part that starts and stops the server. A Swift program on
# macOS 11 and newer links to /usr/lib/swift and the system frameworks
# only, which the check below allows like any other system library.
#
# Two things are checked here because nothing after this would notice them
# until somebody's Mac refused to start the program:
#
#   * every Mach-O file links only to the system (/usr/lib, /System) or to
#     itself. The runner has Homebrew; the arbiter's Mac does not. A NIF or
#     an ERTS that picked up /opt/homebrew/... works here and nowhere else.
#   * the oldest macOS every Mach-O file accepts (its `minos`). The newest of
#     those is what the bundle can honestly claim, so it goes into
#     LSMinimumSystemVersion and the job log, instead of a number typed once
#     and never checked.

set -eu

payload=${1:?usage: build_app.sh <portable release dir> <output dir>}
out=${2:?usage: build_app.sh <portable release dir> <output dir>}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ -x "$payload/bin/pairings_engine_portable" ] || {
  echo "::error::$payload is not a portable release (no bin/pairings_engine_portable)" >&2
  exit 1
}

# The release's own version, which mix.exs gave it - never a second copy.
version=$(sed -n 's/^[^ ]* \([0-9][0-9.]*\)$/\1/p' "$payload/releases/start_erl.data")
[ -n "$version" ] || {
  echo "::error::no version in $payload/releases/start_erl.data" >&2
  exit 1
}

app="$out/OpenPairings.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# ditto, not cp -R: it keeps modes, symlinks and extended attributes.
ditto "$payload" "$app/Contents/Resources/app"
cp "$here/launcher.sh" "$app/Contents/Resources/launcher.sh"
chmod 755 "$app/Contents/Resources/launcher.sh"

# The app's executable. swiftc's complaints go to the log in full and, for
# errors, to the run's summary as annotations on the line they are about:
# the first compile of this file happens here, on a Mac nobody sits at.
swift_source="${here#"$PWD"/}/Launcher.swift"
swift_log=$(mktemp)
if ! xcrun swiftc -O -swift-version 5 -target arm64-apple-macos11 -framework AppKit \
  -o "$app/Contents/MacOS/OpenPairings" "$swift_source" >"$swift_log" 2>&1; then
  sed -n 's/^\(.*\.swift\):\([0-9][0-9]*\):\([0-9][0-9]*\): error: \(.*\)$/::error file=\1,line=\2,col=\3::\4/p' "$swift_log"
  echo "swiftc failed on $swift_source; everything it said:"
  cat "$swift_log"
  rm -f "$swift_log"
  exit 1
fi
cat "$swift_log"
rm -f "$swift_log"
echo "Launcher compiled: $(file "$app/Contents/MacOS/OpenPairings" | cut -d: -f2-)"
otool -L "$app/Contents/MacOS/OpenPairings"

# The Dock icon, drawn by rel/build_taskbar_icon.py. Cosmetic: a failure
# leaves Finder's generic icon and a warning, not a failed build.
make_icon() {
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$1" --out "$2/icon_${size}x${size}.png" >/dev/null || return 1
    sips -z $((size * 2)) $((size * 2)) "$1" --out "$2/icon_${size}x${size}@2x.png" >/dev/null ||
      return 1
  done
  iconutil -c icns "$2" -o "$3"
}

logo=rel/macos/OpenPairings-icon.png
iconset="$out/OpenPairings.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
if [ -f "$logo" ] && make_icon "$logo" "$iconset" "$app/Contents/Resources/OpenPairings.icns"; then
  echo "Icon made from $logo"
else
  echo "::warning::could not make OpenPairings.icns; the app gets the generic icon"
fi
rm -rf "$iconset"

# Links and minimum system, per Mach-O file.
bad=0
minimum=11.0
found=$(mktemp)
find "$app" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 >"$found"
while IFS= read -r binary; do
  # Only what it loads: `otool -L` also prints a library's own id, which
  # for a precompiled NIF is a path on the machine that built it.
  libs=$(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD)_DYLIB$/ {f=1; next} f && $1 == "name" {print $2; f=0}')
  for lib in $libs; do
    case "$lib" in
      /usr/lib/* | /System/Library/* | @rpath/* | @loader_path/* | @executable_path/*) ;;
      *)
        echo "::error::$binary links to $lib, which a Mac without it does not have"
        bad=1
        ;;
    esac
  done

  minos=$(otool -l "$binary" | awk '
    /LC_BUILD_VERSION/ { want = "minos" }
    /LC_VERSION_MIN_MACOSX/ { want = "version" }
    want != "" && $1 == want { print $2; want = "" }' | head -1)
  if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minimum" "$minos" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$minos" ]; then
    minimum=$minos
  fi
done <"$found"
echo "Mach-O files: $(wc -l <"$found" | tr -d ' '), oldest macOS all of them accept: $minimum"
rm -f "$found"
[ "$bad" = 0 ] || exit 1

sed -e "s/__VERSION__/$version/g" -e "s/__MINIMUM_SYSTEM__/$minimum/g" \
  "$here/Info.plist" >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# Ad-hoc: no identity, but every Mach-O carries a signature, which Apple
# Silicon requires before it runs a single instruction, and the bundle is
# sealed. It does not satisfy Gatekeeper; see docs/macos.md for what the
# arbiter clicks instead, and sign_and_notarize.sh for what replaces it.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

echo "Built $app ($version, macOS $minimum or newer)"
