# Plex Server

### Install

### Instalar Git

```bash
sudo apt update
sudo apt install git
```

### Instalar Docker

Sigue la guía oficial de Docker para Debian:

https://docs.docker.com/engine/install/debian/

### Agregar usuario al grupo `docker`

Después de instalar Docker, agrega tu usuario al grupo `docker` para poder usar Docker sin `sudo`:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Clone repository

Clone this repository and execute 

```bash
sudo bash setup.sh
```