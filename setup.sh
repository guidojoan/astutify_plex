#!/bin/bash

# Setup script for Astutify Plex
# This script mounts disks, configures Samba, and prepares the environment

set -e

echo "===================================="
echo "  Astutify Plex Setup"
echo "===================================="
echo ""

# Get the home directory of the current user
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    CURRENT_USER="$SUDO_USER"
else
    USER_HOME="$HOME"
    CURRENT_USER="$USER"
fi

echo "Working directory: $USER_HOME"
echo "User: $CURRENT_USER"
echo ""

# Ask whether to use a VPN (gluetun) for downloads
printf "Do you want to use a VPN for downloads? (y/n): "
read -r USE_VPN
echo ""

if [[ "$USE_VPN" =~ ^[Yy]$ ]]; then
    USE_VPN="y"

    printf "Enter your OpenVPN username: "
    read OPENVPN_USER
    echo ""

    printf "Enter your OpenVPN password: "
    stty -echo
    read OPENVPN_PASSWORD
    stty echo
    echo ""
else
    USE_VPN="n"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ "$USE_VPN" = "y" ]; then
    echo "Saving configuration..."

    if [ -f "$ENV_FILE" ]; then
        if grep -q "^OPENVPN_USER=" "$ENV_FILE"; then
            sed -i "s|^OPENVPN_USER=.*|OPENVPN_USER=$OPENVPN_USER|" "$ENV_FILE"
        else
            echo "OPENVPN_USER=$OPENVPN_USER" >> "$ENV_FILE"
        fi

        if grep -q "^OPENVPN_PASSWORD=" "$ENV_FILE"; then
            sed -i "s|^OPENVPN_PASSWORD=.*|OPENVPN_PASSWORD=$OPENVPN_PASSWORD|" "$ENV_FILE"
        else
            echo "OPENVPN_PASSWORD=$OPENVPN_PASSWORD" >> "$ENV_FILE"
        fi
    else
        echo "OPENVPN_USER=$OPENVPN_USER" > "$ENV_FILE"
        echo "OPENVPN_PASSWORD=$OPENVPN_PASSWORD" >> "$ENV_FILE"
    fi

    # Make sure .env is not accessible to other users
    chmod 600 "$ENV_FILE"
fi

# Detect the operating system
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
else
    OS="unknown"
fi

# USB disk mounting and Samba share configuration (extracted script)
source "$SCRIPT_DIR/storage-samba-setup.sh"

# Create necessary directories
echo ""
echo "Creating directories..."
sudo mkdir -p "$USER_HOME/Docker/plex/config"
sudo mkdir -p "$USER_HOME/Docker/prowlarr/config"
sudo mkdir -p "$USER_HOME/Docker/radarr/config"
sudo mkdir -p "$USER_HOME/Docker/sonarr/config"
sudo mkdir -p "$USER_HOME/Docker/transmission/config"
sudo mkdir -p "$USER_HOME/Docker/seerr/config"

# Set permissions
echo "Setting permissions..."
sudo chown -R "$CURRENT_USER":$CURRENT_USER "$USER_HOME/Docker"
sudo chmod -R 775 "$USER_HOME/Docker"

echo "Starting services..."

if [ "$USE_VPN" = "y" ]; then
    docker compose up -d
else
    docker compose -f docker-compose.novpn.yml up -d
fi

echo ""
echo "===================================="
echo "  Setup complete"
echo "===================================="
echo ""
echo "Check the status of the services:"
echo "  docker ps"
echo ""
