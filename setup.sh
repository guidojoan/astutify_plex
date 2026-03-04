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

# Crear directorios necesarios
echo "Creando directorios..."
sudo mkdir -p "$USER_HOME/Docker/jackett/config"
sudo mkdir -p "$USER_HOME/Docker/plex/config"
sudo mkdir -p "$USER_HOME/Docker/radarr/config"
sudo mkdir -p "$USER_HOME/Docker/sonarr/config"
sudo mkdir -p "$USER_HOME/Docker/qbittorrent/config"
sudo mkdir -p /media

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
