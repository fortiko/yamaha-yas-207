# Configuration

The Yamaha YAS-207 controller (`control/control.rb`) loads a single
JSON configuration file. The same file is parseable by both the Ruby
controller and any Ruby/Python helpers (no extra dependencies beyond
the stdlib `json`).

## Locations

| Source | Path |
|---|---|
| Default | `~/.config/yas207/controller.json` |
| Env override | `YAS207_CONFIG=/absolute/path/to/file.json` |
| Test override | `YAS207_RUNTIME_DIR=/run/user/<uid>/yas207` |

If the config file does not exist, the controller falls back to its
hard-coded defaults. This is the backwards-compatible behaviour for
users who upgrade from the original project without writing a config.

The runtime directory is derived deterministically from the effective
UID:

    /run/user/<euid>/yas207

`XDG_RUNTIME_DIR` is intentionally NOT consulted. If the directory
does not exist it is created with mode `0700`. Set
`YAS207_RUNTIME_DIR` to override for tests only.

## Schema overview

```jsonc
{
  "controller": { ... },
  "session":    { ... },
  "volume":     { ... },
  "player":     { ... }
}
```

Each section is independent. Generic defaults (preserving upstream
behaviour) apply when a key is absent. See `docs/profiles.md` for the
rationale of each key.

### `controller`

| Key | Type | Default | Notes |
|---|---|---|---|
| `rfcomm_device` | string | `/dev/rfcomm0` | BT SPP serial device |
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
recommended state for installations that already have a configured TV
state), or keep the legacy upstream defaults without any new key.

### `session`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | **required** | session identifier (matched by `/start-session` / `/stop-session`) |
| `music_intent` | object | **required** | static intent applied on `start-session` |
| `stop_debounce_seconds` | int ≥ 0 | `10` | player-side debounce on STOP events |

Keys in `music_intent` not listed here (e.g. `surround`, `bass_ext`,
`subwoofer`) are passed through to upstream's `parse_intent` for
validation.

### `volume`

| Key | Type | Default | Notes |
|---|---|---|---|
| `min_nonzero_raw` | int 0..50 | `1` | floor for non-mute volume mapping |
| `max_raw` | int 1..50 | `50` | YAS hardware max (not a tuned preference) |
| `zero_is_mute` | bool | `false` | if `true`, raw `0` is treated as `mute: true` instead of raw 0 |
| `default_percent` | int 0..100 | `50` | default volume percent at session start |
| `remember_when_inactive` | bool | `true` | if `true`, adapter remembers last volume when no session is active |

`min_nonzero_raw` is a floor for volume mappings that need a non-zero
raw value (e.g. 1% → 1 raw). `max_raw` caps the upper bound — the
YAS-207 hardware accepts `0..50`, so any value above 50 is invalid.

### `player`

The `player` section is purely informational in the controller itself
— the controller never reads audio transport configuration. The
schema is published here so the same config file can document the
audio path side without forcing a second config.

| Key | Type | Default | Notes |
|---|---|---|---|
| `type` | string | — | short identifier, e.g. `shairport`, `sendspin`, `none` |
| `name` | string | — | human-readable player name |
| `audio_format` | string | — | e.g. `pcm:44100:16:2` |
| `audio_device` | object | — | opaque to the controller; consumed by the audio transport |
| `hardware_volume` | bool | `false` | if `true`, the player owns volume/mute; controller does not enforce |
| `use_mpris` | bool | `false` | if `true`, the player uses MPRIS for control |

## Backward compatibility

With no config file the controller behaves identically to upstream
master:

- `manage_power = true` (auto-power-on path runs)
- `initial_intent` is absent (legacy `INITIAL_INTENT` is applied)
- `rfcomm_device = /dev/rfcomm0`
- `http_bind = 127.0.0.1`
- `http_port = 8000`
- `sync_timeout_seconds = 15`
- `status_refresh_seconds = 30`

No existing user-visible behaviour changes unless a config file is
written.

## Failure modes

A config file that fails to parse (`JSON.parse` raises) is a fatal
configuration error: the controller prints the path and the exception
to stderr and exits with code 2. This is intentional — silently
ignoring a broken config is worse than failing to start.
