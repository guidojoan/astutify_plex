import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_CONFIG = {
    "enabled": False,
    "interval_s": 45,
    "device_name": "Mouse Jiggler",
    "schedule_enabled": False,
    "start_hour": 9,
    "end_hour": 17,
    "days": [0, 1, 2, 3, 4, 5, 6],
}


def _clean_days(days):
    try:
        cleaned = sorted({int(d) for d in days if 0 <= int(d) <= 6})
    except (TypeError, ValueError):
        cleaned = []
    return cleaned or list(DEFAULT_CONFIG["days"])


class ConfigStore:
    """Atomic on-disk store for the enabled/interval/device_name/schedule settings.

    The jiggler daemon is the only writer; the web process only reads this
    file directly as a fallback when the daemon is unreachable.
    """

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def load(self):
        if not self.path.exists():
            return dict(DEFAULT_CONFIG)
        try:
            with open(self.path, "r") as f:
                data = json.load(f)
            return {
                "enabled": bool(data.get("enabled", DEFAULT_CONFIG["enabled"])),
                "interval_s": int(data.get("interval_s", DEFAULT_CONFIG["interval_s"])),
                "device_name": str(data.get("device_name") or DEFAULT_CONFIG["device_name"]),
                "schedule_enabled": bool(data.get("schedule_enabled", DEFAULT_CONFIG["schedule_enabled"])),
                "start_hour": max(0, min(23, int(data.get("start_hour", DEFAULT_CONFIG["start_hour"])))),
                "end_hour": max(0, min(23, int(data.get("end_hour", DEFAULT_CONFIG["end_hour"])))),
                "days": _clean_days(data.get("days", DEFAULT_CONFIG["days"])),
            }
        except (json.JSONDecodeError, OSError, ValueError, TypeError):
            return dict(DEFAULT_CONFIG)

    def save(self, enabled, interval_s, device_name, schedule_enabled, start_hour, end_hour, days):
        data = {
            "enabled": bool(enabled),
            "interval_s": int(interval_s),
            "device_name": str(device_name),
            "schedule_enabled": bool(schedule_enabled),
            "start_hour": int(start_hour),
            "end_hour": int(end_hour),
            "days": _clean_days(days),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        fd, tmp_path = tempfile.mkstemp(dir=self.path.parent, prefix=".config-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, self.path)
        except BaseException:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            raise
        return data
