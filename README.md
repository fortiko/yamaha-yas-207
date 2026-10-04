# Yamaha YAS-207

Control a Yamaha YAS-207 soundbar over Bluetooth serial from Linux — named
sessions switch inputs, manage volume, and restore the previous state;
Music Assistant integration is available via Sendspin.

This repo coordinates the soundbar around the audio path. It does not
implement audio transport itself.

## Quick Start

### Requirements

- **Linux** with BlueZ (`bt-device`, `rfcomm`) and a Bluetooth adapter
- **Ruby** with the `serialport` gem (`gem install serialport`)
- **Python 3** (standard library only) for the Sendspin adapter
- A user session providing `/run/user/$UID/` (systemd/logind)

### Pair and bind the soundbar

```sh
bt-device -l | grep YAS                     # find the soundbar's address
sudo rfcomm bind rfcomm0 C8:84:xx:xx:xx:xx  # use your address
```

Binding needs privileges; for boot-time binding see
`deployment/systemd/yas207-rfcomm-bind.service`.

### Test basic control

Send one raw command as proof-of-life (switch input to TV):

```sh
echo -en "\xCC\xAA\x03\x40\x78\xDF\x66" > /dev/rfcomm0   # input to TV
```

Then start the controller from the repo root and read its state:

```sh
ruby control/control.rb
curl -fsS http://127.0.0.1:8000/state
```

Without a config file the controller keeps upstream behavior.

### Configure the controller

```sh
mkdir -p ~/.config/yas207
cp examples/profiles/minimal.json ~/.config/yas207/controller.json
```

Edit the copy for your setup. The file is also honored at `$YAS207_CONFIG`;
see [Configuration](#configuration).

### Music Assistant / Sendspin

The maintained example plays music from Music Assistant over Sendspin
through HDMI: while music plays, the soundbar switches to logical Yamaha
input `hdmi` with a music-oriented profile, then restores the prior
state afterwards.

1. Create the config:

   ```sh
   mkdir -p ~/.config/yas207
   cp examples/profiles/hdmi-sendspin.json ~/.config/yas207/controller.json
   ```

   Then set three values for your setup:
   - `controller.bluetooth_address` — Bluetooth address of the YAS-207;
   - `player.interface` — address Sendspin listens on (bind IP address);
   - `player.audio_device.match` — stable ALSA device name (or prefix)
     of your HDMI output; never a numeric index.

   The profile already selects logical `hdmi`, Yamaha Music surround
   mode, and Clear Voice off for music.

2. Install the adapter at its canonical path:

   ```sh
   sudo install -Dm755 \
     adapters/sendspin/yas207-sendspin \
     /usr/local/sbin/yas207/yas207-sendspin
   ```

   Sendspin calls this adapter on playback start, stop, and volume
   changes; `deployment/systemd/sendspin.service` shows the hook wiring.

3. Start the controller, then Sendspin, and start playback from Music
   Assistant. Expect the YAS-207 to switch to HDMI, apply the music
   profile, and follow the MA volume; when playback stops, the
   controller restores the pre-session snapshot.

## Music Assistant

Sendspin is the player this repo integrates with. On stream start and stop
(with a configurable debounce), Sendspin invokes
`adapters/sendspin/yas207-sendspin`, which opens and closes a named
session on the controller (`/start-session`, `/stop-session`). Starting a
session snapshots the soundbar state and applies the configured music
intent; stopping it restores the snapshot in stages, volume first and
power last.

While a session is active the adapter owns volume and mute: Music
Assistant volume changes are translated to the Yamaha raw range and
remembered across sessions in `$XDG_STATE_HOME/yas207/sendspin-volume.json`
(falling back to the configured default). Volume events received while no
session is active update the remembered value without touching the soundbar.

### Why profiles?

A soundbar shared with a TV usually idles in a TV-oriented state — for
example, 3D surround playback (`surround: "3d"`) with Clear Voice
(`clearvoice`) enabled. Music over Music Assistant wants something else:
logical input `hdmi` with a music-oriented Yamaha mode such as the Music
surround mode (`surround: "music"`) or Stereo (2-channel) playback
(`surround: "stereo"`), usually with Clear Voice disabled. A profile
records the music side of that split in `session.music_intent`; when the
Sendspin session ends after the configured stop debounce, the controller
restores the snapshot taken before playback started, prior input and
sound settings included.

Bonus: Music Assistant's optional AirPlay Receiver plugin can expose the
MA-managed player to phones and laptops; that receiver is handled
entirely by Music Assistant, not by this repo.

## What this fork adds

- JSON configuration with upstream-compatible defaults
  (`docs/configuration.md`, `examples/profiles/`)
- Session snapshot, staged restore, and crash recovery, plus a
  `GET /state` endpoint (`docs/http-api.md`)
- Sendspin player adapter (`adapters/sendspin/yas207-sendspin`) with
  persistent Music Assistant volume; the controller itself stays
  audio-transport independent
- Example profiles (`examples/profiles/`) and systemd units (`deployment/`)

## Audio paths

The wired logical inputs are `analog`, `hdmi`, and `tv`; physical
optical/TOSLINK and HDMI ARC connections both arrive as logical `tv`.
Bluetooth here carries Yamaha control commands over serial (RFCOMM); it
is not the maintained audio transport.

## Configuration

All behavior beyond upstream defaults lives in one JSON file
(`~/.config/yas207/controller.json`, or `$YAS207_CONFIG`); see
`docs/configuration.md`, `docs/profiles.md`, and `examples/profiles/`.

## Repository layout

- `control/` — Ruby controller (device protocol, session model, HTTP API)
- `adapters/sendspin/` — Sendspin hook adapter (session and volume bridge)
- `deployment/` — systemd units and install notes (`deployment/README.md`)
- `docs/` — configuration, profiles, HTTP API, compatibility notes
- `examples/profiles/` — ready-to-copy JSON profiles
- `reversing/` — original Bluetooth protocol reversing helpers
- `tests/` — smoke suites and adapter dispatch tests

## Background

Michal Jirku reverse-engineered the YAS-207 Bluetooth protocol in 2021 and
published a minimal Ruby controller ([project write-up](https://wejn.org/2021/04/multi-weekend-project-reversing-yamaha-yas-207-remote-control/),
[protocol notes](https://wejn.org/2021/04/yas-207-bluetooth-protocol-reversed/)).
This fork keeps that work (`reversing/`, `control/` core) and adds
configuration, sessions, and player integration on top.

## Credits

- Original work: Michal Jirku ([wejn.org](https://wejn.org)) —
  [wejn/yamaha-yas-207](https://github.com/wejn/yamaha-yas-207)
- Maintained fork: [fortiko/yamaha-yas-207](https://github.com/fortiko/yamaha-yas-207)
- License: GNU AGPL v3.0 — see `LICENSE`.
