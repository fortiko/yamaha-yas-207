# Compatibility

The Yamaha protocol reverse-engineering and command opcodes shipped in
`control/control.rb` are:

* Fully reverse-engineered and tested by the upstream author against a
  YAS-207 soundbar.
* Independently reported compatible with the YAS-107 by an upstream user
  (see https://github.com/wejn/yamaha-yas-207/issues/1). The basic
  command set used by this controller (HDMI, ANALOG, BLUETOOTH, TV,
  VOL+/-, POWER OFF) matches both models per that report.

We do **not** claim compatibility with all YAS-xxx soundbars. The
controller is built around the protocol as decoded against the YAS-207
and verified against the YAS-107 only for the basic input/volume/power
opcodes.

## Audio-transport independence

Per the upstream author's design (issue #2:

> "this solution is independent on what you use for audio. As long as
>  you configure your raspi to stream audio to the hdmi port, it
>  should work just fine"

), the controller knows nothing about the audio transport / output
device. It only manages the Yamaha SPP control channel and the
configured Yamaha music input (analog / HDMI / TV / bluetooth). The
player (Shairport Sync, Sendspin, future others) is responsible for
selecting and driving the actual audio output device.

Deployment profiles (see `examples/profiles/`):

| Profile | Player | Audio output | YAS input |
|---|---|---|---|
| `analogue-sendspin.json` | Sendspin | Example ALSA Device (3.5 mm) | analog |
| `shairport-toslink.json` | Shairport Sync | ALSA SPDIF/TOSLINK | tv |
| (illustrative) | any | ALSA HDMI | hdmi |
| (illustrative) | any | HDMI -> TV -> ARC | tv |

Adding a new profile does not require controller code changes; only a
new config file with the appropriate `session.music_intent.input`
value.

## A2DP support

A2DP Bluetooth audio output is **not implemented** in this repository.
No A2DP transport is started by the controller or any adapter shipped
here, and **no config-only flag will enable one**. The controller will
not start, configure, or manage `bluealsa`, `snd-aloop`, `alsaloop`,
or any other Bluetooth audio sink.

The Yamaha core is audio-transport independent and would not need to
change to support A2DP. A future A2DP transport would require a new,
transport-specific adapter (analogous to `yas207-sendspin`) that owns
the BlueALSA / snd-aloop / alsaloop lifecycle, acquires the BlueZ
A2DP sink, and recovers on disconnect. Such an adapter is out of
scope for this branch.
