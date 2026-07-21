const statusDaemon = document.getElementById("status-daemon");
const statusBt = document.getElementById("status-bt");
const statusPeer = document.getElementById("status-peer");
const statusSchedule = document.getElementById("status-schedule");
const enabledToggle = document.getElementById("enabled-toggle");
const intervalInput = document.getElementById("interval-input");
const deviceNameInput = document.getElementById("device-name-input");
const scheduleEnabledToggle = document.getElementById("schedule-enabled-toggle");
const scheduleFields = document.getElementById("schedule-fields");
const startHourSelect = document.getElementById("start-hour-select");
const endHourSelect = document.getElementById("end-hour-select");
const daysRow = document.getElementById("days-row");
const saveBtn = document.getElementById("save-btn");
const saveStatus = document.getElementById("save-status");
const pairBtn = document.getElementById("pair-btn");
const pairStatus = document.getElementById("pair-status");

const DAY_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

let pairingPollTimer = null;

function formatHour(h) {
  return `${String(h).padStart(2, "0")}:00`;
}

for (let h = 0; h < 24; h++) {
  const opt1 = new Option(formatHour(h), h);
  const opt2 = new Option(formatHour(h), h);
  startHourSelect.add(opt1);
  endHourSelect.add(opt2);
}

DAY_LABELS.forEach((label, idx) => {
  const dayLabel = document.createElement("label");
  dayLabel.className = "day-toggle";
  const cb = document.createElement("input");
  cb.type = "checkbox";
  cb.value = String(idx);
  cb.className = "day-checkbox";
  dayLabel.appendChild(cb);
  dayLabel.appendChild(document.createTextNode(label));
  daysRow.appendChild(dayLabel);
});

function getSelectedDays() {
  return Array.from(document.querySelectorAll(".day-checkbox:checked")).map((cb) => parseInt(cb.value, 10));
}

function setSelectedDays(days) {
  const set = new Set(days || []);
  document.querySelectorAll(".day-checkbox").forEach((cb) => {
    cb.checked = set.has(parseInt(cb.value, 10));
  });
}

function updateScheduleFieldsVisibility() {
  scheduleFields.style.display = scheduleEnabledToggle.checked ? "block" : "none";
}

scheduleEnabledToggle.addEventListener("change", updateScheduleFieldsVisibility);

async function fetchJSON(url, options) {
  const res = await fetch(url, options);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.detail || `${res.status} ${res.statusText}`);
  }
  return data;
}

async function refreshStatus() {
  try {
    const status = await fetchJSON("/api/status");
    statusDaemon.textContent = status.daemon_reachable ? "reachable" : "unreachable";
    statusDaemon.className = status.daemon_reachable ? "ok" : "bad";
    statusBt.textContent = status.bt_connected ? "connected" : "not connected";
    statusBt.className = status.bt_connected ? "ok" : "muted";
    statusPeer.textContent = status.bt_peer || "—";
    if (!status.schedule_enabled) {
      statusSchedule.textContent = "always on";
      statusSchedule.className = "muted";
    } else if (status.schedule_active === null || status.schedule_active === undefined) {
      statusSchedule.textContent = "scheduled";
      statusSchedule.className = "muted";
    } else {
      statusSchedule.textContent = status.schedule_active ? "in window" : "outside window";
      statusSchedule.className = status.schedule_active ? "ok" : "muted";
    }
    if (document.activeElement !== enabledToggle) {
      enabledToggle.checked = !!status.enabled;
    }
    if (document.activeElement !== intervalInput) {
      intervalInput.value = status.interval_s;
    }
    if (document.activeElement !== deviceNameInput) {
      deviceNameInput.value = status.device_name || "";
    }
    if (document.activeElement !== scheduleEnabledToggle) {
      scheduleEnabledToggle.checked = !!status.schedule_enabled;
      updateScheduleFieldsVisibility();
    }
    if (document.activeElement !== startHourSelect) {
      startHourSelect.value = status.start_hour ?? 9;
    }
    if (document.activeElement !== endHourSelect) {
      endHourSelect.value = status.end_hour ?? 17;
    }
    if (document.activeElement === null || document.activeElement.className !== "day-checkbox") {
      setSelectedDays(status.days);
    }
  } catch (err) {
    statusDaemon.textContent = "error";
    statusDaemon.className = "bad";
  }
}

saveBtn.addEventListener("click", async () => {
  const days = getSelectedDays();
  if (days.length === 0) {
    saveStatus.textContent = "Error: select at least one day";
    return;
  }
  saveStatus.textContent = "Saving…";
  try {
    await fetchJSON("/api/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        enabled: enabledToggle.checked,
        interval_s: parseInt(intervalInput.value, 10),
        device_name: deviceNameInput.value.trim() || null,
        schedule_enabled: scheduleEnabledToggle.checked,
        start_hour: parseInt(startHourSelect.value, 10),
        end_hour: parseInt(endHourSelect.value, 10),
        days,
      }),
    });
    saveStatus.textContent = "Saved";
    setTimeout(() => (saveStatus.textContent = ""), 2000);
  } catch (err) {
    saveStatus.textContent = `Error: ${err.message}`;
  }
  refreshStatus();
});

pairBtn.addEventListener("click", async () => {
  pairStatus.textContent = "Starting pairing window…";
  try {
    await fetchJSON("/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ timeout_s: 120 }),
    });
    pairStatus.textContent = "Discoverable — connect from your Mac's Bluetooth settings";
    clearInterval(pairingPollTimer);
    pairingPollTimer = setInterval(async () => {
      const s = await fetchJSON("/api/pairing-status");
      pairStatus.textContent = `Pairing state: ${s.pairing_state}`;
      if (s.pairing_state === "paired" || s.pairing_state === "idle") {
        clearInterval(pairingPollTimer);
      }
    }, 3000);
  } catch (err) {
    pairStatus.textContent = `Error: ${err.message}`;
  }
});

refreshStatus();
setInterval(refreshStatus, 5000);
