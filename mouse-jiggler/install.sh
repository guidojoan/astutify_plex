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

if [ -n "$SUDO_USER" ]; then
    WEB_USER="$SUDO_USER"
else
    WEB_USER="$USER"
fi

echo "==================================="
echo "  Mouse Jiggler - Install"
echo "==================================="
echo ""
echo "Install directory: $SCRIPT_DIR"
echo "Web service user:  $WEB_USER"
echo ""

echo "Installing system dependencies..."
apt-get update
apt-get install -y python3-venv bluez bluez-tools dbus cec-utils

echo "Setting up Python virtual environment..."
python3 -m venv "$SCRIPT_DIR/venv"
"$SCRIPT_DIR/venv/bin/pip" install --upgrade pip
"$SCRIPT_DIR/venv/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"

echo "Creating mousejiggler group..."
getent group mousejiggler >/dev/null || groupadd --system mousejiggler
usermod -aG mousejiggler "$WEB_USER"

# /dev/cec0 is typically owned by root:video — add the web user so it can
# run cec-client (HDMI-CEC) without needing root.
usermod -aG video "$WEB_USER"

# Clean up the old dedicated service account from earlier installs, if present:
# it can never traverse into $WEB_USER's home directory to reach this repo.
if id -u mousejiggler-web >/dev/null 2>&1; then
    echo "Removing obsolete mousejiggler-web system account..."
    userdel mousejiggler-web 2>/dev/null || true
fi

echo "Setting Bluetooth adapter class (peripheral, mouse only)..."
if [ -f /etc/bluetooth/main.conf ]; then
    if grep -q "^Class" /etc/bluetooth/main.conf; then
        sed -i 's|^Class.*|Class = 0x000580|' /etc/bluetooth/main.conf
    else
        sed -i '/^\[General\]/a Class = 0x000580' /etc/bluetooth/main.conf
    fi
fi

echo "Disabling BlueZ's built-in HID 'input' plugin..."
# bluetoothd's stock input plugin already registers the HID (0x1124) UUID to
# manage any paired HID devices itself, which conflicts with our own custom
# HID profile registration ("UUID already registered"). Override the vendor
# unit rather than editing it directly, so this survives package updates.
BLUETOOTHD_PATH="$(systemctl show bluetooth.service -p ExecStart --value | grep -oP '(?<=path=)\S+' | head -n1)"
if [ -z "$BLUETOOTHD_PATH" ]; then
    BLUETOOTHD_PATH="/usr/libexec/bluetooth/bluetoothd"
fi
mkdir -p /etc/systemd/system/bluetooth.service.d
cat > /etc/systemd/system/bluetooth.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=$BLUETOOTHD_PATH --noplugin=input
EOF

echo "Installing systemd units..."
for unit in mouse-jiggler-daemon.service mouse-jiggler-web.service; do
    sed -e "s|__INSTALL_DIR__|$SCRIPT_DIR|g" -e "s|__WEB_USER__|$WEB_USER|g" \
        "systemd/$unit" > "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl restart bluetooth
systemctl enable --now mouse-jiggler-daemon.service
systemctl enable --now mouse-jiggler-web.service
systemctl restart mouse-jiggler-web.service

echo ""
echo "==================================="
echo "  Install complete"
echo "==================================="
echo ""
echo "Web UI:      http://$(hostname -I | awk '{print $1}'):8090"
echo "Daemon logs: journalctl -u mouse-jiggler-daemon -f"
echo "Web logs:    journalctl -u mouse-jiggler-web -f"
echo ""
