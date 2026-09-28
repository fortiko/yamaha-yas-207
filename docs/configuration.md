# Configuration

The Yamaha YAS-207 controller (`control/control.rb`) and any player adapter
load a single JSON configuration file. The same file is parsed by both the
Ruby controller and the Python adapters — there are no extra dependencies
beyond `json` (Ruby stdlib) and `json` (Python stdlib).

## Locations

| Source | Path |
|---|---|
| Default | `~/.config/yas207/controller.json` |
| Env override | `YAS207_CONFIG=/absolute/path/to/file.json` |
| Test/dev override | `YAS207_RUNTIME_DIR=/run/user/<uid>/yas207` |

If the config file does not exist, the controller falls back to upstream
legacy behaviour (no config-driven policy). This is the backwards-compatible
default for users who upgrade from the original project.

The runtime directory is derived deterministically from the effective UID:

    /run/user/<euid>/yas207

`XDG_RUNTIME_DIR` is intentionally NOT consulted. If the directory does not
exist it is created with mode `0700`. Set `YAS207_RUNTIME_DIR` to override
for tests only.

## Schema overview

```jsonc
{
  "controller": { ... },
  "session":    { ... },
  "volume":     { ... },
  "player":     { ... }
}
```

Each section is independent. Generic defaults (preserving upstream behaviour)
apply when a key is absent. See `docs/profiles.md` for the rationale of
each key and example profiles.

### `controller`

| Key | Type | Default | Notes |
|---|---|---|---|
| `rfcomm_device` | string | `/dev/rfcomm0` | BT SPP serial device |
| `rfcomm_channel` | int 1..30 | `1` | SPP channel; used if the project later owns binding |
| `bluetooth_address` | string | absent (required by adapters) | MAC `XX:XX:XX:XX:XX:XX` of the unit |
| `http_bind` | string | `127.0.0.1` | controller HTTP bind address |
| `http_port` | int 1..65535 | `8000` | controller HTTP port |
| `sync_timeout_seconds` | int | `15` | retry interval if SPP sync stalls |
| `status_refresh_seconds` | int | `30` | periodic device-state poll interval |
| `manage_power` | bool | `true` | if `false`, controller never issues `power_*` commands |
| `initial_intent` | object | **absent → legacy** | see tri-state below |
| `idle_input_policy` | string | **absent → disabled** | idle/post-connect input sanitization, see below |

#### `controller.initial_intent` — tri-state semantics

| Config state | Behaviour |
|---|---|
| key **absent** | upstream legacy `INITIAL_INTENT` is applied on first sync |
| key present, value `{}` | NO initial intent is applied on first sync |
| key present, non-empty | the configured intent is applied on first sync, validated by the upstream `parse_intent` rules |

This lets users opt in to first-sync defaults, opt out entirely (the
recommended state for installations that already have a configured TV state),
or keep the legacy upstream defaults without any new key.

#### `controller.idle_input_policy` — idle / post-connect input sanitization

An SPP/RFCOMM reconnect can wake the Yamaha, and the device may come up with
`input: bluetooth`. In installations where Bluetooth AUDIO is not used (SPP
stays control-only), that input must not be left as the idle state merely as
a side effect of establishing the control connection.

When set to an input name that has a `set_input_<name>` command (e.g. `"tv"`),
the controller corrects the input — and verifies it via the next device
status report — when **all** of the following hold at a status report:

- the device is positively powered on,
- no session is active (including session start-up),
- no staged restore is in progress,
- no intent is pending (initial / manual / session commands),
- the observed input is exactly `bluetooth`.

Guarantees / non-goals:

- the default (key absent or `null`) disables the feature entirely —
  upstream behaviour is preserved;
- it never powers the device on or off (a genuinely off device is left off);
- it only ever corrects the unwanted `bluetooth` input — any other idle
  input (including the policy input itself, `analog`, `hdmi`, …) is
  untouched;
- it never interferes with an active music session, session start-up,
  staged restoration, or crash recovery;
- the reconnect itself — and any wake it caused — remains a separate
  lifecycle observation in the controller log (`+ DS:` lines); the
  sanitization is logged on its own lines
  (`+ Idle input: … applying policy input=…` /
  `+ Idle input: policy input=… verified`);
- correction is bounded: if the device does not confirm the policy input
  within `15 s`, the attempt is logged as unverified and the correction
  simply re-arms on the next idle `bluetooth` observation.

### `session`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | **required** | upstream session identifier |
| `music_intent` | object | **required** | static intent applied on `start-session`. **Must NOT contain `volume` or `mute` when `player.hardware_volume == false`;** the adapter owns those fields |
| `stop_debounce_seconds` | int ≥ 0 | `10` | adapter-side debounce on STOP events |

Keys in `music_intent` not listed here (e.g. `surround`, `bass_ext`,
`subwoofer`) are passed through to upstream's `parse_intent` for validation.

### `volume`

| Key | Type | Default | Notes |
|---|---|---|---|
| `min_nonzero_raw` | int 1..50 | `1` | floor applied to non-zero MA→raw mapping |
| `max_raw` | int ≤ 50 | `50` | music maximum; YAS hardware max is 50 |
| `zero_is_mute` | bool | `false` | if `true`, MA `0` → upstream `{mute:true}` |
| `default_percent` | int 0..100 | `50` | initial remembered MA volume |
| `remember_when_inactive` | bool | `true` | if `true`, inactive volume events update remembered value but never touch the YAS |

The mapping is:
```
ma_to_raw(v) = max(min_nonzero_raw, round(v * max_raw / 100))   # v > 0
```

`max_raw` is an installation preference, NOT a YAS hardware limit. The YAS
raw volume protocol range is `0..50` (device maximum is 50); `max_raw` is
the listening ceiling the adapter maps player volume to. Player volume
events while no session is active (`remember_when_inactive`) update the
remembered value only and never touch the YAS.

### `player`

| Key | Type | Default | Notes |
|---|---|---|---|
| `type` | enum | **required** | one of `sendspin`, `shairport` |
| `name` | string | **required** | display name |
| `interface` | string | **required** | bind IP address |
| `audio_device` | object | **required** | see below |
| `audio_format` | string | **required** | `codec:rate:bits:channels` |
| `hardware_volume` | bool | `false` | adapter owns volume translation |
| `use_mpris` | bool | `false` | set `false` to keep the transport off D-Bus/MPRIS (recommended for headless hosts) |
| `hooks.start` | string | **required** | shell command for stream-start |
| `hooks.stop` | string | **required** | shell command for stream-stop |
| `hooks.set_volume` | string | **required** | argv form for volume events |

#### `player.audio_device`

```json
{
  "audio_device": {
    "match": "Example ALSA Device"
  }
}
```

| Key | Type | Notes |
|---|---|---|
| `match` | string | durable ALSA name or name prefix. Sent to Sendspin as `--audio-device "<match>"` |

`match` is required. The match string is sent verbatim to Sendspin
(`--audio-device "<match>"`); PortAudio’s substring match resolves the
durable name at runtime, so the numeric index cannot drift across
reboots or device reordering.

## Configuration validation and failure modes

The Ruby controller and the Python adapters validate the config at startup,
each to the extent it consumes it:

* The **controller** reads the `controller` section (plus `session`
  metadata for session commands). A config that fails to parse
  (`JSON.parse` raises) is a fatal configuration error: the controller
  prints the path and the exception to stderr and exits with code `2`.
  Invalid `controller.idle_input_policy` values (not a non-empty string,
  or no `set_input_<name>` command) raise `ArgumentError` at startup.
* The **adapters** enforce the full schema, including the `player` section
  and `controller.bluetooth_address`. Validation failures log the reason
  and exit with code `2`.

Hard requirements for adapter use (config is invalid without):

* All keys marked **required** above
* `controller.bluetooth_address` matches `^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`
* `session.music_intent` is an object (may be empty)
* `player.audio_device.match` is a non-empty string
* `volume.min_nonzero_raw ≤ volume.max_raw ≤ 50`
* If `volume.zero_is_mute == true`: `volume.min_nonzero_raw ≥ 1`

Cross-field rules:

* If `controller.manage_power == false`: `session.music_intent` MUST NOT
  contain the key `power`.
* `session.music_intent` MUST NOT contain `volume` or `mute` when
  `player.hardware_volume == false` (adapter-owned).
* `session.music_intent.input` if present ∈ {`hdmi`, `analog`, `bluetooth`, `tv`}.
* `session.music_intent.surround` if present ∈ {`"3d"`, `tv`, `stereo`,
  `movie`, `music`, `sports`, `game`}.

A controller-only installation (e.g. `examples/profiles/minimal.json`)
needs no `player` section and no `bluetooth_address`; those fields are
required only when an adapter runs.

## Backward compatibility

With no config file the controller behaves identically to upstream master:

* `manage_power = true` (legacy auto-power-on path runs)
* `initial_intent` absent (legacy `INITIAL_INTENT` is applied on first sync)
* `rfcomm_device = /dev/rfcomm0`
* `http_bind = 127.0.0.1`, `http_port = 8000`
* `sync_timeout_seconds = 15`, `status_refresh_seconds = 30`
* volume mapping defaults (`max_raw = 50`, the protocol maximum)

No user-visible behaviour changes unless a config file is written.

## Session snapshot, crash recovery, and staged restore

* The pre-session state is captured **exactly once** per `start-session`
  (at the first confirmed device status before the music intent is
  applied) and persisted to
  `/run/user/<euid>/yas207/controller/session.json`.
* If the controller process dies mid-session, the next startup
  rehydrates the saved state and resumes the staged restore from where
  the previous process left off. A snapshot that is unreadable or
  malformed is logged and ignored (the controller starts fresh, no
  session). A successfully completed restore deletes the snapshot.
* Staged restore ordering: `:mute` → `:volume` (closed-loop convergence
  with bounded correction) → `:sound` (clearvoice / surround / bass
  extension / subwoofer) → `:input` (only after volume and sound state
  are verified) → `:post_input_volume` (re-verify, since input switches
  can reset volume) → `:final_mute` → `:final_power`.
* `:final_power` is the **last** restore phase. It runs only when the
  saved state has `power: false` AND the session powered the device on
  with `power_on_completed: true`; otherwise the device is left as-is.
  If the process crashed before wake-up verification
  (`power_on_completed: false`), restore is conservative and does NOT
  emit `power_off`.
* While a staged restore is in flight, user mutation requests (`send`,
  `send_intent`, `start_session`, `stop_session`, `send_raw`) are
  rejected with `RuntimeError("session restore in progress")`.

## Runtime state locations

| File | Owner | Purpose |
|---|---|---|
| `/run/user/<euid>/yas207/state.json` | adapter | desired player volume, session_active, pending_stop_token |
| `/run/user/<euid>/yas207/lock` | adapter | flock for serialising all adapter operations |
| `/run/user/<euid>/yas207/yas207-sendspin.log` | adapter | adapter log |
| `/run/user/<euid>/yas207/controller/session.json` | controller | persistent session snapshot (for crash recovery) |

The controller and adapter use disjoint directories; they communicate only
via the HTTP API on the controller.
