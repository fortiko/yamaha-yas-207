# Profiles

The configuration model is intentionally split between:

* **device facts** — YAS-207 protocol constants, never configurable
* **generic defaults** — preserve upstream behaviour when no config key is set
* **user / installation preferences** — always in config, profile-overridable
* **correctness invariants** — never configurable, hard-coded in the controller

This separation prevents the upstream default behaviour from drifting
to match one specific installation.

## Classification

### Device facts (Bucket A — never configurable)

* YAS raw volume hardware range `0..50`
* All command opcodes in the upstream `COMMANDS` table
* Input byte→symbol map (`INPUT_NAMES`)
* Surround byte→symbol map (`SURROUND_NAMES`)
* Subwoofer domain `0..32 step 4`
* Initial handshake string (`HTS Cont` + `020001`)

These are baked into `control/control.rb` and never read from config.

### Generic defaults (Bucket C — preserve upstream behaviour)

| Key | Default | Behaviour preserved |
|---|---|---|
| `controller.manage_power` | `true` | upstream auto-power-on path runs |
| `controller.initial_intent` (absent) | upstream legacy | `{subwoofer:16, surround::tv, bass_ext:true, clearvoice:false}` |
| `controller.rfcomm_device` | `/dev/rfcomm0` | upstream default |
| `controller.http_bind` | `127.0.0.1` | upstream default |
| `controller.http_port` | `8000` | upstream default |
| `controller.sync_timeout_seconds` | `15` | upstream `SYNC_TIMEOUT` |
| `controller.status_refresh_seconds` | `30` | upstream `STATUS_REFRESH` |
| `volume.min_nonzero_raw` | `1` | safe floor |
| `volume.max_raw` | `50` | YAS hardware max, NOT a tuned preference |
| `volume.zero_is_mute` | `false` | raw `0` is a valid Yamaha silent state |
| `volume.default_percent` | `50` | sensible centre |
| `volume.remember_when_inactive` | `true` | safer (memory but no YAS touch) |
| `player.hardware_volume` | `false` | adapter-controlled volume |
| `player.use_mpris` | `false` | defensive default |

Upstream users who upgrade without writing a config file see no
behaviour change.

### Correctness invariants (Bucket D — never configurable)

* Session restoration is staged: temporary mute → volume → sound state
  → input → final mute. This prevents an audible blast when restoring
  a higher-volume state to a lower saved volume.
* `/state` reports `session.restoring` truthfully. Callers can poll
  until both `session.active` and `session.restoring` are false before
  tearing down their own audio resources.
* A persistent session snapshot survives process crashes — the next
  controller startup rehydrates the saved state and resumes the
  staged restore exactly where the previous process left off.
* User mutation requests (`send`, `send_intent`, `start_session`,
  `stop_session`, `send_raw`) are rejected with
  `RuntimeError("session restore in progress")` while staged restore
  is in flight.

## What is NOT in the profile

* Audio transport configuration (ALSA device, USB DAC, SPDIF/TOSLINK,
  HDMI). These are owned by the player (Shairport Sync, Sendspin,
  others). The Yamaha controller does not need to know which ALSA
  device is producing audio — only the chosen YAS input
  (`session.music_intent.input`).
* Bluetooth A2DP output. Not implemented in the controller. The
  controller would not need to change to support A2DP; a future A2DP
  transport would require its own transport-specific adapter.
