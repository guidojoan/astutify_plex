import asyncio
import logging
import os
import random
import signal

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
        self.bt = BluetoothHID(on_state_change=self._on_bt_state_change)
        self.pairing_state = "idle"
        self._pairing_revert_handle = None
        self._movement_task = None

    def _on_bt_state_change(self, connected, peer):
        self.pairing_state = "paired" if connected else "idle"
        logger.info("Bluetooth state changed: connected=%s peer=%s", connected, peer)

    async def start(self):
        await self.bt.start()
        self._movement_task = asyncio.create_task(self._movement_loop())
        ipc = IPCServer(SOCKET_PATH, self)
        await ipc.start()
        logger.info("Jiggler daemon ready (enabled=%s interval_s=%s)", self.enabled, self.interval_s)

    async def _movement_loop(self):
        while True:
            await asyncio.sleep(self.interval_s)
            if self.enabled and self.bt.connected:
                dx = random.choice([-2, -1, 1, 2])
                dy = random.choice([-2, -1, 1, 2])
                self.bt.send_move(dx, dy)
                self.bt.send_move(-dx, -dy)  # return to roughly the same spot
                logger.debug("Sent jiggle move dx=%s dy=%s", dx, dy)

    def get_status(self):
        return {
            "enabled": self.enabled,
            "interval_s": self.interval_s,
            "bt_connected": self.bt.connected,
            "bt_peer": self.bt.peer_address,
            "pairing_state": self.pairing_state,
        }

    def set_config(self, enabled, interval_s):
        self.enabled = bool(enabled)
        self.interval_s = max(5, int(interval_s))
        self.config_store.save(self.enabled, self.interval_s)
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
