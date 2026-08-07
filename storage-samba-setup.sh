#!/bin/bash

# USB disk mounting and Samba share configuration for Astutify Plex.
# Meant to be sourced from setup.sh, which provides CURRENT_USER and OS.

# ===================================
#   USB disk setup
# ===================================
echo ""
echo "===================================="
echo "  USB disk setup"
echo "===================================="

BASE_MEDIA_DIR="/plexmedia"
MOUNTED_FOLDERS=()

while true; do
    mapfile -t USB_DISKS < <(lsblk -dn -o NAME,TRAN | awk '$2=="usb"{print $1}')

    if [ ${#USB_DISKS[@]} -eq 0 ]; then
        echo "No USB disks detected."
        break
    fi

    echo "Detected USB disks:"
    for i in "${!USB_DISKS[@]}"; do
        DISK="${USB_DISKS[$i]}"
        SIZE=$(lsblk -dn -o SIZE "/dev/$DISK")
        MODEL=$(lsblk -dn -o MODEL "/dev/$DISK")
        echo "  [$i] /dev/$DISK - $SIZE - $MODEL"
    done

    printf "Select the number of the disk to mount (leave empty to finish): "
    read -r DISK_INDEX

    if [ -z "$DISK_INDEX" ]; then
        break
    fi

    SELECTED_DISK="${USB_DISKS[$DISK_INDEX]}"

    if [ -z "$SELECTED_DISK" ]; then
        echo "Invalid selection."
        continue
    fi

    mapfile -t PARTITIONS < <(lsblk -ln -o NAME,TYPE "/dev/$SELECTED_DISK" | awk '$2=="part"{print $1}')

    if [ ${#PARTITIONS[@]} -eq 0 ]; then
        SELECTED_PART="$SELECTED_DISK"
    elif [ ${#PARTITIONS[@]} -eq 1 ]; then
        SELECTED_PART="${PARTITIONS[0]}"
    else
        echo "Partitions found on /dev/$SELECTED_DISK:"
        for i in "${!PARTITIONS[@]}"; do
            PART="${PARTITIONS[$i]}"
            SIZE=$(lsblk -dn -o SIZE "/dev/$PART")
            FSTYPE=$(lsblk -dn -o FSTYPE "/dev/$PART")
            echo "  [$i] /dev/$PART - $SIZE - $FSTYPE"
        done
        printf "Select the number of the partition to mount: "
        read -r PART_INDEX
        SELECTED_PART="${PARTITIONS[$PART_INDEX]}"
    fi

    if [ -z "$SELECTED_PART" ]; then
        echo "Invalid selection. Skipping this disk."
        continue
    fi

    DISK_UUID=$(sudo blkid -s UUID -o value "/dev/$SELECTED_PART")
    DISK_FSTYPE=$(sudo blkid -s TYPE -o value "/dev/$SELECTED_PART")

    if [ -z "$DISK_UUID" ]; then
        echo "Error: could not get the UUID of /dev/$SELECTED_PART. Skipping this disk."
        continue
    fi

    DEFAULT_FOLDER_NAME="$SELECTED_PART"
    printf "Enter the folder name for this disk's mount point [%s]: " "$DEFAULT_FOLDER_NAME"
    read -r FOLDER_NAME
    FOLDER_NAME="${FOLDER_NAME:-$DEFAULT_FOLDER_NAME}"

    MOUNT_POINT="$BASE_MEDIA_DIR/$FOLDER_NAME"

    USER_UID=$(id -u "$CURRENT_USER")
    USER_GID=$(id -g "$CURRENT_USER")

    # Install filesystem support if needed
    case "$DISK_FSTYPE" in
        ntfs)
            if ! command -v ntfs-3g &> /dev/null; then
                if [ "$OS" = "debian" ]; then
                    sudo apt-get install -y ntfs-3g
                elif [ "$OS" = "redhat" ]; then
                    sudo yum install -y ntfs-3g
                fi
            fi
            MOUNT_OPTS="defaults,uid=$USER_UID,gid=$USER_GID,dmask=022,fmask=133,nofail"
            ;;
        exfat)
            if ! command -v mount.exfat-fuse &> /dev/null && ! command -v mount.exfat &> /dev/null; then
                if [ "$OS" = "debian" ]; then
                    sudo apt-get install -y exfatprogs exfat-fuse
                elif [ "$OS" = "redhat" ]; then
                    sudo yum install -y exfatprogs
                fi
            fi
            MOUNT_OPTS="defaults,uid=$USER_UID,gid=$USER_GID,nofail"
            ;;
        *)
            MOUNT_OPTS="defaults,nofail"
            ;;
    esac

    echo "Creating mount point $MOUNT_POINT..."
    sudo mkdir -p "$MOUNT_POINT"

    # Back up fstab before modifying it
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%s)"

    if grep -q "$DISK_UUID" /etc/fstab; then
        echo "This disk already has an entry in /etc/fstab."
    else
        echo "Adding entry to /etc/fstab for permanent mounting..."
        sudo bash -c "echo 'UUID=$DISK_UUID  $MOUNT_POINT  $DISK_FSTYPE  $MOUNT_OPTS  0  2' >> /etc/fstab"
    fi

    echo "Mounting $MOUNT_POINT..."
    sudo systemctl daemon-reload
    sudo mount -a

    if [ "$DISK_FSTYPE" != "ntfs" ] && [ "$DISK_FSTYPE" != "exfat" ]; then
        sudo chown "$CURRENT_USER":"$CURRENT_USER" "$MOUNT_POINT"
    fi

    echo "Disk /dev/$SELECTED_PART permanently mounted at $MOUNT_POINT"
    MOUNTED_FOLDERS+=("$FOLDER_NAME")

    echo ""
    printf "Do you want to mount another USB disk? (y/n): "
    read -r MOUNT_ANOTHER
    echo ""
    if [[ ! "$MOUNT_ANOTHER" =~ ^[Yy]$ ]]; then
        break
    fi
done

# ===================================
#   Samba configuration
# ===================================
echo ""
echo "===================================="
echo "  Samba configuration"
echo "===================================="

if [ ${#MOUNTED_FOLDERS[@]} -eq 0 ]; then
    echo "No disks were mounted. Skipping Samba share configuration."
else
    printf "Enter the Samba password for %s: " "$CURRENT_USER"
    stty -echo
    read SAMBA_PASSWORD
    stty echo
    echo ""

    printf "Confirm the Samba password: "
    stty -echo
    read SAMBA_PASSWORD_CONFIRM
    stty echo
    echo ""

    if [ "$SAMBA_PASSWORD" != "$SAMBA_PASSWORD_CONFIRM" ]; then
        echo "Error: passwords do not match"
        exit 1
    fi

    # Install Samba if not already installed
    if ! command -v smbpasswd &> /dev/null; then
        echo "Samba is not installed. Installing..."

        if [ "$OS" = "debian" ]; then
            sudo apt-get update
            sudo apt-get install -y samba samba-common-bin
        elif [ "$OS" = "redhat" ]; then
            sudo yum install -y samba samba-client samba-common
        else
            echo "Error: could not detect the operating system"
            echo "Please install Samba manually"
            exit 1
        fi

        echo "Samba installed successfully"
    else
        echo "Samba is already installed"
    fi

    echo "Configuring Samba..."

    # Verify the system user exists
    if ! id -u "$CURRENT_USER" >/dev/null 2>&1; then
        echo "Error: user $CURRENT_USER does not exist on the system"
        exit 1
    fi

    # Create/update the Samba user and set the password
    echo "Configuring Samba user: $CURRENT_USER"
    (echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | sudo smbpasswd -a "$CURRENT_USER" -s

    # Optional read-only Samba user
    printf "Do you want to configure a read-only Samba user? (y/n): "
    read -r SETUP_READONLY
    echo ""

    READONLY_USER=""
    if [[ "$SETUP_READONLY" =~ ^[Yy]$ ]]; then
        printf "Enter the read-only Samba username: "
        read -r READONLY_USER

        printf "Enter the password for %s: " "$READONLY_USER"
        stty -echo
        read READONLY_PASSWORD
        stty echo
        echo ""

        printf "Confirm the password: "
        stty -echo
        read READONLY_PASSWORD_CONFIRM
        stty echo
        echo ""

        if [ "$READONLY_PASSWORD" != "$READONLY_PASSWORD_CONFIRM" ]; then
            echo "Error: passwords do not match"
            exit 1
        fi

        # Create the system user if it doesn't exist
        if ! id -u "$READONLY_USER" >/dev/null 2>&1; then
            echo "Creating system user: $READONLY_USER"
            sudo useradd -m -s /usr/sbin/nologin "$READONLY_USER"
        fi

        # Create the Samba user with read-only access
        echo "Configuring read-only Samba user: $READONLY_USER"
        (echo "$READONLY_PASSWORD"; echo "$READONLY_PASSWORD") | sudo smbpasswd -a "$READONLY_USER" -s
    fi

    # Configure a Samba share for each mounted disk
    for FOLDER_NAME in "${MOUNTED_FOLDERS[@]}"; do
        MOUNT_POINT="$BASE_MEDIA_DIR/$FOLDER_NAME"

        echo "Configuring Samba share for $MOUNT_POINT..."
        sudo bash -c "cat >> /etc/samba/smb.conf" <<EOF

[$FOLDER_NAME]
   comment = $FOLDER_NAME Media Share
   path = $MOUNT_POINT
   browseable = yes
   read only = no
   guest ok = no
   valid users = $CURRENT_USER
   create mask = 0775
   directory mask = 0775
   force user = $CURRENT_USER
EOF

        if [ -n "$READONLY_USER" ]; then
            echo "Configuring read-only Samba share for $MOUNT_POINT..."
            sudo bash -c "cat >> /etc/samba/smb.conf" <<EOF

[$FOLDER_NAME-ReadOnly]
   comment = $FOLDER_NAME Media Share (Read Only)
   path = $MOUNT_POINT
   browseable = yes
   read only = yes
   guest ok = no
   valid users = $READONLY_USER
   force user = nobody
   force group = nogroup
EOF
        fi
    done

    # Restart the Samba service
    echo "Restarting Samba service..."
    if [ "$OS" = "debian" ]; then
        sudo systemctl restart smbd
        sudo systemctl enable smbd
    elif [ "$OS" = "redhat" ]; then
        sudo systemctl restart smb
        sudo systemctl enable smb
    fi
fi
