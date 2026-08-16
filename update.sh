#!/bin/bash

# Update script for Astutify Plex
# Pulls the latest Docker images and restarts all services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

echo "===================================="
echo "  Astutify Plex Update"
echo "===================================="
echo ""

# Determine compose file: --novpn flag overrides auto-detection
USE_VPN="n"
if [[ "$1" != "--novpn" ]]; then
    if [ -f "$ENV_FILE" ] && grep -q "^OPENVPN_USER=" "$ENV_FILE"; then
        USE_VPN="y"
    fi
fi

if [ "$USE_VPN" = "y" ]; then
    COMPOSE_FILE="docker-compose.yml"
else
    COMPOSE_FILE="docker-compose.novpn.yml"
fi

echo "Using compose file: $COMPOSE_FILE"
echo ""

cd "$SCRIPT_DIR"

echo "Pulling latest images..."
docker compose -f "$COMPOSE_FILE" pull
echo ""

echo "Restarting services..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
echo ""

echo "Cleaning up unused images..."
docker image prune -f
echo ""

echo "===================================="
echo "  Update complete"
echo "===================================="
echo ""
echo "Check the status of the services:"
echo "  docker ps"
echo ""
