import json
import os
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import ipc_client

CONFIG_PATH = os.environ.get("MOUSE_JIGGLER_CONFIG", "/var/lib/mouse-jiggler/config.json")
STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="Mouse Jiggler")


class ConfigUpdate(BaseModel):
    enabled: bool
    interval_s: int = Field(ge=5, le=3600)


class PairRequest(BaseModel):
    timeout_s: int = Field(default=120, ge=10, le=600)


class UnpairRequest(BaseModel):
    address: Optional[str] = None


def _fallback_status():
    try:
        with open(CONFIG_PATH) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = {"enabled": False, "interval_s": 45}
    return {
        "enabled": data.get("enabled", False),
        "interval_s": data.get("interval_s", 45),
        "bt_connected": False,
        "bt_peer": None,
        "pairing_state": "unknown",
        "daemon_reachable": False,
    }


@app.get("/api/status")
async def get_status():
    try:
        result = await ipc_client.call("get_status")
    except ipc_client.DaemonUnavailable:
        return _fallback_status()
    result.pop("ok", None)
    result["daemon_reachable"] = True
    return result


@app.put("/api/config")
async def set_config(update: ConfigUpdate):
    try:
        result = await ipc_client.call("set_config", enabled=update.enabled, interval_s=update.interval_s)
    except ipc_client.DaemonUnavailable:
        raise HTTPException(status_code=503, detail="daemon unreachable")
    result.pop("ok", None)
    result["daemon_reachable"] = True
    return result


@app.post("/api/pair")
async def pair(req: PairRequest):
    try:
        result = await ipc_client.call("pair", timeout_s=req.timeout_s)
    except ipc_client.DaemonUnavailable:
        raise HTTPException(status_code=503, detail="daemon unreachable")
    result.pop("ok", None)
    return result


@app.post("/api/unpair")
async def unpair(req: UnpairRequest):
    try:
        result = await ipc_client.call("unpair", address=req.address)
    except ipc_client.DaemonUnavailable:
        raise HTTPException(status_code=503, detail="daemon unreachable")
    return result


@app.get("/api/pairing-status")
async def pairing_status():
    try:
        result = await ipc_client.call("get_status")
    except ipc_client.DaemonUnavailable:
        return {"pairing_state": "unknown", "daemon_reachable": False}
    return {"pairing_state": result.get("pairing_state", "unknown"), "daemon_reachable": True}


app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
