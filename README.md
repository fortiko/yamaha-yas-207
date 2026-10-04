# Yamaha YAS-207

A small controller for the Yamaha YAS-207 soundbar, with a practical Music Assistant + Sendspin setup.

The maintained example uses:

- **Bluetooth** to control the YAS-207;
- **HDMI** for Music Assistant audio;
- **Sendspin** as the Music Assistant player;
- a small controller profile so music can use different Yamaha sound settings from TV.

This does not need a full PC or server. Any small Linux system with Bluetooth, network access and HDMI audio can do the job. A **Raspberry Pi Zero 2 W** is a compact example; larger Raspberry Pi models are fine too.

## Quick Start

The commands below are written for Debian / Raspberry Pi OS.

### 1. Clone the repository

```sh
mkdir -p ~/src
git clone https://github.com/fortiko/yamaha-yas-207.git ~/src/yamaha-yas-207
cd ~/src/yamaha-yas-207
```

### 2. Install the basic dependencies

```sh
sudo apt update
sudo apt install -y \
  git curl bluez \
  ruby ruby-dev build-essential \
  libportaudio2
```

Install the Ruby serial-port library used by the controller:

```sh
gem install serialport
```

Install `uv`, then Sendspin:

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

uv tool install sendspin
sendspin --help
```

### 3. Pair the YAS-207 over Bluetooth

Put the soundbar into Bluetooth pairing/discoverable mode, then run:

```sh
bluetoothctl
```

Inside `bluetoothctl`:

```text
power on
scan on
```

Wait for the YAS-207 to appear and note its Bluetooth address, for example:

```text
AA:BB:CC:DD:EE:FF
```

Then:

```text
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
quit
```

Bind the Yamaha serial-control channel:

```sh
sudo rfcomm bind /dev/rfcomm0 AA:BB:CC:DD:EE:FF 1
```

### 4. Find this machine's LAN address and HDMI audio device

Find the LAN address that Music Assistant can reach:

```sh
ip -br addr
```

Then list the audio devices Sendspin can use:

```sh
sendspin audio-devices list
```

Note the HDMI device you want Sendspin to use.

### 5. Create the Yamaha / Sendspin profile

```sh
mkdir -p ~/.config/yas207
cp examples/profiles/hdmi-sendspin.json \
  ~/.config/yas207/controller.json
```

Edit:

```sh
nano ~/.config/yas207/controller.json
```

Set:

- `controller.bluetooth_address` to the YAS-207 Bluetooth address;
- `player.interface` to this machine's LAN IP address;
- `player.audio_device.match` to the HDMI device reported by Sendspin.

The supplied profile already uses the Yamaha logical input `hdmi`, the **Music** surround mode, and **Clear Voice** off while music is playing.

### 6. Install the Sendspin adapter

```sh
sudo install -Dm755 \
  adapters/sendspin/yas207-sendspin \
  /usr/local/sbin/yas207/yas207-sendspin
```

The adapter connects Sendspin's playback lifecycle and volume changes to the Yamaha controller.

### 7. Start the Yamaha controller

From the repository root:

```sh
ruby control/control.rb
```

Leave it running.

You can check the controller from another terminal:

```sh
curl -fsS http://127.0.0.1:8000/state
```

### 8. Start Sendspin

Use the same LAN address and HDMI device that you put in the profile:

```sh
sendspin daemon \
  --name "Yamaha YAS-207" \
  --interface <THIS-MACHINE-IP> \
  --audio-device "<YOUR-HDMI-AUDIO-DEVICE>" \
  --audio-format flac:48000:16:2 \
  --hardware-volume false \
  --hook-start /usr/local/sbin/yas207/yas207-sendspin \
  --hook-stop /usr/local/sbin/yas207/yas207-sendspin \
  --hook-set-volume /usr/local/sbin/yas207/yas207-sendspin \
  --log-level INFO \
  --disable-mpris
```

For example, replace `<THIS-MACHINE-IP>` with `192.168.1.50` and `<YOUR-HDMI-AUDIO-DEVICE>` with the HDMI device shown by `sendspin audio-devices list`.

### 9. Play music

With Music Assistant on the same network, the Sendspin player should normally appear automatically.

If Sendspin asks for pairing, keep the Sendspin terminal visible: it will show the pairing information needed to complete setup in Music Assistant.

Select **Yamaha YAS-207** in Music Assistant and play something.

During playback the soundbar should:

- switch to HDMI;
- apply the music settings from the profile;
- follow Music Assistant volume.

When playback stops and the configured stop debounce expires, the controller restores the Yamaha state that was present before the music session started.

### 10. Make it persistent

Once the manual setup works, use the supplied systemd units for automatic startup:

[deployment/README.md](deployment/README.md)

Get the manual path working first; systemd should only make that working setup persistent.

## Music Assistant

The maintained setup is:

```text
Music Assistant
      |
      v
   Sendspin
      |
      v
 HDMI audio
      |
      v
 Yamaha YAS-207
```

Bluetooth is used for Yamaha control commands. It is not the audio transport in this setup.

### Why profiles?

A soundbar used for both TV and music often benefits from different settings for each job.

For example, the YAS-207 may spend most of its time on TV with Yamaha **3D surround playback** and **Clear Voice** enabled. Those settings can work well for dialogue, but they are not necessarily what you want for music.

For Music Assistant, the profile can temporarily switch to the logical `hdmi` input and use Yamaha's **Music** surround mode or **Stereo (2-channel) playback**, usually with **Clear Voice** disabled.

When the Sendspin session ends, the controller restores the snapshot captured before playback started, including the previous input and sound settings. There is no separate hard-coded "TV preset" to maintain.

Music Assistant can also expose an AirPlay Receiver player if you enable that plugin; this is separate from the Yamaha control path described here.

## What this fork adds

Compared with the original reverse-engineering project, this fork adds a small controller and deployment layer around the discovered YAS-207 protocol:

- HTTP control and state API;
- configurable Yamaha state intents;
- session snapshot and restore;
- Sendspin start/stop/volume integration;
- persistent Music Assistant volume;
- systemd deployment examples;
- example profiles for common audio paths.

The reverse-engineered Yamaha protocol remains the foundation.

## Audio paths

The controller recognises three wired Yamaha inputs:

- `hdmi` — the maintained Music Assistant / Sendspin example;
- `tv` — the Yamaha logical TV input, used by optical/TOSLINK or HDMI ARC;
- `analog` — supported as an alternative analog music path.

Bluetooth is separate and is used here for Yamaha control.

## Configuration

The main example used by this README is:

```text
examples/profiles/hdmi-sendspin.json
```

Copy it to:

```text
~/.config/yas207/controller.json
```

For the complete configuration reference, see:

- [docs/configuration.md](docs/configuration.md)
- [docs/profiles.md](docs/profiles.md)
- [docs/http-api.md](docs/http-api.md)
- [docs/compatibility.md](docs/compatibility.md)

## Repository layout

```text
control/                 Yamaha controller and HTTP API
adapters/sendspin/       Sendspin integration
examples/profiles/       Example controller profiles
deployment/systemd/      systemd unit examples
docs/                    Configuration and protocol documentation
reversing/               Original protocol-research helpers
```

## Background

The YAS-207 exposes useful control over its Bluetooth serial interface, including power, input, volume and sound settings.

The original project reverse-engineered that protocol. This fork keeps that work and adds enough state management and player integration to use the soundbar as part of a modern Music Assistant setup without changing the soundbar itself.

## Credits

Original Yamaha YAS-207 reverse engineering and protocol work by **Michal Jirku / wejn.org**.

This repository is licensed under the **GNU Affero General Public License v3.0**; see [LICENSE](LICENSE).