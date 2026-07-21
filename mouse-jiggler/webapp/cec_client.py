import asyncio

TV_LOGICAL_ADDRESS = "0"

# CEC only runs over HDMI, so only the monitor's HDMI inputs are
# reachable this way (a DisplayPort input can never be selected via CEC).
# Physical addresses follow the standard HDMI-CEC convention for a device
# plugged directly into sink input N, with no intermediate switch: N.0.0.0.
INPUT_PHYSICAL_ADDRESSES = {
    "hdmi1": "1.0.0.0",
    "hdmi2": "2.0.0.0",
}

_lock = asyncio.Lock()


class CECError(Exception):
    pass


async def _run(commands, timeout=10.0):
    async with _lock:
        try:
            proc = await asyncio.create_subprocess_exec(
                "cec-client",
                "-s",
                "-d",
                "1",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise CECError("cec-client not found — is cec-utils installed?") from exc

        stdin_data = ("\n".join(commands) + "\n").encode("utf-8")
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(stdin_data), timeout=timeout)
        except asyncio.TimeoutError as exc:
            proc.kill()
            await proc.wait()
            raise CECError("cec-client timed out") from exc

        if proc.returncode != 0:
            raise CECError(stderr.decode("utf-8", errors="replace") or "cec-client failed")
        return stdout.decode("utf-8", errors="replace")


async def power(state):
    cmd = "on" if state == "on" else "standby"
    await _run([f"{cmd} {TV_LOGICAL_ADDRESS}"])


async def set_active_source(source=None):
    """Make an HDMI input active on the monitor.

    With no source, claims active source using the Pi's own (real) physical
    address — the monitor switches to whichever port the Pi is plugged
    into. With a named source ("hdmi1"/"hdmi2"), each cec-client invocation
    is a fresh process that auto-detects its real physical address on
    startup, so temporarily overriding it with `pa` before `as` — and then
    exiting — is a self-contained way to claim active source on a *different*
    HDMI port without needing to actually be wired to it.
    """
    if source is None:
        await _run(["as"])
        return
    try:
        physical_address = INPUT_PHYSICAL_ADDRESSES[source]
    except KeyError:
        raise CECError(
            f"unknown source {source!r}; expected one of {sorted(INPUT_PHYSICAL_ADDRESSES)}"
        )
    await _run([f"pa {physical_address}", "as"])
