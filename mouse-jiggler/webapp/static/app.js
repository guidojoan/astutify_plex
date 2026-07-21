const statusDaemon = document.getElementById("status-daemon");
const statusBt = document.getElementById("status-bt");
const statusPeer = document.getElementById("status-peer");
const enabledToggle = document.getElementById("enabled-toggle");
const intervalInput = document.getElementById("interval-input");
const saveBtn = document.getElementById("save-btn");
const saveStatus = document.getElementById("save-status");
const pairBtn = document.getElementById("pair-btn");
const pairStatus = document.getElementById("pair-status");

let pairingPollTimer = null;

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
    if (document.activeElement !== enabledToggle) {
      enabledToggle.checked = !!status.enabled;
    }
    if (document.activeElement !== intervalInput) {
      intervalInput.value = status.interval_s;
    }
  } catch (err) {
    statusDaemon.textContent = "error";
    statusDaemon.className = "bad";
  }
}

saveBtn.addEventListener("click", async () => {
  saveStatus.textContent = "Saving…";
  try {
    await fetchJSON("/api/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        enabled: enabledToggle.checked,
        interval_s: parseInt(intervalInput.value, 10),
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
