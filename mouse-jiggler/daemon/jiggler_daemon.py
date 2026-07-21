import asyncio
import logging
import os
import random
import signal
from datetime import datetime

from .bt_hid import BluetoothHID
from .config_store import ConfigStore
from .ipc_server import IPCServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("jiggler_daemon")

CONFIG_PATH = os.environ.get("MOUSE_JIGGLER_CONFIG", "/var/lib/mouse-jiggler/config.json")
SOCKET_PATH = os.environ.get("MOUSE_JIGGLER_SOCKET", "/run/mouse-jiggler/daemon.sock")


class JigglerDaemon:
    def __init__(self):
        self.config_store = ConfigStore(CONFIG_PATH)
        state = self.config_store.load()
        self.enabled = state["enabled"]
        self.interval_s = state["interval_s"]
        self.device_name = state["device_name"]
        self.schedule_enabled = state["schedule_enabled"]
        self.start_hour = state["start_hour"]
        self.end_hour = state["end_hour"]
        self.days = state["days"]
        self.bt = BluetoothHID(on_state_change=self._on_bt_state_change)
        self.pairing_state = "idle"
        self._pairing_revert_handle = None
        self._movement_task = None

    def _on_bt_state_change(self, connected, peer):
        self.pairing_state = "paired" if connected else "idle"
        logger.info("Bluetooth state changed: connected=%s peer=%s", connected, peer)

    async def start(self):
        await self.bt.start(device_name=self.device_name)
        self._movement_task = asyncio.create_task(self._movement_loop())
        ipc = IPCServer(SOCKET_PATH, self)
        await ipc.start()
        logger.info("Jiggler daemon ready (enabled=%s interval_s=%s)", self.enabled, self.interval_s)

    async def _movement_loop(self):
        while True:
            await asyncio.sleep(self.interval_s)
            if self.enabled and self.bt.connected and self._in_schedule_window():
                dx = random.choice([-2, -1, 1, 2])
                dy = random.choice([-2, -1, 1, 2])
                self.bt.send_move(dx, dy)
                self.bt.send_move(-dx, -dy)  # return to roughly the same spot
                logger.debug("Sent jiggle move dx=%s dy=%s", dx, dy)

    def _in_schedule_window(self, now=None):
        """True if jiggling should run right now given the weekly schedule.

        Hours are the host's local time. start_hour == end_hour means "all
        day" on the selected days. start_hour > end_hour is an overnight
        window (e.g. 22 -> 6); the day it "belongs to" is the day the window
        started in the evening, so the early-morning tail counts against the
        previous day's selection.
        """
        if not self.schedule_enabled:
            return True
        now = now or datetime.now()
        weekday = now.weekday()
        hour = now.hour
        if self.start_hour == self.end_hour:
            return weekday in self.days
        if self.start_hour < self.end_hour:
            return self.start_hour <= hour < self.end_hour and weekday in self.days
        if hour >= self.start_hour:
            return weekday in self.days
        return hour < self.end_hour and (weekday - 1) % 7 in self.days

    def get_status(self):
        return {
            "enabled": self.enabled,
            "interval_s": self.interval_s,
            "device_name": self.device_name,
            "schedule_enabled": self.schedule_enabled,
            "start_hour": self.start_hour,
            "end_hour": self.end_hour,
            "days": self.days,
            "schedule_active": self._in_schedule_window(),
            "bt_connected": self.bt.connected,
            "bt_peer": self.bt.peer_address,
            "pairing_state": self.pairing_state,
        }

    async def set_config(
        self,
        enabled,
        interval_s,
        device_name=None,
        schedule_enabled=None,
        start_hour=None,
        end_hour=None,
        days=None,
    ):
        self.enabled = bool(enabled)
        self.interval_s = max(5, int(interval_s))
        if device_name is not None:
            device_name = device_name.strip()[:32] or self.device_name
            if device_name != self.device_name:
                self.device_name = device_name
                await self.bt.set_device_name(self.device_name)
        if schedule_enabled is not None:
            self.schedule_enabled = bool(schedule_enabled)
        if start_hour is not None:
            self.start_hour = max(0, min(23, int(start_hour)))
        if end_hour is not None:
            self.end_hour = max(0, min(23, int(end_hour)))
        if days is not None:
            cleaned = sorted({int(d) for d in days if 0 <= int(d) <= 6})
            if cleaned:
                self.days = cleaned
        self.config_store.save(
            self.enabled,
            self.interval_s,
            self.device_name,
            self.schedule_enabled,
            self.start_hour,
            self.end_hour,
            self.days,
        )
        return self.get_status()

    async def start_pairing(self, timeout_s):
        timeout_s = max(10, min(int(timeout_s), 600))
        await self.bt.set_discoverable(True, timeout_s)
        self.pairing_state = "discoverable"
        if self._pairing_revert_handle:
            self._pairing_revert_handle.cancel()
        loop = asyncio.get_running_loop()
        self._pairing_revert_handle = loop.call_later(
            timeout_s, lambda: asyncio.create_task(self._end_pairing_window())
        )
        return timeout_s

    async def _end_pairing_window(self):
        await self.bt.set_discoverable(False)
        if self.pairing_state == "discoverable":
            self.pairing_state = "idle"

    async def unpair(self, address=None):
        address = address or self.bt.peer_address
        if not address:
            return False
        proc = await asyncio.create_subprocess_exec(
            "bluetoothctl",
            "remove",
            address,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        if self.bt.peer_address == address:
            self.bt.reset_connection()
        self.pairing_state = "idle"
        return proc.returncode == 0


async def main():
    daemon = JigglerDaemon()
    await daemon.start()
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)
    await stop_event.wait()


if __name__ == "__main__":
    asyncio.run(main())
