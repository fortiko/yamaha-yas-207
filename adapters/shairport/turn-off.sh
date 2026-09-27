#!/bin/sh
# Shairport Sync integration: turn-off.sh
#
# Called by shairport-sync's run_this_after_play_ends configuration.
# Tells the upstream YAS-207 controller to stop the session and let it
# restore the pre-session state.

set -eu

NAME="airplay"
HOST="${YAS207_CONTROLLER_HOST:-127.0.0.1}"
PORT="${YAS207_CONTROLLER_PORT:-8000}"

exec curl -fsS --max-time 5 \
    "http://${HOST}:${PORT}/stop-session" \
    -d "name=${NAME}"
