# Deployment

This directory holds generic systemd unit files for production
persistence of the YAS-207 controller stack on the Pi.

These are **templates** — copy to the correct systemd location on
the Pi and edit the placeholders to match your installation.

## Files

* `systemd/yas207-rfcomm-bind.service` — **system** unit (root). Runs
  once at boot to bind `/dev/rfcomm0` to the YAS-207 Bluetooth SPP
  channel. Required because `rfcomm bind` needs `CAP_NET_ADMIN` and
  must run before any user process tries to open `/dev/rfcomm0`.

* `systemd/yas207-controller.service` — **user** unit (yas207). Runs
  the Ruby controller continuously. Restarts on failure. Holds the
  SPP session; Sendspin hooks invoke the adapter, the adapter
  talks to this controller over HTTP at `127.0.0.1:8000`.

* `systemd/sendspin.service` — **user** unit (yas207). Example Sendspin
  daemon invocation with the three hooks wired to
  `yas207-sendspin`. Adjust the audio-device selection for your
  Pi's actual PortAudio enumeration.

## Runtime directory

The runtime directory `/run/user/<euid>/yas207/` is created by the
controller service on first start (mode 0700, owned by yas207).
It is part of the user systemd runtime (`/run/user/<uid>`), which
is created and managed by `systemd --user` automatically when
`loginctl enable-linger <user>` has been set.

## Install steps

```
# yas207: enable lingering so user services run at boot
sudo loginctl enable-linger yas207

# root: install the rfcomm bind service
sudo cp deployment/systemd/yas207-rfcomm-bind.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable yas207-rfcomm-bind.service

# yas207: install user services
mkdir -p ~/.config/systemd/user
cp deployment/systemd/yas207-controller.service ~/.config/systemd/user/
cp deployment/systemd/sendspin.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable yas207-controller.service sendspin.service
```

## Audio-device selection

The `sendspin.service` example uses `--audio-device "Example ALSA
Headphones"` (durable name). `sendspin daemon --help` accepts
either a device name prefix or a numeric index. For production,
prefer the name.

If the durable name does not resolve at start time, Sendspin will
fail to open the device. Run `sendspin audio-devices list` once
from the target user to confirm.

## Boot-time ordering

```
bluetooth.service
  -> yas207-rfcomm-bind.service (one-shot, waits for BT)
  -> yas207-controller.service (user, persistent)
  -> sendspin.service (user, persistent)
```

## Failure / recovery

* The controller's serial worker retries on `Errno::EIO` (transient
  SPP drop). The user systemd unit restarts the whole controller
  if it exits.
* If the BT link to the YAS-207 is lost AND the rfcomm binding is
  released, a manual `sudo rfcomm bind 0 <MAC> 1` is required.
  Future improvement: a udev rule that rebinds when the BT device
  reappears.
