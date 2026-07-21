import json
import os
from pathlib import Path
from typing import List, Literal, Optional

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from . import cec_client, ipc_client

CONFIG_PATH = os.environ.get("MOUSE_JIGGLER_CONFIG", "/var/lib/mouse-jiggler/config.json")
STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="Mouse Jiggler")


class ConfigUpdate(BaseModel):
    enabled: bool
    interval_s: int = Field(ge=5, le=3600)
    device_name: Optional[str] = Field(default=None, min_length=1, max_length=32)
    schedule_enabled: bool = False
    start_hour: int = Field(default=9, ge=0, le=23)
    end_hour: int = Field(default=17, ge=0, le=23)
    days: List[int] = Field(default_factory=lambda: [0, 1, 2, 3, 4, 5, 6])

    @field_validator("days")
    @classmethod
    def _validate_days(cls, value):
        cleaned = sorted({d for d in value if 0 <= d <= 6})
        if not cleaned:
            raise ValueError("days must contain at least one value between 0 (Mon) and 6 (Sun)")
        return cleaned


class PairRequest(BaseModel):
    timeout_s: int = Field(default=120, ge=10, le=600)


class UnpairRequest(BaseModel):
    address: Optional[str] = None


class CECPowerRequest(BaseModel):
    state: Literal["on", "standby"]


class CECActiveSourceRequest(BaseModel):
    source: Optional[Literal["hdmi1", "hdmi2"]] = None


def _fallback_status():
    try:
        with open(CONFIG_PATH) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = {"enabled": False, "interval_s": 45}
    return {
        "enabled": data.get("enabled", False),
        "interval_s": data.get("interval_s", 45),
        "device_name": data.get("device_name", "Mouse Jiggler"),
        "schedule_enabled": data.get("schedule_enabled", False),
        "start_hour": data.get("start_hour", 9),
        "end_hour": data.get("end_hour", 17),
        "days": data.get("days", [0, 1, 2, 3, 4, 5, 6]),
        "schedule_active": None,
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
        result = await ipc_client.call(
            "set_config",
            enabled=update.enabled,
            interval_s=update.interval_s,
            device_name=update.device_name,
            schedule_enabled=update.schedule_enabled,
            start_hour=update.start_hour,
            end_hour=update.end_hour,
            days=update.days,
        )
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


@app.post("/api/cec/power")
async def cec_power(req: CECPowerRequest):
    try:
        await cec_client.power(req.state)
    except cec_client.CECError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return {"ok": True, "state": req.state}


@app.post("/api/cec/active-source")
async def cec_active_source(req: CECActiveSourceRequest = CECActiveSourceRequest()):
    try:
        await cec_client.set_active_source(req.source)
    except cec_client.CECError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return {"ok": True, "source": req.source or "self"}


app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
