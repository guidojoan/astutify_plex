# Mouse Jiggler

Turns the Raspberry Pi into a Bluetooth HID mouse that pairs with a Mac and
periodically sends a tiny movement to keep it from going to sleep. Configured
(ON/OFF, interval) from a small web UI.

This is **fully independent of the Docker media stack** in this repo — it
runs as native systemd services on the Pi, not in Docker, because Bluetooth
HID emulation needs direct access to BlueZ over D-Bus and the `hci0`
adapter. Nothing in `docker-compose.yml` is touched.

## Architecture

- `daemon/` — `jiggler_daemon.py`, a Python asyncio process that owns the
  Bluetooth HID connection (`bt_hid.py`), the movement loop, and the config
  file (`config_store.py`). It's the only process that talks to BlueZ and
  the only writer of the config file. Exposes a small Unix-socket JSON IPC
  (`ipc_server.py`) at `/run/mouse-jiggler/daemon.sock`.
- `webapp/` — a FastAPI app (`main.py`) serving a REST API plus the static
  frontend (`static/`, plain HTML/CSS/vanilla JS). Talks to the daemon over
  the IPC socket; degrades gracefully (`daemon_reachable: false`) if the
  daemon is down, instead of crashing.
- Two systemd units so the web UI can restart independently without
  dropping the Bluetooth pairing.

## Install

On the Pi, after cloning/pulling this repo:

```bash
cd mouse-jiggler
sudo bash install.sh
```

This installs `bluez`/`python3-venv`, creates a venv, installs both systemd
units, and starts them. To update after a `git pull`, just re-run
`sudo bash install.sh`.

The daemon runs as `root` (needed for raw Bluetooth access). The web service
runs as whichever user invoked `sudo` (i.e. the account that owns this repo
checkout, e.g. `plex`) rather than a separate system account — it needs to
`cd` into this directory to start, and a dedicated system account has no
access to another user's home directory. That user is added to the
`mousejiggler` group so it can read the daemon's IPC socket.

Web UI: `http://<pi-ip>:8090`

## Pairing

1. Open the web UI and click **Pair new device**. The Pi becomes
   discoverable/pairable for 2 minutes.
2. On the Mac: **System Settings → Bluetooth**, find the Pi in the device
   list, click **Connect**. Pairing uses BlueZ's `NoInputNoOutput` agent
   ("Just Works") — no PIN should be required.
3. Once paired, the status card shows `Bluetooth: connected` and the peer
   address. Toggle **Enabled** and set an interval, then **Save**.

## Scheduling

Turn on **Only run on a schedule** in the Jiggle Settings card to restrict
jiggling to a start hour, end hour, and set of weekdays (all times are the
Pi's local clock). A start hour later than the end hour wraps past
midnight (e.g. 22:00 -> 06:00). With the schedule off, jiggling runs
whenever **Enabled** is on, as before. The status card's **Schedule** row
shows `in window` / `outside window` while a schedule is active.

macOS generally expects the *first* pairing to be initiated from its own
Bluetooth settings while the peripheral (the Pi) is discoverable, rather
than the peripheral connecting out — that's why pairing is a manual,
UI-triggered action rather than something the daemon does automatically.

## Renaming the device

The **Device name** field in the web UI sets the Bluetooth adapter's Alias
(what's advertised while scanning/pairing) — by default it's "Mouse
Jiggler", not the Pi's hostname. It only affects *future* pairings: a Mac
that already paired keeps showing whatever name it cached at pairing time.
To see a new name (or the corrected mouse icon, if you paired before this
was fixed), remove the device from the Mac's Bluetooth settings and pair
again.

## HDMI-CEC monitor control

The web app also exposes two API-only endpoints (no UI, meant to be called
from another machine on the LAN — e.g. a script or automation) that send
HDMI-CEC commands out the Pi's HDMI port via `cec-client` (`cec-utils`):

- `POST /api/cec/power` with body `{"state": "on"}` or `{"state": "standby"}`
  — powers the monitor on or puts it into standby.
- `POST /api/cec/active-source` with an optional body `{"source": "hdmi1"}`
  or `{"source": "hdmi2"}` — tells the monitor to switch to that HDMI
  input. With no body (or `{}`), it claims active source using the Pi's
  own real physical address, i.e. switches to whichever port the Pi
  itself is plugged into.

```bash
curl -X POST http://<pi-ip>:8090/api/cec/power \
  -H 'Content-Type: application/json' -d '{"state": "on"}'
curl -X POST http://<pi-ip>:8090/api/cec/active-source \
  -H 'Content-Type: application/json' -d '{"source": "hdmi2"}'
```

Requires the `video` group membership `install.sh` grants the web service
user (for `/dev/cec0` access) and the `cec-utils` package it installs. Both
endpoints return `502` if `cec-client` fails, times out, or isn't
installed — check `cec-client -l` (adapter detected?) and
`echo 'scan' | cec-client -s -d 1` (monitor found on the bus?) first if
they fail. Same no-auth, LAN-only trust model as the rest of this app.

**Input selection specifics (MSI PRO MP275Q, 2× HDMI 2.0b + 1× DisplayPort):**
CEC only runs over HDMI, so the DisplayPort input can never be selected
this way — only `hdmi1`/`hdmi2` (physical addresses `1.0.0.0`/`2.0.0.0`,
the standard HDMI-CEC addressing for a device wired directly into sink
input N) are offered. Switching to a *named* input works by having
`cec-client` temporarily report a spoofed physical address before
claiming active source (`pa <addr>` then `as`) — safe because each API
call spawns a fresh `cec-client` process that re-detects its real address
on the next invocation, so nothing persists across calls. This monitor
advertises CEC support as "MSI Power Link" for one-touch-play/standby;
whether it also honors routing requests to a HDMI port other than the
one currently sending them is unverified — confirm on real hardware
(`journalctl -u mouse-jiggler-web -f` while calling the endpoint) before
relying on it, and treat `hdmi1`/`hdmi2` as a starting guess for which
physical port is which until you've confirmed which one the monitor
actually switches to.

## Known caveats

- **The BlueZ SDP-record and L2CAP-socket plumbing in `daemon/bt_hid.py`
  is the highest-risk part of this design** — it's being iterated on
  against real Pi 5 + Mac hardware. `journalctl -u mouse-jiggler-daemon -f`
  is the first place to look if pairing or reports don't behave as
  expected. One issue already found and fixed this way: BlueZ's stock
  `input` plugin registers the HID (`0x1124`) UUID itself to manage any
  paired HID devices, which collides with our own profile registration
  ("UUID already registered"). `install.sh` disables that plugin via a
  `bluetooth.service` drop-in (`--noplugin=input`) — if you see that error,
  re-run `sudo bash install.sh` to pick it up, or check
  `systemctl cat bluetooth.service` to confirm the override is active.
- This only prevents **idle-triggered** sleep/screen lock — it's the
  software equivalent of nudging a physical mouse. It won't override
  `pmset sleepnow`, a closed lid, or an explicit scheduled sleep on the Mac.
- macOS's Bluetooth HID reconnection behavior (does it auto-reconnect to a
  bonded peripheral after a Pi reboot, without re-pairing?) is version/build
  dependent — verify explicitly rather than assuming it.
- The daemon runs as `root` (needed for raw Bluetooth sockets and adapter
  control) — reasonable for a single-purpose home Pi; a
  capability-based (`CAP_NET_RAW`/`CAP_NET_ADMIN` + D-Bus policy file)
  hardening pass is a possible future improvement, not required for this to
  work.
- No authentication on the web UI — same trust model as the other services
  in this repo (LAN-only, no auth). Don't expose port 8090 to the internet.

## Verification checklist

1. `sudo systemctl status mouse-jiggler-daemon mouse-jiggler-web` — both
   `active (running)`.
2. `bluetoothctl show` — adapter powered on, `Class: 0x0005c0`.
3. `curl http://<pi-ip>:8090/api/status` from another LAN machine returns
   `daemon_reachable: true`.
4. Pair from the Mac's Bluetooth settings as described above; confirm no
   passkey prompt appears (Just Works). If macOS insists on confirming a
   passkey, the agent capability needs to change from `NoInputNoOutput` to
   `DisplayYesNo` in `bt_hid.py`.
5. Enable jiggling with a short interval (e.g. 5s); watch the Mac's cursor
   twitch on schedule; `journalctl -u mouse-jiggler-daemon -f` logs each
   report.
6. Set a short Energy Saver timeout on the Mac; confirm it stays awake with
   jiggling ON and sleeps normally with it OFF, to isolate cause and effect.
7. `sudo reboot` the Pi; confirm both units auto-start and the Mac
   reconnects to the bonded device without re-pairing.
8. `sudo systemctl stop mouse-jiggler-daemon` while the web service stays
   up: `/api/status` should return `503`/`daemon_reachable: false`, not
   crash the API; recovers once the daemon restarts.
9. Change the interval via the UI, restart the daemon, confirm the value
   persisted in `/var/lib/mouse-jiggler/config.json`.
10. `docker ps` — confirm the existing media stack is unaffected.
