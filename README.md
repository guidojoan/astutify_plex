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

`setup.sh` will mount your disk(s) under `/plexmedia`, set up Samba, and start every service defined in `docker-compose.yml` (with VPN, via `gluetun`) or `docker-compose.novpn.yml` (without VPN), depending on what you answer during the prompts.

## Services

| Service | URL | Notes |
|---|---|---|
| Plex | `http://SERVER_IP:32400/web` | host network |
| Prowlarr | `http://SERVER_IP:9696` | indexer manager |
| Radarr | `http://SERVER_IP:7878` | movies |
| Sonarr | `http://SERVER_IP:8989` | TV shows |
| Seerr | `http://SERVER_IP:5055` | request UI for Plex users |
| Transmission | `http://SERVER_IP:9091` | download client |
| Flaresolverr | `http://SERVER_IP:8191` | Cloudflare bypass, used internally by Prowlarr |

Replace `SERVER_IP` with the LAN IP of the machine running Docker.

## Media folder layout

All the `*arr` apps and Plex share the same host folder, `/plexmedia` (created by `storage-samba-setup.sh`), bind-mounted into every container as `/media`. Each disk you mount ends up as a subfolder there, e.g. `/plexmedia/disk1`, which containers see as `/media/disk1`.

Before configuring the apps, create a consistent layout on the disk, for example:

```
/plexmedia/disk1/movies
/plexmedia/disk1/tv
/plexmedia/disk1/downloads/complete
/plexmedia/disk1/downloads/incomplete
```

Use the exact same paths (`/media/disk1/...`) in every app below. Because every container mounts the same host folder, Sonarr/Radarr can hardlink or atomically move finished downloads straight into the library instead of copying them, and no "remote path mapping" is needed.

## Container networking

- `plex` uses `network_mode: host`, so it's reached directly at the host's IP on port `32400`.
- Every other service (except `transmission` on the VPN profile) sits on the `backend` bridge network and can reach the others by container name, e.g. `http://prowlarr:9696`, `http://sonarr:8989`, `http://radarr:7878`, `http://flaresolverr:8191`.
- `transmission`:
  - `docker-compose.yml` (VPN via `gluetun`): shares gluetun's network namespace (`network_mode: service:gluetun`). Other containers must reach it at `http://gluetun:9091`, **not** `http://transmission:9091`.
  - `docker-compose.novpn.yml`: sits on the `backend` network like everything else, reachable as `http://transmission:9091`.

## Configuring the stack

### 1. Prowlarr (indexers)

1. Add your indexers under **Indexers**.
2. If an indexer needs Cloudflare bypass, go to **Settings → Indexers → FlareSolverr Proxies** and add `http://flaresolverr:8191`, then assign it to the indexer(s) that need it.
3. Go to **Settings → Apps** and add:
   - **Sonarr**: `http://sonarr:8989` + its API key (Sonarr → Settings → General)
   - **Radarr**: `http://radarr:7878` + its API key (Radarr → Settings → General)

   Prowlarr will push its indexers into both apps automatically.

### 2. Sonarr / Radarr

1. **Settings → Media Management → Root Folders**: add `/media/disk1/tv` (Sonarr) or `/media/disk1/movies` (Radarr).
2. **Settings → Download Clients**: add Transmission —
   - Host: `gluetun` (VPN profile) or `transmission` (no-VPN profile)
   - Port: `9091`
   - Category: e.g. `tv` / `movies`
3. Leave **Remote Path Mapping** empty — host and download-client paths already match, since every container mounts the same `/plexmedia` → `/media`.

### 3. Transmission

1. Open the web UI and go to settings.
2. Set the download directory to `/media/disk1/downloads/complete` and the incomplete directory to `/media/disk1/downloads/incomplete`.
3. On the VPN profile, downloads only flow while `gluetun` has an active tunnel — check `docker logs gluetun` if transfers stall.

### 4. Plex

1. Claim the server at `http://SERVER_IP:32400/web`.
2. Add libraries pointing at `/media/disk1/movies` and `/media/disk1/tv` — the same paths used as the Sonarr/Radarr root folders.

### 5. Seerr

1. Open `http://SERVER_IP:5055` and connect it to Plex using the server's **LAN IP** and port `32400` — Plex is on the host network, so `localhost` from inside the Seerr container won't reach it.
2. Add Radarr (`http://radarr:7878`) and Sonarr (`http://sonarr:8989`) as request destinations, pointing at the root folders configured above.