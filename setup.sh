#!/bin/bash

# Script de configuración para Astutify Plex
# Este script configura Samba y prepara el entorno

set -e

echo "==================================="
echo "  Configuración de Astutify Plex"
echo "==================================="
echo ""

# Obtener el directorio home del usuario actual
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    CURRENT_USER="$SUDO_USER"
else
    USER_HOME="$HOME"
    CURRENT_USER="$USER"
fi

echo "Directorio de trabajo: $USER_HOME"
echo "Usuario: $CURRENT_USER"
echo ""

# Solicitar contraseña de Samba (sin mostrarla en pantalla)
printf "Ingrese la contraseña de Samba: "
stty -echo
read SAMBA_PASSWORD
stty echo
echo ""

printf "Confirme la contraseña de Samba: "
stty -echo
read SAMBA_PASSWORD_CONFIRM
stty echo
echo ""


# Verificar que las contraseñas coincidan
if [ "$SAMBA_PASSWORD" != "$SAMBA_PASSWORD_CONFIRM" ]; then
    echo "Error: Las contraseñas no coinciden"
    exit 1
fi

echo ""

# Solicitar credenciales de OpenVPN
printf "Ingrese su usuario de OpenVPN: "
read OPENVPN_USER
echo ""

printf "Ingrese su password de OpenVPN: "
stty -echo
read OPENVPN_PASSWORD
stty echo
echo ""

# Guardar las credenciales en archivo .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

echo "Guardando configuración..."

# Crear o actualizar archivo .env
if [ -f "$ENV_FILE" ]; then
    # Si existe, actualizar las líneas de OpenVPN
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
    # Crear nuevo archivo .env
    echo "OPENVPN_USER=$OPENVPN_USER" > "$ENV_FILE"
    echo "OPENVPN_PASSWORD=$OPENVPN_PASSWORD" >> "$ENV_FILE"
fi

# Asegurar que .env no sea accesible a otros usuarios
chmod 600 "$ENV_FILE"

# Detectar el sistema operativo
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
else
    OS="unknown"
fi

# Instalar Samba si no está instalado
if ! command -v smbpasswd &> /dev/null; then
    echo "Samba no está instalado. Instalando..."
    
    if [ "$OS" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y samba samba-common-bin
    elif [ "$OS" = "redhat" ]; then
        sudo yum install -y samba samba-client samba-common
    else
        echo "Error: No se pudo detectar el sistema operativo"
        echo "Por favor, instale Samba manualmente"
        exit 1
    fi
    
    echo "Samba instalado correctamente"
else
    echo "Samba ya está instalado"
fi

echo "Configurando Samba..."

# Verificar que el usuario del sistema existe
if ! id -u "$CURRENT_USER" >/dev/null 2>&1; then
    echo "Error: El usuario $CURRENT_USER no existe en el sistema"
    exit 1
fi

# Crear o actualizar el usuario de Samba y establecer la contraseña
echo "Configurando usuario de Samba: $CURRENT_USER"
(echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | sudo smbpasswd -a "$CURRENT_USER" -s

# Configurar el recurso compartido de Samba para /media
echo "Configurando recurso compartido de Samba..."
sudo bash -c "cat >> /etc/samba/smb.conf" <<EOF

[Plex-Admin]
   comment = Media Share
   path = /media
   browseable = yes
   read only = no
   guest ok = no
   valid users = $CURRENT_USER
   create mask = 0775
   directory mask = 0775
   force user = $CURRENT_USER
EOF

echo ""
printf "Ingrese el nombre del usuario de Samba de solo lectura: "
read -r READONLY_USER

printf "Ingrese la contraseña para $READONLY_USER: "
stty -echo
read READONLY_PASSWORD
stty echo
echo ""

printf "Confirme la contraseña: "
stty -echo
read READONLY_PASSWORD_CONFIRM
stty echo
echo ""

if [ "$READONLY_PASSWORD" != "$READONLY_PASSWORD_CONFIRM" ]; then
    echo "Error: Las contraseñas no coinciden"
    exit 1
fi

# Crear el usuario del sistema si no existe
if ! id -u "$READONLY_USER" >/dev/null 2>&1; then
    echo "Creando usuario del sistema: $READONLY_USER"
    sudo useradd -m -s /usr/sbin/nologin "$READONLY_USER"
fi

# Crear el usuario de Samba con acceso de solo lectura
echo "Configurando usuario de Samba de solo lectura: $READONLY_USER"
(echo "$READONLY_PASSWORD"; echo "$READONLY_PASSWORD") | sudo smbpasswd -a "$READONLY_USER" -s

# Configurar el recurso compartido de Samba para acceso de solo lectura
echo "Configurando recurso compartido de solo lectura..."
sudo bash -c "cat >> /etc/samba/smb.conf" <<EOF

[Plex]
   comment = Media Share (Read Only)
   path = /media
   browseable = yes
   read only = yes
   guest ok = no
   valid users = $READONLY_USER
   force user = nobody
   force group = nogroup
EOF

# Reiniciar el servicio de Samba
echo "Reiniciando servicio de Samba..."
if [ "$OS" = "debian" ]; then
    sudo systemctl restart smbd
    sudo systemctl enable smbd
elif [ "$OS" = "redhat" ]; then
    sudo systemctl restart smb
    sudo systemctl enable smb
fi

# Seleccionar disco USB y montarlo permanentemente en /plexmedia
echo ""
echo "==================================="
echo "  Configuración de disco USB"
echo "==================================="

mapfile -t USB_DISKS < <(lsblk -dn -o NAME,TRAN | awk '$2=="usb"{print $1}')

if [ ${#USB_DISKS[@]} -eq 0 ]; then
    echo "No se detectó ningún disco USB conectado. Omitiendo montaje de /plexmedia."
else
    echo "Discos USB detectados:"
    for i in "${!USB_DISKS[@]}"; do
        DISK="${USB_DISKS[$i]}"
        SIZE=$(lsblk -dn -o SIZE "/dev/$DISK")
        MODEL=$(lsblk -dn -o MODEL "/dev/$DISK")
        echo "  [$i] /dev/$DISK - $SIZE - $MODEL"
    done

    printf "Seleccione el número del disco a montar en /plexmedia: "
    read -r DISK_INDEX
    SELECTED_DISK="${USB_DISKS[$DISK_INDEX]}"

    if [ -z "$SELECTED_DISK" ]; then
        echo "Selección inválida. Omitiendo montaje de /plexmedia."
    else
        mapfile -t PARTITIONS < <(lsblk -ln -o NAME,TYPE "/dev/$SELECTED_DISK" | awk '$2=="part"{print $1}')

        if [ ${#PARTITIONS[@]} -eq 0 ]; then
            SELECTED_PART="$SELECTED_DISK"
        elif [ ${#PARTITIONS[@]} -eq 1 ]; then
            SELECTED_PART="${PARTITIONS[0]}"
        else
            echo "Particiones encontradas en /dev/$SELECTED_DISK:"
            for i in "${!PARTITIONS[@]}"; do
                PART="${PARTITIONS[$i]}"
                SIZE=$(lsblk -dn -o SIZE "/dev/$PART")
                FSTYPE=$(lsblk -dn -o FSTYPE "/dev/$PART")
                echo "  [$i] /dev/$PART - $SIZE - $FSTYPE"
            done
            printf "Seleccione el número de la partición a montar en /plexmedia: "
            read -r PART_INDEX
            SELECTED_PART="${PARTITIONS[$PART_INDEX]}"
        fi

        if [ -z "$SELECTED_PART" ]; then
            echo "Selección inválida. Omitiendo montaje de /plexmedia."
        else
            DISK_UUID=$(sudo blkid -s UUID -o value "/dev/$SELECTED_PART")
            DISK_FSTYPE=$(sudo blkid -s TYPE -o value "/dev/$SELECTED_PART")

            if [ -z "$DISK_UUID" ]; then
                echo "Error: No se pudo obtener el UUID de /dev/$SELECTED_PART"
            else
                USER_UID=$(id -u "$CURRENT_USER")
                USER_GID=$(id -g "$CURRENT_USER")

                # Instalar soporte del sistema de archivos si es necesario
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

                echo "Creando punto de montaje /plexmedia..."
                sudo mkdir -p /plexmedia

                # Respaldar fstab antes de modificarlo
                sudo cp /etc/fstab "/etc/fstab.bak.$(date +%s)"

                if grep -q "$DISK_UUID" /etc/fstab; then
                    echo "El disco ya tiene una entrada en /etc/fstab"
                else
                    echo "Agregando entrada a /etc/fstab para montaje permanente..."
                    sudo bash -c "echo 'UUID=$DISK_UUID  /plexmedia  $DISK_FSTYPE  $MOUNT_OPTS  0  2' >> /etc/fstab"
                fi

                echo "Montando /plexmedia..."
                sudo systemctl daemon-reload
                sudo mount -a

                if [ "$DISK_FSTYPE" != "ntfs" ] && [ "$DISK_FSTYPE" != "exfat" ]; then
                    sudo chown "$CURRENT_USER":"$CURRENT_USER" /plexmedia
                fi

                echo "Disco /dev/$SELECTED_PART montado permanentemente en /plexmedia"
            fi
        fi
    fi
fi

# Crear directorios necesarios
echo "Creando directorios..."
sudo mkdir -p "$USER_HOME/Docker/jackett/config"
sudo mkdir -p "$USER_HOME/Docker/plex/config"
sudo mkdir -p "$USER_HOME/Docker/radarr/config"
sudo mkdir -p "$USER_HOME/Docker/sonarr/config"
sudo mkdir -p "$USER_HOME/Docker/transmission/config"
sudo mkdir -p "$USER_HOME/Docker/seerr/config"

# Establecer permisos
echo "Configurando permisos..."
sudo chown -R "$CURRENT_USER":$CURRENT_USER "$USER_HOME/Docker"
sudo chmod -R 775 "$USER_HOME/Docker"
sudo chown -R "$CURRENT_USER":$CURRENT_USER /media
sudo chmod -R 775 /media

echo "Iniciando servicios..."

docker compose up -d

echo ""
echo "==================================="
echo "  Configuración completada"
echo "==================================="
echo ""
echo "Verificar estado de los servicios:"
echo "  docker ps"
echo ""
