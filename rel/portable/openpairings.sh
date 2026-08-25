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
export OPENPAIRINGS_LOCAL PORT
echo "Starting OpenPairings on http://localhost:$PORT"
echo "Press Ctrl-C to stop it."
echo
exec "$here/bin/pairings_engine_portable" start
