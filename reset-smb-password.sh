#!/bin/bash

# Reset the password of an existing Samba user for Astutify Plex.
# Lists the configured Samba users and lets you pick one to change its password.

set -e

echo "===================================="
echo "  Reset Samba Password"
echo "===================================="
echo ""

# Verify Samba is installed
if ! command -v pdbedit &> /dev/null || ! command -v smbpasswd &> /dev/null; then
    echo "Error: Samba is not installed on this system."
    exit 1
fi

# Get the list of Samba users
mapfile -t SMB_USERS < <(sudo pdbedit -L | cut -d: -f1)

if [ ${#SMB_USERS[@]} -eq 0 ]; then
    echo "No Samba users are configured on this system."
    exit 1
fi

echo "Available Samba users:"
for i in "${!SMB_USERS[@]}"; do
    echo "  [$i] ${SMB_USERS[$i]}"
done
echo ""

printf "Select the number of the user to reset the password for: "
read -r USER_INDEX

SELECTED_USER="${SMB_USERS[$USER_INDEX]}"

if [ -z "$SELECTED_USER" ]; then
    echo "Error: invalid selection"
    exit 1
fi

echo ""
echo "Selected user: $SELECTED_USER"
echo ""

# Prompt for the new password
printf "Enter the new password for %s: " "$SELECTED_USER"
stty -echo
read NEW_PASSWORD
stty echo
echo ""

printf "Confirm the new password: "
stty -echo
read NEW_PASSWORD_CONFIRM
stty echo
echo ""

if [ "$NEW_PASSWORD" != "$NEW_PASSWORD_CONFIRM" ]; then
    echo "Error: passwords do not match"
    exit 1
fi

if [ -z "$NEW_PASSWORD" ]; then
    echo "Error: password cannot be empty"
    exit 1
fi

# Set the new password
(echo "$NEW_PASSWORD"; echo "$NEW_PASSWORD") | sudo smbpasswd -s "$SELECTED_USER"

echo ""
echo "===================================="
echo "  Password updated successfully"
echo "===================================="
echo "User: $SELECTED_USER"
