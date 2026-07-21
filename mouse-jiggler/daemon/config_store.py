import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_CONFIG = {"enabled": False, "interval_s": 45, "device_name": "Mouse Jiggler"}


class ConfigStore:
    """Atomic on-disk store for the enabled/interval/device_name settings.

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
            }
        except (json.JSONDecodeError, OSError, ValueError):
            return dict(DEFAULT_CONFIG)

    def save(self, enabled, interval_s, device_name):
        data = {
            "enabled": bool(enabled),
            "interval_s": int(interval_s),
            "device_name": str(device_name),
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
