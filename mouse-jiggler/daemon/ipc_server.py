import asyncio
import json
import logging
import os

logger = logging.getLogger("ipc_server")


class IPCServer:
    """Line-delimited JSON protocol over a Unix domain socket. The daemon is
    the only writer of on-disk config; this is how the web process reads and
    mutates state."""

    def __init__(self, socket_path, daemon):
        self.socket_path = socket_path
        self.daemon = daemon

    async def start(self):
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)
        server = await asyncio.start_unix_server(self._handle_client, path=self.socket_path)
        os.chmod(self.socket_path, 0o660)
        logger.info("IPC socket listening at %s", self.socket_path)
        asyncio.create_task(server.serve_forever())

    async def _handle_client(self, reader, writer):
        try:
            line = await reader.readline()
            if not line:
                return
            request = json.loads(line.decode("utf-8"))
            response = await self._dispatch(request)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            response = {"ok": False, "error": f"bad request: {exc}"}
        except Exception as exc:  # keep the daemon alive regardless of client-side errors
            logger.exception("IPC handler error")
            response = {"ok": False, "error": str(exc)}
        try:
            writer.write((json.dumps(response) + "\n").encode("utf-8"))
            await writer.drain()
        finally:
            writer.close()

    async def _dispatch(self, request):
        cmd = request.get("cmd")
        if cmd == "get_status":
            return {"ok": True, **self.daemon.get_status()}
        if cmd == "set_config":
            status = await self.daemon.set_config(
                request["enabled"], request["interval_s"], request.get("device_name")
            )
            return {"ok": True, **status}
        if cmd == "pair":
            timeout_s = await self.daemon.start_pairing(request.get("timeout_s", 120))
            return {"ok": True, "pairing_state": self.daemon.pairing_state, "timeout_s": timeout_s}
        if cmd == "unpair":
            ok = await self.daemon.unpair(request.get("address"))
            return {"ok": ok}
        return {"ok": False, "error": f"unknown command: {cmd}"}
