#!/usr/bin/env bash
# Smoke test: Sendspin adapter dispatch contract (start/stop/set-volume
# hooks, plus legacy/manual argv forms). Runs on any host with Python 3
# (no serial port, no Sendspin, no controller required).

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST="$REPO_ROOT/tests/test_adapter_dispatch.py"

if [ ! -f "$TEST" ]; then
    echo "FAIL: test file not found: $TEST" >&2
    exit 1
fi

exec python3 "$TEST" "$@"