#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_USER=${ADMIN_USER:-admin}
ROOTLESS_USER=${ROOTLESS_USER:-app}
SSH_PORT=${SSH_PORT:-22}
ENABLE_DOCKER_COMPAT=${ENABLE_DOCKER_COMPAT:-false}
INSTALL_PACKAGES=${INSTALL_PACKAGES:-true}

export DEBIAN_FRONTEND=noninteractive

log() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die 'Run this script as root (for example: sudo ./bootstrap.sh)'
[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable'

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Unsupported distribution: ${ID:-unknown}. Debian and Ubuntu are supported." ;;
esac

valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid username: $1"
  [[ ${#1} -le 32 ]] || die "Username is too long: $1"
}
valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_user "$ADMIN_USER"
valid_user "$ROOTLESS_USER"
[[ "$ADMIN_USER" != "$ROOTLESS_USER" ]] || die 'ADMIN_USER and ROOTLESS_USER must be different'
valid_port "$SSH_PORT" || die "Invalid SSH_PORT: $SSH_PORT"

log 'Updating package indexes'
if [[ "$INSTALL_PACKAGES" == true ]]; then
  apt-get update

  log 'Installing base packages'
  apt-get install -y --no-install-recommends \
    ca-certificates curl ufw sudo uidmap slirp4netns fuse-overlayfs

  log 'Installing Podman'
  apt-get install -y --no-install-recommends podman

  log 'Installing podman-compose'
  apt-get install -y --no-install-recommends podman-compose
fi

command -v ufw >/dev/null || die 'UFW is not installed'
command -v podman >/dev/null || die 'Podman is not installed'

log 'Creating users'
create_user() {
  local user=$1
  if id "$user" >/dev/null 2>&1; then
    warn "User $user already exists; leaving account settings unchanged"
  else
    useradd --create-home --shell /bin/bash "$user"
  fi
}

create_user "$ADMIN_USER"
create_user "$ROOTLESS_USER"

log 'Configuring sudo access for the administrator'
install -d -m 0750 /etc/sudoers.d
cat > "/etc/sudoers.d/90-${ADMIN_USER}" <<EOF
${ADMIN_USER} ALL=(ALL:ALL) ALL
EOF
chmod 0440 "/etc/sudoers.d/90-${ADMIN_USER}"

if id "$ROOTLESS_USER" | grep -q 'sudo\|wheel'; then
  warn "Rootless user $ROOTLESS_USER appears to belong to a privileged group"
fi

log 'Enabling linger for rootless Podman services'
mkdir -p /var/lib/systemd/linger
ln -sfn /dev/null "/var/lib/systemd/linger/$ROOTLESS_USER"
# Remove the no-op link: linger is enabled by touching an empty regular file.
rm -f "/var/lib/systemd/linger/$ROOTLESS_USER"
touch "/var/lib/systemd/linger/$ROOTLESS_USER"
chmod 0644 "/var/lib/systemd/linger/$ROOTLESS_USER"

log 'Configuring UFW'
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw --force enable

log 'Configuring rootless Podman'
cat > "/etc/subuid".tmp <<EOF
EOF
if ! grep -q "^${ROOTLESS_USER}:" /etc/subuid 2>/dev/null; then
  usermod --add-subuids "100000-165535" "$ROOTLESS_USER"
fi
if ! grep -q "^${ROOTLESS_USER}:" /etc/subgid 2>/dev/null; then
  usermod --add-subgids "100000-165535" "$ROOTLESS_USER"
fi
rm -f /etc/subuid.tmp

if [[ "$ENABLE_DOCKER_COMPAT" == true ]]; then
  log 'Installing Docker CLI-compatible docker compose wrapper'
  cat > /usr/local/bin/docker <<'EOF'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == "compose" ]]; then
  shift
  exec podman compose "$@"
fi
printf 'This server exposes only Docker-compatible "docker compose" commands. Docker itself is not installed.\n' >&2
exit 64
EOF
  chmod 0755 /usr/local/bin/docker

  log 'Enabling the rootless-compatible Podman API socket'
  runuser -u "$ROOTLESS_USER" -- systemctl --user enable --now podman.socket 2>/dev/null || \
    warn 'The Podman user socket could not be enabled from the installer session; the user should enable it from a login session'
fi

log 'Verifying Podman'
runuser -u "$ROOTLESS_USER" -- podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || \
  warn 'Rootless Podman verification requires a login session with a valid user runtime directory'

log 'Configuration complete'
printf '\nUsers:\n  sudo: %s\n  rootless: %s\n\nUFW: SSH port %s/tcp allowed\nCompose: podman compose; docker compose=%s\n' \
  "$ADMIN_USER" "$ROOTLESS_USER" "$SSH_PORT" "$ENABLE_DOCKER_COMPAT"
