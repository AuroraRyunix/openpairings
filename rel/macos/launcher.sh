#!/bin/sh
# The server half of OpenPairings.app: copied to Contents/Resources/launcher.sh
# by rel/macos/build_app.sh and run by the app's own executable
# (rel/macos/Launcher.swift, Contents/MacOS/OpenPairings), which is the half
# you see: the Dock icon, the small window, the browser. Finder never runs
# this file directly; a terminal can.
#
#   1. Works out where it is from its own path and finds the release in
#      Contents/Resources/app.
#   2. If OpenPairings already answers on the port, leaves at once (exit 0):
#      a second start is not a second server. The app then opens a tab.
#   3. Starts the release in local mode, Erlang distribution off, with every
#      file it writes OUTSIDE the bundle (see "Nothing is written into the
#      app" below). Its output is this script's output; the app points that
#      at logs/server.log in the data folder, a fresh file on every start.
#   4. Waits until the port really answers, says so, and then waits for the
#      server for as long as it runs.
#
# ## Exit codes, which the app turns into sentences
#
#   0  stopped when asked, or another copy already answers
#   2  the release is missing from inside the app
#   3  the data folder cannot be created
#   4  the server stopped while starting
#   5  no answer within two minutes; the server has been stopped
#   anything else, once it answered: the server's own exit status
#
# ## Stopping
#
# SIGTERM, SIGINT or SIGHUP to this script sends SIGTERM to the BEAM, which
# since OTP 19 means a clean `init:stop()` - every SQLite connection closed
# in order - and waits up to twenty seconds before insisting. The app sends
# the SIGTERM on Quit, on logout and on shutdown.
#
# If the app itself disappears without that (Force Quit, a crash), this
# script notices its parent is gone and stops the server anyway: a server
# nobody can see is a server nobody can stop.
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

set -u

contents=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
app="$contents/Resources/app"
release="$app/bin/pairings_engine_portable"

PORT=${PORT:-4000}
url="http://localhost:$PORT"
data=${OPENPAIRINGS_DATA_DIR:-"$HOME/Library/Application Support/OpenPairings"}

answers() {
  curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null
}

if [ ! -x "$release" ]; then
  echo "OpenPairings is incomplete: $release is missing." >&2
  exit 2
fi

# Already running: do not start a second one that cannot bind.
if answers; then
  echo "OpenPairings already answers on $url"
  exit 0
fi

if ! mkdir -p "$data"; then
  echo "OpenPairings cannot create its data folder: $data" >&2
  exit 3
fi

export OPENPAIRINGS_LOCAL=1
# The app opens the browser itself, once the port answers.
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
cd "$data" || exit 3

echo "Starting $release ($url, data in $data)"
"$release" start &
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

# The parent watch: the app, gone without a word, takes the server with it.
# Not when the parent is launchd (pid 1), which `kill -0` cannot ask about.
parent=$PPID
watcher=
if [ "$parent" -gt 1 ]; then
  (
    while kill -0 "$parent" 2>/dev/null; do sleep 2; done
    kill -TERM $$ 2>/dev/null
  ) &
  watcher=$!
fi

trap 'if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null; fi' EXIT
trap 'stop_server; exit 0' TERM INT HUP

# Two minutes, for a start that normally takes a few seconds: a first start
# migrates a new database, and a Mac busy indexing a fresh download is slow.
waited=0
until answers; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "OpenPairings stopped while starting." >&2
    exit 4
  fi
  if [ "$waited" -ge 120 ]; then
    stop_server
    echo "OpenPairings did not answer within two minutes, and has been stopped." >&2
    exit 5
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "OpenPairings answers on $url"
wait "$pid"
status=$?
exit "$status"
