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

macOS generally expects the *first* pairing to be initiated from its own
Bluetooth settings while the peripheral (the Pi) is discoverable, rather
than the peripheral connecting out — that's why pairing is a manual,
UI-triggered action rather than something the daemon does automatically.

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
