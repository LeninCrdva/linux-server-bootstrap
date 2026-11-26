# Linux Server Bootstrap

A configurable bootstrap script for Debian/Ubuntu servers. It installs and enables SSH (only when a key is already configured, to avoid lockouts), configures UFW, creates two users — one with sudo and one rootless — and installs Podman plus rootless Compose support.

## Features

- Debian and Ubuntu support
- SSH server installed and enabled, with a safety validator: SSH access and the firewall are only enabled if the admin user already has an SSH public key in `~/.ssh/authorized_keys` (or one is provided via `--ssh-key-file`)
- UFW firewall with SSH, optional Docker-compatible socket support
- Two users: a sudo administrator and a rootless Podman user
- Podman installation
- `podman compose` support through `podman-compose`
- `docker compose` compatibility without installing Docker
- Configuration via command-line arguments, environment variables, or a `.env` file

## Quick start

```bash
sudo bash ./bootstrap.sh --ssh-key-file ~/.ssh/id_ed25519.pub
```

(`chmod +x bootstrap.sh` also works if you prefer `sudo ./bootstrap.sh`.)

Keep the current SSH session open while the script runs.

## Step-by-step usage

1. Clone this repository on the server and connect with your current root access (provider console or an existing SSH session). **Do not close that session while the script runs.**
2. Generate an SSH key on your local machine if you don't have one yet:
   ```bash
   ssh-keygen -t ed25519
   ```
3. Preview the configuration that will be applied (nothing is changed):
   ```bash
   bash ./bootstrap.sh --print-config
   bash ./bootstrap.sh --env-file prod.env --print-config   # or edit .env first
   ```
4. Run the bootstrap, passing the admin key (or configure `.env` instead):
   ```bash
   sudo bash ./bootstrap.sh --ssh-key-file ~/.ssh/id_ed25519.pub
   # or: cp .env.example .env && nano .env && sudo bash ./bootstrap.sh
   ```
5. When it finishes, open a **second** SSH session as the admin user and confirm sudo works before closing the original session:
   ```bash
   ssh -i ~/.ssh/id_ed25519 admin@server
   sudo -i
   ```
6. Optional hardening: set `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/50-hardening.conf` and run `sudo systemctl reload ssh`.

## Configuration

Values are resolved with this priority (highest first):

1. Command-line arguments
2. Environment variables
3. `.env` file (`--env-file PATH`, or `./.env` in the current directory when present — see `.env.example`)
4. Built-in defaults

```bash
# Arguments on the command line
sudo ./bootstrap.sh --admin-user ops --rootless-user app --ssh-port 2222

# Environment variables (sudo keeps the VAR=value form shown below)
sudo ADMIN_USER=ops ROOTLESS_USER=app SSH_PORT=2222 ./bootstrap.sh

# .env file
cp .env.example .env   # edit values
sudo ./bootstrap.sh
```

Inspect the resolved configuration without changing anything:

```bash
./bootstrap.sh --print-config
./bootstrap.sh --env-file prod.env --admin-user ops --print-config
```

## Options

| Option | Variable | Default | Purpose |
|---|---|---|---|
| `--admin-user NAME` | `ADMIN_USER` | `admin` | User with passwordless sudo |
| `--rootless-user NAME` | `ROOTLESS_USER` | `app` | Rootless Podman user without sudo |
| `--ssh-port PORT` | `SSH_PORT` | `22` | Port allowed through UFW and used by sshd |
| `--docker-compat` / `--no-docker-compat` | `ENABLE_DOCKER_COMPAT` | `false` | Enable the Docker-compatible wrapper and Podman socket |
| `--install-packages` / `--no-install-packages` | `INSTALL_PACKAGES` | `true` | Install OS packages with apt |
| `--ssh-key-file PATH` | `SSH_KEY_FILE` | _(empty)_ | Public key installed for the admin user before SSH is enabled |
| `--env-file PATH` | — | `./.env` if present | Load extra values from a `.env`-style file |
| `--print-config` | — | — | Print resolved values and exit |
| `-h`, `--help` | — | — | Show usage |

The `.env` parser is safe: it only reads `KEY=VALUE` lines, skips comments and blank lines, strips optional quotes, and ignores unknown keys. It never evaluates the file.

## SSH access and the lockout validator

The script installs and enables `openssh-server` and opens the SSH port in UFW **only after** verifying that the admin user has at least one valid SSH public key in `~/.ssh/authorized_keys` and that sshd does not have `PubkeyAuthentication no`. If the check fails, the script aborts before touching the firewall.

On a fresh server, pass your key explicitly:

```bash
sudo ./bootstrap.sh --ssh-key-file ~/.ssh/id_ed25519.pub
```

or add the key manually beforehand (`ssh-copy-id`, or write it to `~admin/.ssh/authorized_keys` with `0600` permissions and a `0700` `.ssh` directory).

## Requirements

- Debian or Ubuntu
- Run as root (`sudo ./bootstrap.sh`)
- Outbound Internet access (unless `--no-install-packages` is used)
- An SSH key configured for the admin user (or `--ssh-key-file`) — otherwise the script refuses to enable SSH/UFW

## Compose usage

```bash
podman compose up -d
```

Docker-compatible usage when `--docker-compat` is enabled:

```bash
docker compose up -d
```

This does not install Docker. It creates a Podman compatibility wrapper for Compose commands and optionally exposes the Podman socket.

## Security notes

- Keep a second SSH session open after running the script.
- Use SSH key authentication and disable password login after validating access.
- Rootless Podman may require a login session or lingering support for services to run while the user is logged out.
- The script does not expose additional application ports by default.

## FAQ — common errors

| Error / symptom | Cause | Solution |
|---|---|---|
| `[x] Run this script as root` | Not executed as root | Run `sudo bash ./bootstrap.sh ...` |
| `Permission denied` running `./bootstrap.sh` | File is not executable | Use `bash bootstrap.sh` or `chmod +x bootstrap.sh` |
| `[x] Unsupported distribution: ...` | Only Debian/Ubuntu are supported | Run on Debian 11+/12+ or Ubuntu 20.04+ |
| `[x] Unknown option: ...` | Typo in a flag | Check `bash ./bootstrap.sh --help` |
| `[x] Invalid username` / `Invalid SSH_PORT` | Name longer than 32 chars or with invalid characters; port outside 1–65535 | Use `[a-z_][a-z0-9_-]*` names and a valid port |
| `[x] Aborting before enabling SSH/UFW ... Add a key first` | The admin user has no key in `~/.ssh/authorized_keys` | Re-run with `--ssh-key-file ~/.ssh/id_ed25519.pub`, or add the key manually first. This validator is intentional — it prevents lockouts |
| `[x] openssh-server is not installed` | You ran with `--no-install-packages` without sshd | Install `openssh-server` or drop the flag |
| `[x] UFW is not installed` / `Podman is not installed` | Same, missing packages | Install `ufw podman podman-compose` or run without `--no-install-packages` |
| Environment variables seem ignored | `sudo` strips exported variables (`env_reset`) | Use the `sudo VAR=value bash ./bootstrap.sh` form, or pass CLI arguments |
| My `.env` is not applied | `./.env` is read from the directory where you run the script, not from the script's directory | `cd` to the right directory or use `--env-file /path/to/file.env`; confirm with `--print-config` |
| `[!] Ignoring malformed line in .env` / `Ignoring unknown variable` | Line without `KEY=VALUE`, or a key the script doesn't know | Fix the file; valid keys are the ones in `.env.example` |
| `[!] User ... already exists; leaving account settings unchanged` | Informational warning, not an error | The existing account is kept as-is; make sure it has an SSH key before re-running |
| `ssh: connect ... Connection refused` after running | sshd down or UFW blocking | From the provider's out-of-band console: `systemctl status ssh` and `ufw status` |
| I got locked out of the server | UFW enabled without a valid key for the admin | Enter via the provider console (VNC/serial) and run `ufw disable`. This is exactly what the key validator prevents |
| `[!] The Podman user socket could not be enabled ...` | Normal when the rootless user has no login session | As the rootless user: `systemctl --user enable --now podman.socket` (linger is already enabled by the script) |
| `[!] Rootless Podman verification requires a login session ...` | Expected in a non-login session | Verify with an active session: `runuser -u app -- podman info` |
| `docker: command not found` | The wrapper is only installed with `--docker-compat` | Use `podman compose ...`, or re-run with `--docker-compat` |
| `podman compose` fails as rootless | Missing subuid/subgid ranges or no user session | The script assigns subuid/subgid and linger; make sure you have a login session (`loginctl show-user app`) |

## Tests

```bash
bash scripts/test.sh
```

Checks shell syntax, `--help`, rejection of unknown options and invalid values, and the argument > environment > `.env` > default resolution order using `--print-config`.
