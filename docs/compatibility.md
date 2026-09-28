# Compatibility

The Yamaha protocol reverse-engineering and command opcodes shipped in
`control/control.rb` are:

* Fully reverse-engineered and tested by the upstream author against a
  YAS-207 soundbar.
* Independently reported compatible with the YAS-107 by an upstream
  user (see https://github.com/wejn/yamaha-yas-207/issues/1). The
  basic command set used by this controller (HDMI, ANALOG, BLUETOOTH,
  TV, VOL+/-, POWER OFF) matches both models per that report.

We do **not** claim compatibility with all YAS-xxx soundbars. The
expanded controller/session behaviour (configuration loading,
staged restore, session snapshots) has only been exercised against a
YAS-207.

## Audio-transport independence

Per the upstream author's design (issue #2):

> "this solution is independent on what you use for audio. As long as
>  you configure your raspi to stream audio to the hdmi port, it
>  should work just fine"

The controller knows nothing about the audio transport / output
device. It only manages the Yamaha SPP control channel and the
configured Yamaha music input (analog / HDMI / TV / bluetooth). The
player (Shairport Sync, Sendspin, future others) is responsible for
selecting and driving the actual audio output device.

| Player | Audio output | YAS input |
|---|---|---|
| Shairport Sync | ALSA SPDIF/TOSLINK | tv |
| Shairport Sync | ALSA HDMI | hdmi |
| Sendspin | 3.5 mm analogue | analog |
| any | HDMI → TV → ARC | tv |

Adding a new audio transport does not require controller code
changes; only a new config profile with the appropriate
`session.music_intent.input` value.

## Validation scope

The configuration schema, staged session restore, /state endpoint,
and persistent session snapshot have all been exercised end-to-end
against a real YAS-207 soundbar over SPP. The audio-transport and
player-side behaviour described above is not part of the controller
and is not validated here.
