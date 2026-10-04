# Profiles

The configuration model is intentionally split between:

* **device facts** — YAS-207 protocol constants, never configurable
* **generic defaults** — preserve upstream behaviour when no config key is set
* **user / installation preferences** — always in config, profile-overridable
* **correctness invariants** — never configurable, hard-coded in the controller

This separation prevents the upstream default behaviour from drifting to
match one specific installation.

## Classification

### Device facts (Bucket A — never configurable)

* YAS raw volume hardware range `0..50`
* All command opcodes in the upstream `COMMANDS` table
* Input byte→symbol map (`INPUT_NAMES`)
* Surround byte→symbol map (`SURROUND_NAMES`)
* Subwoofer domain `0..32 step 4`
* SPP channel 1 on YAS-207
* Initial handshake string (`HTS Cont` + `020001`)

These are baked into `control/control.rb` and never read from config.

### Generic defaults (Bucket C — preserve upstream behaviour)

| Key | Default | Behaviour preserved |
|---|---|---|
| `controller.manage_power` | `true` | upstream auto-power-on path runs |
| `controller.initial_intent` (absent) | upstream legacy | `{subwoofer: 16, surround: :tv, bass_ext: true, clearvoice: false}` |
| `controller.rfcomm_device` | `/dev/rfcomm0` | upstream default |
| `controller.http_bind` | `127.0.0.1` | upstream default |
| `controller.http_port` | `8000` | upstream default |
| `controller.sync_timeout_seconds` | `15` | upstream `SYNC_TIMEOUT` |
| `controller.status_refresh_seconds` | `30` | upstream `STATUS_REFRESH` |
| `volume.min_nonzero_raw` | `1` | safe floor |
| `volume.max_raw` | `50` | YAS hardware max, NOT a tuned preference |
| `volume.zero_is_mute` | `false` | raw `0` is a valid Yamaha silent state |
| `volume.default_percent` | `50` | sensible centre |
| `volume.follow_remote_ma_volume_while_inactive` | `true` | safer (memory but no YAS touch) |
| `player.hardware_volume` | `false` | adapter-controlled volume |
| `player.use_mpris` | `false` | defensive default |

Upstream users who upgrade without writing a config file see no behaviour
change.

### Correctness invariants (Bucket D — never configurable)

* Session restoration is staged, in this order: temporary mute → volume
  (closed-loop, with bounded correction) → sound state (clearvoice /
  surround / bass extension / subwoofer) → input → post-input volume
  re-verification → final mute → **final power LAST**. Muting first and
  restoring power last prevents audible blasts when restoring pre-music
  state.
* Inactive player volume events MUST NOT contact or wake the Yamaha,
  regardless of any other setting.
* Session state is captured exactly once per `start-session`; subsequent
  starts reuse the saved state (do not overwrite with music-modified state).
* HTTP errors from the controller preserve adapter state (allow retry).

## Shipped example profiles

| Profile | Purpose |
|---|---|
| `examples/profiles/minimal.json` | controller-only, upstream-style defaults (no player section) |
| `examples/profiles/shairport-tv-optical.json` | mirrors the upstream Shairport Sync design |
| `examples/profiles/analogue-music.json` | generic analogue-input music profile |
| `examples/profiles/analogue-sendspin.json` | Sendspin transport over the analogue input |

All examples use synthetic placeholder values (example MAC
`02:0A:0B:0C:0D:0E`, documentation IP `192.0.2.x`); replace them with your
own unit's values.

### `analogue-sendspin.json` — key choices

| Key | Value | Why |
|---|---|---|
| `controller.manage_power` | `false` | the controller must not own power; e.g. in a TV-over-ARC installation the TV already powers the YAS and the controller must not interfere |
| `controller.initial_intent` | `{}` | first sync is non-intrusive; existing TV-state preferences are not overridden |
| `session.music_intent` | `{input: "analog", clearvoice: false, surround: "music", bass_ext: false}` | music goes to the ANALOG input; Clear Voice (dialogue enhancement) off for music; Music surround mode; bass extension off |
| `volume.max_raw` | `50` | full protocol range; choose a lower value if you want an installation listening ceiling — it is a policy cap, not a hardware limit |
| `volume.zero_is_mute` | `true` | player volume `0` maps to mute, avoiding raw-0 confusion |
| `player.audio_device.match` | `"Example ALSA Device"` | durable ALSA name, not a numeric index |
| `player.use_mpris` | `false` | keeps the transport off D-Bus/MPRIS |

Keys not set in the profile fall back to the generic defaults above.

### `analogue-music.json` — a generic music starting point

Same analogue-input music concept (input `analog`, clearvoice off,
surround `music`, bass extension off; subwoofer intentionally
unspecified — unconfigured fields are never reset by the controller),
with placeholder transport values. It is a starting point, not a
tuned recommendation: set `volume.max_raw` and the player section for
your own installation.

### `shairport-tv-optical.json` — original upstream design

Mirrors the design from the upstream blog post:

* `manage_power: true` (legacy)
* `initial_intent` absent (legacy)
* `music_intent: {input: "tv", surround: "music"}` (TV is the music input for TOSLINK)
* `volume.max_raw: 50` (full hardware range)
* `volume.zero_is_mute: false` (raw 0 is fine)

## What is NOT in the profile

* Audio transport configuration (ALSA device, USB DAC, SPDIF/TOSLINK, HDMI).
  These are owned by the player (Sendspin, Shairport). The Yamaha controller
  does not need to know which ALSA device is producing audio.
* TV / HDMI-ARC wiring. Out of scope.
* Bluetooth A2DP output. Not implemented in this branch (see
  `docs/compatibility.md`).

The general project remains capable of supporting all these audio paths;
the configuration only encodes what is unique to a given installation.
