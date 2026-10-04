# Yamaha YAS-207

This repository hosts (some of) the code to remotely control
a Yamaha YAS-207 soundbar.

It's part of a multi-weekend project to build an [AirPlay speaker
using the YAS-207 and Raspberry Pi](https://wejn.org/2021/04/multi-weekend-project-reversing-yamaha-yas-207-remote-control/).

## Why this fork in 2026

The original wejn.org work (2021) reverse-engineered the YAS-207 Bluetooth
protocol and provided a minimal Ruby controller. This maintained fork
extends that foundation into a scriptable, session-aware control layer
suitable for modern home-audio integrations.

**Audio signal path (preferred/digital):** HDMI and the logical `tv` input
(where optical/TOSLINK and HDMI ARC are physical paths to the same
logical `tv` input) feed digital audio into the soundbar. Analog audio
remains supported as an optional logical input/path. Bluetooth is used
by this architecture **for Yamaha control/commands**, not as the audio
transport; Bluetooth audio may be possible at the hardware level but is
not the integration path this repo currently uses or tests.

**Modern integrations** feed networked audio via the digital path while
this repo handles Yamaha input/session switching, volume state, and
restoration:

- **Music Assistant + AirPlay Receiver plugin**: exposes a MA player
  backed by the YAS-207 path as an AirPlay receiver (iPhone/macOS can
  stream to it). AirPlay 1/RAOP compatibility mode via Shairport Sync is
  typically required; AirPlay 2 is not supported by Shairport.
- **Music Assistant AirPlay player provider**: MA can *send* audio to an
  AirPlay/RAOP target (e.g., a Shairport instance driving the YAS-207
  `tv` input).
- **Sendspin**: direct Music Assistant integration via the Sendspin
  adapter with persistent MA volume across sessions.
- **Shairport Sync**: AirPlay 1/RAOP receiver driving the logical `tv`
  input via ALSA SPDIF/TOSLINK or HDMI ARC.

This repo coordinates the soundbar around the audio path; it does not
implement AirPlay or audio transport itself.

Other audio-path combinations are welcome as PRs, especially with tests
or reproducible setup notes. Do not claim support for paths that are not
currently tested.

## Maintained fork

This is a maintained fork of
[wejn/yamaha-yas-207](https://github.com/wejn/yamaha-yas-207), originally
authored by Michal Jirku (wejn.org). The original reversing work
(`reversing/`) and the `control/` core are preserved; with no
configuration file the controller behaves identically to the original.

Maintained additions:

* JSON configuration with backwards-compatible defaults
  (`docs/configuration.md`, `examples/profiles/`)
* Staged session restore with closed-loop volume verification,
  crash recovery via a persistent session snapshot, and a `GET /state`
  endpoint
* Player adapters (Sendspin, Shairport Sync) under `adapters/`; the
  controller is audio-transport independent and none of the transports
  are required
* Durable Music Assistant volume persistence via XDG state directory
  (`adapters/sendspin/yas207-sendspin`)
* HTTP API reference (`docs/http-api.md`)
* systemd deployment templates under `deployment/`

## License & AGPL compliance

This project is licensed under the **GNU Affero General Public License
v3.0** (see `LICENSE`). Upstream copyright and authorship are retained:
Michal Jirku (wejn.org).

The `reversing/` directory contains original protocol-analysis scripts
from the upstream project. One file (`reversing/parse-btsnoop.rb`) carries
an ambiguous license note (`GPL2? I don't know.`); its provenance and
license are inherited from upstream and are not relicensed by this fork.
If distributing the repository as a whole under AGPL-3.0 creates a
compliance concern for that file, treat it as upstream-legacy material
with uncertain licensing.

## Contents / usage

For contents of the `reversing` directory see [Yamaha YAS-207's Bluetooth protocol
reversed](https://wejn.org/2021/04/yas-207-bluetooth-protocol-reversed/).

For usage instructions of the `control` directory please see [Yamaha YAS-207's
Minimal Client (and a Soundbar Fake)](http://wejn.org/2021/04/yas-207-minimal-client-and-a-soundbar-fake/).

## Minimal viable control

@jmiskovic mentioned in [Issue #1](https://github.com/wejn/yamaha-yas-207/issues/1)
that there's an easy way to get started with just shell:

``` sh
# Valid for YAS-107 (& also YAS-207)
sudo -s
bt-device -l | grep YAS                # find out the device address
rfcomm bind rfcomm0 C8:84:xx:xx:xx:xx  # bind bluetooth device to /dev/rfcomm0 serial

echo -en "\xCC\xAA\x03\x40\x78\x4A\xFB" > /dev/rfcomm0   # change the input to HDMI
echo -en "\xCC\xAA\x03\x40\x78\xD1\x74" > /dev/rfcomm0   # change the input to ANALOG
echo -en "\xCC\xAA\x03\x40\x78\x29\x1C" > /dev/rfcomm0   # change the input to BLUETOOTH
echo -en "\xCC\xAA\x03\x40\x78\xDF\x66" > /dev/rfcomm0   # change the input to TV
echo -en "\xCC\xAA\x03\x40\x78\x1E\x27" > /dev/rfcomm0   # volume +
echo -en "\xCC\xAA\x03\x40\x78\x1F\x26" > /dev/rfcomm0   # volume -
echo -en "\xCC\xAA\x03\x40\x78\x7F\xC6" > /dev/rfcomm0   # power off
```

For more commands you can look at the commands in `control.rb`, but you'll have to come
up with the checksum. So maybe:

``` sh
$ cd control/
$ f(){ ruby -e '$:<<"."; require "common.rb"' \
  -e 'print YamahaPacketCodec.encode(ARGV.map { |x| x.to_i(16) })' "$@"; }
$ f 40 78 4a | xxd
00000000: ccaa 0340 784a fb                        ...@xJ.
```

## Credits

* Author: Michal Jirku (wejn.org)
* Maintained fork: [fortiko/yamaha-yas-207](https://github.com/fortiko/yamaha-yas-207)
* License: GNU Affero General Public License v3.0 (see `LICENSE`)
