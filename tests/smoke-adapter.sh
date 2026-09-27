#!/usr/bin/env bash
# Smoke test: Sendspin adapter yas207-sendspin volume mapping + config validation.
# Runs on any host with Python 3 (no serial port required).

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$REPO_ROOT/examples/profiles/analogue-sendspin.json"
ADAPTER="$REPO_ROOT/adapters/sendspin/yas207-sendspin"

if [ ! -f "$CONFIG" ]; then
    echo "FAIL: config not found at $CONFIG" >&2
    exit 1
fi

if [ ! -x "$ADAPTER" ]; then
    echo "FAIL: adapter not executable: $ADAPTER" >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

YAS207_CONFIG="$CONFIG" \
YAS207_RUNTIME_DIR="$TMPDIR/runtime" \
    python3 - "$ADAPTER" <<'PY'
import runpy, sys
adapter_path = sys.argv[1]
m = runpy.run_path(adapter_path)
cfg = m['load_config']()
vol = cfg['volume']

failures = []

# Volume mapping checks
expected_raw = {0: 0, 1: 1, 20: 4, 50: 10, 80: 16, 100: 20}
for ma, want in expected_raw.items():
    got = m['ma_to_raw'](ma, vol)
    if got == want:
        print(f"OK  ma_to_raw({ma}) = {got}")
    else:
        print(f"FAIL ma_to_raw({ma}): got {got}, want {want}")
        failures.append(f"ma_to_raw({ma})")

# Music intent shape
intent_0 = m['compute_music_intent'](cfg, 0)
if intent_0.get('mute') is True and 'volume' not in intent_0:
    print(f"OK  compute_music_intent(0) = {intent_0}")
else:
    print(f"FAIL compute_music_intent(0): {intent_0}")
    failures.append("compute_music_intent(0)")

intent_50 = m['compute_music_intent'](cfg, 50)
if intent_50.get('mute') is False and intent_50.get('volume') == 10:
    print(f"OK  compute_music_intent(50) = {intent_50}")
else:
    print(f"FAIL compute_music_intent(50): {intent_50}")
    failures.append("compute_music_intent(50)")

intent_100 = m['compute_music_intent'](cfg, 100)
if intent_100.get('mute') is False and intent_100.get('volume') == 20:
    print(f"OK  compute_music_intent(100) = {intent_100}")
else:
    print(f"FAIL compute_music_intent(100): {intent_100}")
    failures.append("compute_music_intent(100)")

# Validation rejections
import json, tempfile, os
_BASE_CONFIG_PATH = os.environ['YAS207_CONFIG']

def with_cfg(overrides):
    base = json.loads(open(_BASE_CONFIG_PATH).read())
    for path, value in overrides.items():
        cur = base
        for k in path.split('.')[:-1]:
            cur = cur.setdefault(k, {})
        cur[path.split('.')[-1]] = value
    f = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False, dir=tempfile.gettempdir())
    json.dump(base, f); f.flush(); f.close()
    return f.name

cases = [
    ('music_intent has volume', [('session.music_intent', {'input':'analog','volume':10})]),
    ('music_intent has mute',   [('session.music_intent', {'input':'analog','mute':True})]),
    ('music_intent has power (manage_power=false)', [('session.music_intent', {'input':'analog','power':True})]),
    ('bad bluetooth address',   [('controller.bluetooth_address', 'not-a-mac')]),
    ('volume.min_nonzero_raw=0 with zero_is_mute=true', [('volume.min_nonzero_raw', 0)]),
    ('max_raw > 50',            [('volume.max_raw', 60)]),
]
for label, overrides in cases:
    p = with_cfg(dict(overrides))
    os.environ['YAS207_CONFIG'] = p
    try:
        m['validate_config'](json.loads(open(p).read()))
        print(f"FAIL {label}: did not reject")
        failures.append(label)
    except SystemExit as e:
        if e.code == 2:
            print(f"OK  {label}: rejected (exit 2)")
        else:
            print(f"FAIL {label}: wrong exit code {e.code}")
            failures.append(label)
    finally:
        os.unlink(p)

if failures:
    print(f"\nFAIL: {len(failures)} check(s) failed")
    sys.exit(1)
print("\nPASS")
PY
