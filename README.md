# Linux Server Bootstrap

A configurable bootstrap script for Debian/Ubuntu servers. It configures UFW with SSH access, creates two users, and installs Podman plus rootless Compose support.

## Features

- Debian and Ubuntu support
- UFW firewall with SSH, optional TCP port and optional Docker-compatible socket support
- Configurable sudo user and rootless user
- Podman installation
- `podman compose` support through `podman-compose`
- `docker compose` compatibility without installing Docker
- Rootless Podman configuration guidance

## Quick start

```bash
sudo ./bootstrap.sh
```

Override defaults with environment variables:

```bash
sudo ADMIN_USER=ops ROOTLESS_USER=app SSH_PORT=22 ./bootstrap.sh
```

## Requirements

- Debian or Ubuntu
- Run as root
- Outbound Internet access
- SSH access that is kept open while UFW is enabled

## Options

| Variable | Default | Purpose |
|---|---:|---|
| `ADMIN_USER` | `admin` | User with passwordless sudo |
| `ROOTLESS_USER` | `app` | Rootless Podman user without sudo |
| `SSH_PORT` | `22` | Port allowed through UFW |
| `ENABLE_DOCKER_COMPAT` | `false` | Enable Docker-compatible socket and alias setup |
| `INSTALL_PACKAGES` | `true` | Install operating-system packages |

## Compose usage

```bash
podman compose up -d
```

Docker-compatible usage is supported when `ENABLE_DOCKER_COMPAT=true`:

```bash
docker compose up -d
```

This does not install Docker. It creates a Podman compatibility wrapper for Compose commands and optionally exposes the Podman socket.

## Security notes

- Keep a second SSH session open after running the script.
- Use SSH key authentication and disable password login after validating access.
- Rootless Podman may require a login session or lingering support for services to run while the user is logged out.
- The script does not expose additional application ports by default.
