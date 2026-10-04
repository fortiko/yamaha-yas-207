# Deployment

This directory holds generic systemd unit files for persistence of the
YAS-207 controller stack. These are **templates** — adjust the example
LAN IP and HDMI audio-device name to your Quick Start values, then copy
to the systemd locations, reload, and enable.

First get the manual Quick Start in the repo `README.md` working
(controller + `sendspin daemon` + Music Assistant playback). Only then
set up these units for boot-time persistence.

Standard paths assumed below:

- checkout: `~/src/yamaha-yas-207` (`%h/src/yamaha-yas-207` in units)
- controller config: `~/.config/yas207/controller.json`
  (`%h/.config/yas207/controller.json` in units)
- adapter: `/usr/local/sbin/yas207/yas207-sendspin`
- Sendspin binary: `~/.local/bin/sendspin` (`%h/.local/bin/sendspin` in
  units, as installed by `uv tool install sendspin`; run
  `uv tool dir --bin` if your tool bin dir differs and adjust the unit)

## Files

* `systemd/yas207-rfcomm-bind.service` — **system** unit (root).
  Runs once at boot to bind `/dev/rfcomm0` to the YAS-207 Bluetooth
  SPP channel. Required because `rfcomm bind` needs `CAP_NET_ADMIN`
  and the bound device node must exist before the user controller
  tries to open it. Reads `/etc/default/yas207`; see below.

* `systemd/yas207-controller.service` — **user** unit. Runs
  the Ruby controller continuously. Restarts on failure. Holds the
  SPP session; Sendspin hooks invoke the adapter, which talks to
  this controller over HTTP at `127.0.0.1:8000`.

* `systemd/sendspin.service` — **user** unit. Headless Sendspin
  daemon wired to the three YAS-207 hooks. Edit the example
  `--interface` and `--audio-device` to your LAN IP and stable HDMI
  ALSA name from the Quick Start (durable name; not a numeric index);
  uses `--disable-mpris`.

## Boot-time ordering

```
bluetooth.service
  └─► yas207-rfcomm-bind.service   (system, oneshot, RemainAfterExit=yes)
        └─► yas207-controller.service  (user, simple)
              └─► sendspin.service        (user, simple)
```

## Install steps

```sh
# 0. Manual Quick Start works (controller, Sendspin daemon, MA playback).

# 1. Configure the soundbar address for boot-time binding.
sudo tee /etc/default/yas207 >/dev/null <<'EOF'
YAS207_BT_MAC=C8:84:xx:xx:xx:xx
YAS207_RFCOMM_CHANNEL=1
YAS207_RFCOMM_DEV=/dev/rfcomm0
EOF
# Use your address from Quick Start discovery; channel is 1 (SPP)
# unless your setup says otherwise.

# 2. Enable lingering so user services come up at boot without
#    an interactive login.
sudo loginctl enable-linger "$USER"

# 3. Root: install the rfcomm bind service.
sudo cp deployment/systemd/yas207-rfcomm-bind.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yas207-rfcomm-bind.service
# Verify:
rfcomm show 0

# 4. Install user services (from ~/src/yamaha-yas-207).
mkdir -p ~/.config/systemd/user
cp deployment/systemd/yas207-controller.service ~/.config/systemd/user/
cp deployment/systemd/sendspin.service        ~/.config/systemd/user/
# Edit ~/.config/systemd/user/sendspin.service first:
# --interface <your LAN IP> --audio-device "<your HDMI ALSA name>"
systemctl --user daemon-reload
systemctl --user enable --now yas207-controller.service sendspin.service

# 5. Verify
systemctl --user status yas207-controller.service sendspin.service
curl -fsS http://127.0.0.1:8000/state | jq .
journalctl --user -u yas207-controller.service -f
```

## Runtime directory

The runtime directory `/run/user/<euid>/yas207/` is created and
owned by the current user on first controller start
(`FileUtils.mkdir_p` with mode 0700 inside `control/control.rb`). The
directory lives under the per-user systemd runtime path, which
`systemd --user` manages automatically once `loginctl enable-linger`
is in place for that user.

Do NOT set `RuntimeDirectory=yas207` in either user unit — that
would have systemd manage the directory as root and break the user's
writes. The user units grant `ReadWritePaths=/run/user/%U`
(and `%h/.config/sendspin` for Sendspin) so the controller
and adapter can create their snapshot/state/lock files.

## Sendspin hook wiring

Sendspin's daemon runs each hook via
`asyncio.create_subprocess_shell(command, shell=True)` and injects
the event name through the `SENDSPIN_EVENT` environment variable;
positional arguments are only appended for the volume hook, where
the MA percent becomes `argv[1]`. The adapter (`yas207-sendspin`)
dispatches on `SENDSPIN_EVENT`:

```
SENDSPIN_EVENT=start                  → start-session
SENDSPIN_EVENT=stop                   → schedule stop (cleanup handles /stop-session)
SENDSPIN_EVENT=set-volume MA          → apply MA volume (MA in argv[1])
```

So the systemd unit invokes the adapter *without* a subcommand:

```
ExecStart=%h/.local/bin/sendspin daemon \
  --hook-start      /usr/local/sbin/yas207/yas207-sendspin \
  --hook-stop       /usr/local/sbin/yas207/yas207-sendspin \
  --hook-set-volume /usr/local/sbin/yas207/yas207-sendspin
```

`/usr/local/sbin/yas207/yas207-sendspin` is the canonical installed path
of the adapter on the target host:

```sh
sudo install -Dm755 \
  adapters/sendspin/yas207-sendspin \
  /usr/local/sbin/yas207/yas207-sendspin
```

## Failure / recovery

* The controller's serial worker retries on `Errno::EIO` (transient
  SPP drop) and resumes an in-flight restore after a reconnect.
  `systemctl --user status yas207-controller.service` shows the
  live state and `journalctl --user -u yas207-controller.service`
  shows the protocol trace.
* If the BT link to the YAS-207 is lost AND the rfcomm binding is
  released, `systemctl restart yas207-rfcomm-bind.service` re-binds.
* The controller's snapshot is preserved on failure. After any
  crash, the next `/start-session`/`/stop-session` cycle replays the
  pending restore from the snapshot.
