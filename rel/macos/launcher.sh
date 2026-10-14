#!/bin/sh
# OpenPairings.app's front door: copied to Contents/MacOS/OpenPairings by
# rel/macos/build_app.sh, and what Finder runs when the app is opened.
#
# It does on a Mac what OpenPairings.exe (rel/windows/launcher.c) does on
# Windows, as far as a shell script and macOS's own `osascript` allow:
#
#   1. Works out where it is from its own path (Finder gives it no useful
#      working directory) and finds the release in Contents/Resources/app.
#   2. If OpenPairings already answers on the port, opens a browser tab at it
#      and exits: a second double-click is not a second server.
#   3. Starts the release in local mode, Erlang distribution off, with every
#      file it writes OUTSIDE the bundle (see "Nothing is written into the
#      app" below), and its output in launcher.log beside the data.
#   4. Waits until the port really answers, then opens the browser.
#   5. Stays, as a small window that says OpenPairings is running and has
#      two buttons: "Open in browser" and "Stop OpenPairings". The server's
#      lifetime is that window's, the same rule as on Windows.
#
# The window is AppleScript's `display dialog`, run by `osascript`, which
# every Mac has. No compiled helper, nothing to sign separately, and nothing
# that can go stale beside this file. A menu-bar icon would be nicer and
# needs a real Cocoa program; this is the version that can be built and
# checked without a Mac on the desk.
#
# ## Stopping
#
# "Stop OpenPairings" sends SIGTERM to the BEAM, which since OTP 19 means a
# clean `init:stop()` - every SQLite connection closed in order - and waits
# up to twenty seconds before insisting. Logging out or shutting down sends
# this script SIGTERM too, and the trap below passes it on. If the server
# dies by itself, the window is replaced by one that says so and names the
# log.
#
# ## Nothing is written into the app
#
# An unsigned app opened from Downloads is "translocated" by Gatekeeper: run
# from a random, read-only copy. And anything written into a signed bundle
# breaks its seal. So RELEASE_TMP (where a release writes its runtime
# sys.config) goes to the user's temporary folder, the working directory -
# where a crash dump would land - is the data folder, and the data itself is
# in ~/Library/Application Support/OpenPairings, which no installer, updater
# or uninstaller of this app has ever heard of. CI makes the bundle
# read-only before it starts it, so a regression here fails the build.
#
# ## Headless (CI)
#
# OPENPAIRINGS_LAUNCHER_NO_UI=1 skips every window and the browser, logs to
# standard output, and simply waits for the server - which is how the build
# job starts this exact file on a runner nobody is looking at.

set -u

contents=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
app="$contents/Resources/app"
release="$app/bin/pairings_engine_portable"

PORT=${PORT:-4000}
url="http://localhost:$PORT"
data=${OPENPAIRINGS_DATA_DIR:-"$HOME/Library/Application Support/OpenPairings"}
headless=${OPENPAIRINGS_LAUNCHER_NO_UI:-}

version=$(sed -n 's/^[^ ]* \([0-9][0-9.]*\)$/\1/p' "$app/releases/start_erl.data" 2>/dev/null)
title="OpenPairings${version:+ $version}"

# A dialog with one OK button. The text goes in as an argument, never into
# the script: a path with a quote in it must not become AppleScript.
tell() {
  if [ "$headless" = 1 ]; then
    echo "$1" >&2
    return
  fi
  osascript - "$1" "$title" >/dev/null 2>&1 <<'EOF'
on run argv
  activate
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button "OK" with icon caution
end run
EOF
}

answers() {
  curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null
}

if [ ! -x "$release" ]; then
  tell "OpenPairings is incomplete: the program is missing from inside the app. Download it again and replace this copy."
  exit 1
fi

# Already running: show it, do not start a second one that cannot bind.
if answers; then
  [ "$headless" = 1 ] || open "$url"
  exit 0
fi

if ! mkdir -p "$data"; then
  tell "OpenPairings cannot create its data folder: $data"
  exit 1
fi

export OPENPAIRINGS_LOCAL=1
# The launcher opens the browser itself, once the port answers.
export OPENPAIRINGS_NO_BROWSER=1
export PORT
# Distribution off, for the reason openpairings.sh spells out: a reachable
# node plus a cookie that ships inside every download is a stranger running
# code on this Mac. Passed through when set, for debugging from a terminal;
# Finder never sets it.
export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}"
export RELEASE_TMP="${TMPDIR:-/tmp}/OpenPairings"
# Finder starts an app with no locale at all, and the VM then warns that it
# runs in latin1. File names are UTF-8 on every Mac.
export LANG="${LANG:-en_US.UTF-8}"
mkdir -p "$RELEASE_TMP"
cd "$data" || exit 1

if [ "$headless" = 1 ]; then
  log=/dev/stdout
  "$release" start &
else
  log="$data/launcher.log"
  {
    echo
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') $title from $contents"
  } >>"$log"
  "$release" start >>"$log" 2>&1 &
fi
pid=$!

stop_server() {
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

trap 'stop_server; exit 0' TERM INT HUP

# Two minutes, for a start that normally takes a few seconds: a first start
# migrates a new database, and a Mac busy indexing a fresh download is slow.
waited=0
until answers; do
  if ! kill -0 "$pid" 2>/dev/null; then
    tell "OpenPairings stopped while starting. What it said is in: $log"
    exit 1
  fi
  if [ "$waited" -ge 120 ]; then
    stop_server
    tell "OpenPairings did not answer within two minutes, and has been stopped. What it said is in: $log"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

if [ "$headless" = 1 ]; then
  echo "OpenPairings answers on $url"
  wait "$pid"
  exit $?
fi

open "$url"

# The status window, for as long as the server runs. A dialog that cannot
# be shown at all (no window server: started over SSH) fails at once; three
# of those in a row and the launcher stops trying and simply waits.
answer_file="$RELEASE_TMP/launcher-answer.$$"
quick_failures=0
while kill -0 "$pid" 2>/dev/null; do
  started=$(date +%s)
  osascript - "$url" "$title" >"$answer_file" 2>/dev/null <<'EOF' &
on run argv
  activate
  set message to "OpenPairings is running at " & (item 1 of argv) & "." & return & return & "Leave this window open while you work: stopping OpenPairings closes the program, and your tournaments stay saved."
  set reply to display dialog message with title (item 2 of argv) buttons {"Stop OpenPairings", "Open in browser"} default button "Open in browser"
  return button returned of reply
end run
EOF
  dialog=$!

  while kill -0 "$dialog" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      kill "$dialog" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$dialog" 2>/dev/null
  reply=$(cat "$answer_file" 2>/dev/null)

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$answer_file"
    tell "OpenPairings has stopped unexpectedly. What it said is in: $log"
    exit 1
  fi

  case "$reply" in
    "Stop OpenPairings")
      rm -f "$answer_file"
      stop_server
      exit 0
      ;;
    "Open in browser")
      quick_failures=0
      open "$url"
      ;;
    *)
      # Closed some other way (Cmd-Q on the dialog) or never shown.
      if [ $(($(date +%s) - started)) -lt 3 ]; then
        quick_failures=$((quick_failures + 1))
      else
        quick_failures=0
      fi
      if [ "$quick_failures" -ge 3 ]; then
        rm -f "$answer_file"
        wait "$pid"
        exit $?
      fi
      sleep 1
      ;;
  esac
done

rm -f "$answer_file"
exit 0
