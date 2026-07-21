#!/bin/bash
# Installs the Bluetooth Mouse Jiggler as two native systemd services.
# Run from within this directory: sudo bash install.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==================================="
echo "  Mouse Jiggler - Install"
echo "==================================="
echo ""
echo "Install directory: $SCRIPT_DIR"
echo ""

echo "Installing system dependencies..."
apt-get update
apt-get install -y python3-venv bluez bluez-tools dbus

echo "Setting up Python virtual environment..."
python3 -m venv "$SCRIPT_DIR/venv"
"$SCRIPT_DIR/venv/bin/pip" install --upgrade pip
"$SCRIPT_DIR/venv/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"

echo "Creating mousejiggler group and web service user..."
getent group mousejiggler >/dev/null || groupadd --system mousejiggler
id -u mousejiggler-web >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin -g mousejiggler mousejiggler-web

echo "Setting Bluetooth adapter class (peripheral, keyboard+mouse combo)..."
if [ -f /etc/bluetooth/main.conf ] && ! grep -q "^Class" /etc/bluetooth/main.conf; then
    sed -i '/^\[General\]/a Class = 0x0005C0' /etc/bluetooth/main.conf
fi

echo "Installing systemd units..."
for unit in mouse-jiggler-daemon.service mouse-jiggler-web.service; do
    sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "systemd/$unit" > "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl restart bluetooth
systemctl enable --now mouse-jiggler-daemon.service
systemctl enable --now mouse-jiggler-web.service

echo ""
echo "==================================="
echo "  Install complete"
echo "==================================="
echo ""
echo "Web UI:      http://$(hostname -I | awk '{print $1}'):8090"
echo "Daemon logs: journalctl -u mouse-jiggler-daemon -f"
echo "Web logs:    journalctl -u mouse-jiggler-web -f"
echo ""
