# Plex Server

### Install

1. Install Git
2. Setup ssh authentication for Git
3. Install docker compose

      Sigue la guía oficial de Docker para Debian:

      https://docs.docker.com/engine/install/debian/

      ### Agregar usuario al grupo `docker`

      Después de instalar Docker, agrega tu usuario al grupo `docker` para poder usar Docker sin `sudo`:

      ```bash
      sudo usermod -aG docker $USER
      newgrp docker
      ```

4. Clone the repo
   ```bash
    git clone git@github.com:guidojoan/astutify_plex.git
    cd asutify_plex
   ```
5. Execute sh setup.sh
6. Install a VPN to protect the connection

### NordVPN

```bash
nordvpn login --token $TOKEN
nordvpn set lan-discovery enable
nordvpn set killswitch on
nordvpn set autoconnect on p2p
nordvpn connect p2p
```

### Verify if all traffic use VPN

```bash
docker exec sonarr curl ifconfig.me
docker exec jackett curl ifconfig.me
docker exec radarr curl ifconfig.me
docker exec qbittorrent curl ifconfig.me

```