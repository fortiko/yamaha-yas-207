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

## Future A2DP support

The Yamaha core is audio-transport independent and does **not** prevent
future A2DP support. A2DP is **not** implemented in this repository and
**no A2DP transport is started by the controller or adapters**.

A future A2DP transport would require:

* a transport-specific player/adapter implementation that owns the
  BlueALSA / snd-aloop / alsaloop lifecycle;
* BlueZ A2DP transport acquisition and recovery on disconnect;
* a session-policy adapter similar to `yas207-sendspin` but that
  bridges a BlueALSA PCM to the player;

The Yamaha controller core itself would not need to change. The
controller would continue to manage only the SPP control channel and
the configured `session.music_intent.input = "bluetooth"`.

The earlier experimental A2DP controller in `yas207-ma-controller.py`
on the Pi (BlueALSA + snd-aloop + alsaloop) is a starting point but
its architecture should not be carried into the new fork; a clean A2DP
adapter will be designed separately when A2DP support is revisited.
