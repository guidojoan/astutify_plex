import asyncio
import json
import os

SOCKET_PATH = os.environ.get("MOUSE_JIGGLER_SOCKET", "/run/mouse-jiggler/daemon.sock")


class DaemonUnavailable(Exception):
    pass


async def call(cmd, timeout=3.0, **kwargs):
    request = {"cmd": cmd, **kwargs}
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(path=SOCKET_PATH), timeout=timeout
        )
    except (FileNotFoundError, ConnectionRefusedError, asyncio.TimeoutError, OSError) as exc:
        raise DaemonUnavailable(str(exc)) from exc

    try:
        writer.write((json.dumps(request) + "\n").encode("utf-8"))
        await writer.drain()
        line = await asyncio.wait_for(reader.readline(), timeout=timeout)
        if not line:
            raise DaemonUnavailable("empty response from daemon")
        return json.loads(line.decode("utf-8"))
    finally:
        writer.close()
