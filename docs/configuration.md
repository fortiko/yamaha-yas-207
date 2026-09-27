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
| `bluetooth_address` | string | **required** | MAC `XX:XX:XX:XX:XX:XX` |
| `http_bind` | string | `127.0.0.1` | controller HTTP bind address |
| `http_port` | int 1..65535 | `8000` | controller HTTP port |
| `sync_timeout_seconds` | int | `15` | retry interval if SPP sync stalls |
| `status_refresh_seconds` | int | `30` | periodic device-state poll interval |
| `manage_power` | bool | `true` | if `false`, controller never issues `power_*` commands |
| `initial_intent` | object | **absent → legacy** | see tri-state below |

#### `controller.initial_intent` — tri-state semantics

| Config state | Behaviour |
|---|---|
| key **absent** | upstream legacy `INITIAL_INTENT` is applied on first sync |
| key present, value `{}` | NO initial intent is applied on first sync |
| key present, non-empty | the configured intent is applied on first sync, validated by the upstream `parse_intent` rules |

This lets users opt in to first-sync defaults, opt out entirely (the
recommended state for installations that already have a configured TV state),
or keep the legacy upstream defaults without any new key.

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

`max_raw` is an installation preference, NOT a YAS hardware limit. YAS
hardware max raw is 50.

### `player`

| Key | Type | Default | Notes |
|---|---|---|---|
| `type` | enum | **required** | one of `sendspin`, `shairport` |
| `name` | string | **required** | display name |
| `interface` | string | **required** | bind IP address |
| `audio_device` | object | **required** | see below |
| `audio_format` | string | **required** | `codec:rate:bits:channels` |
| `hardware_volume` | bool | `false` | adapter owns volume translation |
| `use_mpris` | bool | `false` | matches our `~/.config/sendspin/settings-daemon.json` |
| `hooks.start` | string | **required** | shell command for stream-start |
| `hooks.stop` | string | **required** | shell command for stream-stop |
| `hooks.set_volume` | string | **required** | argv form for volume events |

#### `player.audio_device`

```json
{
  "audio_device": {
    "match":          "Example ALSA Device",
    "index_override": 0
  }
}
```

| Key | Type | Notes |
|---|---|---|
| `match` | string | durable name or name prefix. Sent to Sendspin as `--audio-device "<match>"` |
| `index_override` | int ≥ 0 | optional. If set, overrides `match`. **Manual tests only**; production deployments should rely on `match`. |

If neither key is set the player config is invalid.

## Configuration validation

Both the Ruby controller and the Python adapters validate the config at
startup. Failures log and exit non-zero.

Hard requirements (config is invalid without):

* All keys marked **required** above
* `controller.bluetooth_address` matches `^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`
* `session.music_intent` is an object (may be empty)
* `player.audio_device` contains at least one of `match` or `index_override`
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

## Runtime state locations

| File | Owner | Purpose |
|---|---|---|
| `/run/user/<euid>/yas207/state.json` | adapter | desired MA volume, session_active, pending_stop_token |
| `/run/user/<euid>/yas207/lock` | adapter | flock for serialising all adapter operations |
| `/run/user/<euid>/yas207/yas207-sendspin.log` | adapter | adapter log |
| `/run/user/<euid>/yas207/controller/session.json` | controller | persistent session snapshot (for crash recovery) |

The controller and adapter use disjoint directories; they communicate only
via the HTTP API on the controller.
