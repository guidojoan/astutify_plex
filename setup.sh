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
read -s -p "Ingrese la contraseña de Samba: " SAMBA_PASSWORD
echo ""
read -s -p "Confirme la contraseña de Samba: " SAMBA_PASSWORD_CONFIRM
echo ""

# Verificar que las contraseñas coincidan
if [ "$SAMBA_PASSWORD" != "$SAMBA_PASSWORD_CONFIRM" ]; then
    echo "Error: Las contraseñas no coinciden"
    exit 1
fi

echo ""

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

# Crear directorios necesarios
echo "Creando directorios..."
sudo mkdir -p "$USER_HOME/Docker/{jackett,plex,radarr,sonarr,transmission}/config"
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
