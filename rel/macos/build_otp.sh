#!/bin/sh
# Builds the Erlang runtime and Elixir for the Mac app, on a Mac.
#
#   rel/macos/build_otp.sh <prefix>
#
# Run by .github/workflows/binaries.yml on the macOS runner,
# once per cache key: the result is cached, so a push that changes none of
# the versions below finds it ready. Writes
#
#   <prefix>/openssl/   OpenSSL, static, only to build crypto against
#   <prefix>/otp/       Erlang/OTP, `make install`ed (bin/erl, lib/erlang)
#   <prefix>/elixir/    Elixir's own precompiled zip for this OTP major
#
# Why from source: the ready-made Erlang for macOS (erlef/otp_builds, which
# setup-beam installs) is built on the newest runner for that runner's own
# macOS, and every program in it said "macOS 15 or newer". The app inherited
# that, and a Mac on 14 refused to open it. Here everything is compiled for
# MACOSX_DEPLOYMENT_TARGET, which the workflow sets (11.0, the first macOS
# for Apple Silicon); clang and ld both read it from the environment.
#
# OpenSSL is linked into crypto.so statically (--disable-dynamic-ssl-lib):
# the runner's Homebrew has an OpenSSL, the arbiter's Mac does not.
# build_app.sh fails the build on any link outside the system, and on any
# file that asks for a newer macOS than 11.
#
# The versions come from the workflow's env (OTP_VERSION, OPENSSL_VERSION,
# ELIXIR_VERSION), the checksums from here: a version without a checksum
# below stops the build, so a bump is two edits and never zero.

set -eu

prefix=${1:?usage: build_otp.sh <prefix>}
: "${OTP_VERSION:?set OTP_VERSION}"
: "${OPENSSL_VERSION:?set OPENSSL_VERSION}"
: "${ELIXIR_VERSION:?set ELIXIR_VERSION}"
: "${MACOSX_DEPLOYMENT_TARGET:?set MACOSX_DEPLOYMENT_TARGET (11.0)}"
export MACOSX_DEPLOYMENT_TARGET

# SHA-256 of the exact files, as GitHub lists them on each release page.
case "$OTP_VERSION" in
  29.0.5) otp_sha256=86f6f40d4638852b0383235b02a70d8450184e441e83a06a108bf8e5bf1b2e04 ;;
  *) echo "::error::no checksum for otp_src_$OTP_VERSION.tar.gz in build_otp.sh" >&2; exit 1 ;;
esac
case "$OPENSSL_VERSION" in
  3.5.9) openssl_sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a ;;
  *) echo "::error::no checksum for openssl-$OPENSSL_VERSION.tar.gz in build_otp.sh" >&2; exit 1 ;;
esac
otp_major=${OTP_VERSION%%.*}
case "$ELIXIR_VERSION-otp-$otp_major" in
  1.20.4-otp-29) elixir_sha256=7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46 ;;
  *) echo "::error::no checksum for Elixir $ELIXIR_VERSION (elixir-otp-$otp_major.zip) in build_otp.sh" >&2; exit 1 ;;
esac

jobs=$(sysctl -n hw.ncpu)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { # url file sha256
  curl -fsSL --retry 3 -o "$2" "$1"
  actual=$(shasum -a 256 "$2" | cut -d' ' -f1)
  [ "$actual" = "$3" ] || {
    echo "::error::$1: expected sha256 $3, got $actual" >&2
    exit 1
  }
}

rm -rf "$prefix"
mkdir -p "$prefix"

# --- OpenSSL ---------------------------------------------------------------
# Static libraries and headers only: no shared libraries for anything to
# find at run time, no programs, no manuals.
echo "OpenSSL $OPENSSL_VERSION for macOS $MACOSX_DEPLOYMENT_TARGET"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "$work/openssl.tar.gz" "$openssl_sha256"
tar -xzf "$work/openssl.tar.gz" -C "$work"
(
  cd "$work/openssl-$OPENSSL_VERSION"
  ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
    "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --prefix="$prefix/openssl" --openssldir="$prefix/openssl/ssl" --libdir=lib
  make -j"$jobs" build_libs >/dev/null
  make install_dev >/dev/null
)

# --- Erlang/OTP ------------------------------------------------------------
# No wx (and so no observer or debugger windows), no Java, no ODBC: none is
# in the release, and the last two would go looking for Homebrew.
echo "Erlang/OTP $OTP_VERSION for macOS $MACOSX_DEPLOYMENT_TARGET"
fetch "https://github.com/erlang/otp/releases/download/OTP-$OTP_VERSION/otp_src_$OTP_VERSION.tar.gz" \
  "$work/otp.tar.gz" "$otp_sha256"
tar -xzf "$work/otp.tar.gz" -C "$work"
(
  cd "$work/otp_src_$OTP_VERSION"
  ./configure --prefix="$prefix/otp" \
    --with-ssl="$prefix/openssl" --disable-dynamic-ssl-lib \
    --without-wx --without-javac --without-odbc
  # configure lists what it skipped; crypto must not be on that list.
  if [ -f lib/crypto/SKIP ]; then
    echo "::error::configure skipped crypto; the OpenSSL above was not usable" >&2
    exit 1
  fi
  make -j"$jobs"
  make install
)

# --- Elixir ----------------------------------------------------------------
echo "Elixir $ELIXIR_VERSION (elixir-otp-$otp_major.zip)"
fetch "https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR_VERSION/elixir-otp-$otp_major.zip" \
  "$work/elixir.zip" "$elixir_sha256"
mkdir -p "$prefix/elixir"
unzip -q "$work/elixir.zip" -d "$prefix/elixir"

# --- what came out -------------------------------------------------------
# A crypto that loads, with the OpenSSL above inside it, and a runtime that
# asks for no newer macOS than the target. build_app.sh checks every file
# again in the finished app; this is the early, cheaper no.
"$prefix/otp/bin/erl" -noshell -eval '
  ok = crypto:start(),
  [{_, _, Name}] = crypto:info_lib(),
  io:format("crypto: ~s~n", [Name]),
  halt().'
beam=$(ls "$prefix"/otp/lib/erlang/erts-*/bin/beam.smp)
vtool -show-build "$beam" | sed 's/^/  /'
otool -L "$prefix"/otp/lib/erlang/lib/crypto-*/priv/lib/crypto.so | sed 's/^/  /'
PATH="$prefix/otp/bin:$PATH" "$prefix/elixir/bin/elixir" -e 'IO.puts("Elixir #{System.version()} on OTP #{System.otp_release()}")'
