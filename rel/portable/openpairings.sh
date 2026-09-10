#!/bin/sh
# Start OpenPairings on this machine, for one person, with no setup.
#
# Sets OPENPAIRINGS_LOCAL because a plain release cannot work it out for
# itself: the standalone binary detects `__BURRITO`, and this is precisely
# the build that is not one.
set -e
here=$(cd "$(dirname "$0")" && pwd)
OPENPAIRINGS_LOCAL=1
PORT=${PORT:-4000}
# Erlang distribution off. A release does not do this by default: it starts
# `epmd` on 0.0.0.0:4369 and a node listener on 0.0.0.0:<ephemeral>, both on
# every interface. Measured on the Windows build of this same release, not
# assumed; the web port was already correctly pinned to loopback and these two
# were not.
#
# What makes it more than untidy is the cookie. `releases/COOKIE` ships inside
# the download, so it is the same on every copy anybody installs, and a
# reachable node plus a known cookie is a stranger running code on this
# machine. On club or hotel wifi that is a real door, not a theoretical one.
# Nothing here wants distribution: one person, one computer, and stopping is
# the Ctrl-C below rather than a remote call.
#
# Overridable, so `RELEASE_DISTRIBUTION=sname ./openpairings.sh` still gives a
# node that `bin/pairings_engine_portable remote` can attach to. That is a
# thing somebody chooses, never a thing that happens by default.
#
# The cost, stated plainly: `bin/pairings_engine_portable stop|restart|pid`
# are all RPC to a named node, so against an instance started this way they
# have nothing to talk to. Ctrl-C is the stop, which is what this script has
# always told people and what the line below still says.
RELEASE_DISTRIBUTION=${RELEASE_DISTRIBUTION:-none}
export OPENPAIRINGS_LOCAL PORT RELEASE_DISTRIBUTION
echo "Starting OpenPairings on http://localhost:$PORT"
echo "Press Ctrl-C to stop it."
echo
exec "$here/bin/pairings_engine_portable" start
