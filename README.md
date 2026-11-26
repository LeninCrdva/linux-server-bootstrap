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
| `--ssh-key-file PATH` | `SSH_KEY_FILE` | _(empty)_ | Public key(s) installed for the admin user before SSH is enabled; accepts a `.pub` file or an existing `authorized_keys` file (e.g. `/root/.ssh/authorized_keys`) |
| `--rootless-ssh-key-file PATH` | `ROOTLESS_SSH_KEY_FILE` | _(empty)_ | Also allow SSH login for the rootless user (key installed, forwarding disabled via a `Match User` block). By default the rootless user is denied SSH (`DenyUsers`). **Must be a different key than `--ssh-key-file` — the script refuses shared keys** |
| `--env-file PATH` | — | `./.env` if present | Load extra values from a `.env`-style file |
| `--print-config` | — | — | Print resolved values and exit |
| `-h`, `--help` | — | — | Show usage |

The `.env` parser is safe: it only reads `KEY=VALUE` lines, skips comments and blank lines, strips optional quotes, and ignores unknown keys. It never evaluates the file.

## SSH access and the lockout validator

The script installs and enables `openssh-server` and opens the SSH port in UFW **only after** verifying that the admin user has at least one valid SSH public key in `~/.ssh/authorized_keys` and that sshd does not have `PubkeyAuthentication no`. If the check fails, the script aborts before touching the firewall.

On a fresh server, pass your key explicitly:

```bash
sudo bash ./bootstrap.sh --ssh-key-file ~/.ssh/id_ed25519.pub
```

You can also reuse a key that already works for another account (for example root's) — only the public part is copied:

```bash
sudo bash ./bootstrap.sh --ssh-key-file /root/.ssh/authorized_keys
```

or add the key manually beforehand (`ssh-copy-id`, or write it to `~admin/.ssh/authorized_keys` with `0600` permissions and a `0700` `.ssh` directory). The private key always stays on your local machine; you log in with `ssh -i ~/.ssh/id_ed25519 admin@server`.

### Rootless user and SSH

SSH access only applies to the admin (sudo) user by default. The rootless user is a service account: it gets no key and is explicitly denied SSH login via `DenyUsers` in `/etc/ssh/sshd_config.d/60-bootstrap-rootless.conf`. That is the recommended posture — it cannot be used as a login or pivot even if someone later sets a password for it.

If the rootless user genuinely needs remote access (e.g. CI deploys running `podman compose`), give it its **own** key, never the admin's. The script **enforces this**: it aborts if the admin (sudo) key and the rootless key share any key line, whether passed via flags or already present in the admin's `authorized_keys`. This matters because the admin key grants sudo — a leaked key shared with the CI/rootless account would escalate straight to root, while separate keys keep each one revocable and rotatable on its own:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/app_id_ed25519   # separate key pair on your machine
scp ~/.ssh/app_id_ed25519.pub root@server:/tmp/
sudo bash ./bootstrap.sh --rootless-ssh-key-file /tmp/app_id_ed25519.pub
```

In that case the script installs the key for the rootless user and replaces the `DenyUsers` line with a hardening block that disables all forwarding (`AllowTcpForwarding no`, `AllowAgentForwarding no`, `X11Forwarding no`, `PermitTunnel no`), so the account can run workloads but cannot tunnel into the server. It still has no sudo.

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

## CI/CD (GitHub Actions)

Use SSH **key** authentication for automation — never passwords. Put the private key in GitHub Secrets and install the public key for the rootless user:

```bash
# on your machine: dedicated deploy key (never reuse the admin key)
ssh-keygen -t ed25519 -f ~/.ssh/app_deploy -N ''
scp ~/.ssh/app_deploy.pub root@server:/tmp/

# on the server
sudo bash ./bootstrap.sh --ssh-key-file /root/.ssh/authorized_keys \
  --rootless-ssh-key-file /tmp/app_deploy.pub
```

In GitHub: Settings → Secrets and variables → Actions → add `DEPLOY_HOST`, `DEPLOY_USER` (`app`) and `DEPLOY_SSH_KEY` (the contents of `~/.ssh/app_deploy`).

```yaml
name: deploy
on: [push]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.DEPLOY_SSH_KEY }}
      - name: Restart services as the rootless user
        run: |
          ssh -o StrictHostKeyChecking=accept-new \
            ${{ secrets.DEPLOY_USER }}@${{ secrets.DEPLOY_HOST }} \
            'cd /srv/app && podman compose pull && podman compose up -d'
```

(Any SSH action works the same way, e.g. `appleboy/ssh-action` with `host`/`username`/`key`.)

Caveats:

- The rootless account has forwarding disabled by the `Match User` block, so `ssh -L/-D` tunnels will **not** work. If the workflow must reach a service port, allow it in UFW or use a reverse proxy — do not rely on SSH port forwarding.
- The rootless user has no sudo: CI can only run rootless Podman commands, which is exactly the intended blast radius.
- Use `StrictHostKeyChecking=accept-new` (or pre-seed `known_hosts` with `ssh-keyscan`) so the workflow never blocks on an interactive prompt.
- Rotate by generating a new key pair, updating `DEPLOY_SSH_KEY`, and re-running the bootstrap with the new `--rootless-ssh-key-file`.

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
| `[x] Aborting before enabling SSH/UFW ... Add a key first` | The admin user has no key in `~/.ssh/authorized_keys` | Re-run with `--ssh-key-file ~/.ssh/id_ed25519.pub` (or `--ssh-key-file /root/.ssh/authorized_keys` to reuse root's key), or add the key manually first. This validator is intentional — it prevents lockouts |
| Can I reuse the SSH key root already has? | Yes. The public key is meant to be shared | `sudo bash ./bootstrap.sh --ssh-key-file /root/.ssh/authorized_keys`, or manually: `install -d -m 0700 -o admin -g admin ~admin/.ssh && cp /root/.ssh/authorized_keys ~admin/.ssh/authorized_keys && chown admin:admin ~admin/.ssh/authorized_keys && chmod 0600 ~admin/.ssh/authorized_keys` |
| How do I create a new SSH key? | You need a key pair on your local machine | On your local machine: `ssh-keygen -t ed25519`, then `scp ~/.ssh/id_ed25519.pub root@server:/tmp/` and re-run with `--ssh-key-file /tmp/id_ed25519.pub`. The `.pub` file is public and safe to copy; the private key never leaves your machine |
| Can the rootless user log in over SSH? | No by default — it is a service account (`DenyUsers`) | Only if you pass `--rootless-ssh-key-file`, and then with its own key and forwarding disabled (`Match User` hardening) |
| Can I use the same key for the admin and the rootless user? | No — the script aborts if both share any key line | The admin key grants sudo, so a shared key would let a leaked deploy/CI key escalate to root. Generate a dedicated pair: `ssh-keygen -t ed25519 -f ~/.ssh/app_deploy -N ''` and pass its `.pub` via `--rootless-ssh-key-file` |
| Is it wrong to give the rootless user SSH? | Not wrong, but it must be deliberate and hardened | Least privilege says no SSH for service accounts; if needed, use a dedicated key + the `Match User` restrictions the script applies automatically |
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
