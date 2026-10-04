# Deployment

This directory holds generic systemd unit files for production
persistence of the YAS-207 controller stack on the Pi. These are
**templates** — copy to the right systemd location on the Pi, run
`systemctl daemon-reload`, and `enable --now` the units.

## Files

* `systemd/yas207-rfcomm-bind.service` — **system** unit (root).
  Runs once at boot to bind `/dev/rfcomm0` to the YAS-207 Bluetooth
  SPP channel. Required because `rfcomm bind` needs `CAP_NET_ADMIN`
  and the bound device node must exist before the user controller
  tries to open it.

* `systemd/yas207-controller.service` — **user** unit (yas207). Runs
  the Ruby controller continuously. Restarts on failure. Holds the
  SPP session; Sendspin hooks invoke the adapter, which talks to
  this controller over HTTP at `127.0.0.1:8000`.

* `systemd/sendspin.service` — **user** unit (yas207). Headless Sendspin
  daemon wired to the three YAS-207 hooks. Uses `--audio-device
  "Example ALSA Device"` (durable name; not a numeric index) and
  `--disable-mpris`.

## Boot-time ordering

```
bluetooth.service
  └─► yas207-rfcomm-bind.service   (system, oneshot, RemainAfterExit=yes)
        └─► yas207-controller.service  (user, simple)
              └─► sendspin.service        (user, simple)
```

## Install steps

```
# 1. yas207: enable lingering so user services come up at boot without
#    an interactive login.
sudo loginctl enable-linger yas207

# 2. root: install the rfcomm bind service.
sudo cp deployment/systemd/yas207-rfcomm-bind.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yas207-rfcomm-bind.service
# Verify:
rfcomm show 0
# Expected: "rfcomm0: 02:0A:0B:0C:0D:0E channel 1 connected [tty-attached]"

# 3. yas207: install user services.
mkdir -p ~/.config/systemd/user
cp deployment/systemd/yas207-controller.service ~/.config/systemd/user/
cp deployment/systemd/sendspin.service        ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now yas207-controller.service sendspin.service

# 4. Verify
systemctl --user status yas207-controller.service sendspin.service
curl -fsS http://127.0.0.1:8000/state | jq .
journalctl --user -u yas207-controller.service -f
```

## Runtime directory

The runtime directory `/run/user/<euid>/yas207/` is created and
owned by `yas207` on first controller start (`FileUtils.mkdir_p` with
mode 0700 inside `control/control.rb`). The directory lives under
the per-user systemd runtime path, which `systemd --user` manages
automatically once `loginctl enable-linger yas207` is in place.

Do NOT set `RuntimeDirectory=yas207` in either user unit — that
would have systemd manage the directory as root and break `yas207`'s
writes. The user units must grant `ReadWritePaths=/run/user/%U`
(and `/home/yas207/.config/sendspin` for Sendspin) so the controller
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
ExecStart=.../sendspin daemon \
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
