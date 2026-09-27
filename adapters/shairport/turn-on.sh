#!/bin/sh
# Shairport Sync integration: turn-on.sh
#
# Called by shairport-sync's run_this_before_play_begins configuration.
# Tells the upstream YAS-207 controller to start a music session with the
# pre-configured music_intent (e.g. {input:"tv", surround:"music"} for the
# upstream TOSLINK profile).
#
# Configuration is read by the upstream controller, not here.

set -eu

NAME="airplay"
HOST="${YAS207_CONTROLLER_HOST:-127.0.0.1}"
PORT="${YAS207_CONTROLLER_PORT:-8000}"
CONFIG="${YAS207_CONFIG:-$HOME/.config/yas207/controller.json}"

if [ -r "$CONFIG" ]; then
    INTENT=$(jq -c '.session.music_intent' "$CONFIG" 2>/dev/null || echo '{}')
else
    INTENT='{"input":"tv","surround":"music"}'
fi

exec curl -fsS --max-time 5 \
    "http://${HOST}:${PORT}/start-session" \
    -d "name=${NAME}" \
    --data-urlencode "intent=${INTENT}"
