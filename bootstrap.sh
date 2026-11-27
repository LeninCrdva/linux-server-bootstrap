#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

# A valid OpenSSH public key line, used to seed and to verify keys.
SSH_KEY_RE='^[[:space:]]*(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$'

# Prints the normalized, valid key lines contained in a .pub or authorized_keys file.
key_lines() {
  local file=$1 line
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    line=$(printf '%s' "$line" | tr -s '[:space:]' ' ')
    if [[ $line =~ $SSH_KEY_RE ]]; then printf '%s\n' "$line"; fi
  done < "$file"
}

# True if any of the given registries.conf files/dirs already searches docker.io.
has_docker_search() {
  grep -rqs '^[[:space:]]*unqualified-search-registries.*docker\.io' "$@" 2>/dev/null
}

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap.sh [OPTIONS]

Options:
  --admin-user NAME        User with passwordless sudo        (default: admin)
  --rootless-user NAME     Rootless Podman user, no sudo      (default: app)
  --rootless-uid UID       UID for the rootless user           (default: auto)
  --rootless-gid GID       Primary GID for the rootless user  (default: auto)
                           Match these to `user:` in your compose files,
                           e.g. --rootless-uid 1000 --rootless-gid 1000 for
                           `user: "1000:1000"`
  --unprivileged-port-start N
                           Set net.ipv4.ip_unprivileged_port_start=N (persisted)
                           so the rootless user can bind low ports like 80/443
                                                                  (default: 80)
  --ssh-port PORT          Port sshd listens on AND UFW allows (default: 22)
  --ufw-reset              Wipe existing UFW rules and re-apply only SSH
                           (default: keep existing rules when UFW is active)
  --docker-compat          Enable the `docker compose` wrapper (default: off)
  --no-docker-compat       Disable the wrapper explicitly
  --install-packages       Install OS packages with apt       (default: on)
  --no-install-packages    Skip apt; required tools must already exist
  --ssh-key-file PATH      Install SSH public key(s) for the admin user before
                           enabling SSH access (a .pub file or an existing
                           authorized_keys file, e.g. /root/.ssh/authorized_keys)
  --rootless-ssh-key-file PATH
                           Also allow SSH login for the rootless user with this
                           key file (forwarding disabled). By default the rootless
                           user is denied SSH login (DenyUsers). Must be a
                           DIFFERENT key than --ssh-key-file (enforced)
  --env-file PATH          Load extra configuration from a .env-style file
                           (default: ./.env when present)
  --print-config           Print the resolved configuration and exit
  -h, --help               Show this help

Every option also has an environment variable form (ADMIN_USER, ROOTLESS_USER,
SSH_PORT, ENABLE_DOCKER_COMPAT, INSTALL_PACKAGES, SSH_KEY_FILE). Values are
resolved with this priority (highest first):

  1. Command-line arguments
  2. Environment variables
  3. .env file (--env-file PATH, or ./.env in the current directory)
  4. Built-in defaults

Note: sudo strips exported variables, so prefer arguments or the
`sudo VAR=value ./bootstrap.sh` form over plain exports.

Safety: SSH access and the firewall are enabled only when the admin user
already has an SSH public key in ~/.ssh/authorized_keys (or one is supplied
with --ssh-key-file). The script aborts otherwise to avoid locking out the
server. The rootless (non-sudo) user is denied SSH login by default; use
--rootless-ssh-key-file only if it genuinely needs remote access, and with a
key different from the admin's (the script refuses shared keys).
EOF
}

# --- Defaults ---------------------------------------------------------------
DEF_ADMIN_USER=admin
DEF_ROOTLESS_USER=app
DEF_ROOTLESS_UID=''
DEF_ROOTLESS_GID=''
DEF_UNPRIVILEGED_PORT_START=80
DEF_UFW_RESET=false
DEF_SSH_PORT=22
DEF_ENABLE_DOCKER_COMPAT=false
DEF_INSTALL_PACKAGES=true
DEF_SSH_KEY_FILE=''
DEF_ROOTLESS_SSH_KEY_FILE=''

CLI_ADMIN_USER=''
CLI_ROOTLESS_USER=''
CLI_ROOTLESS_UID=''
CLI_ROOTLESS_GID=''
CLI_UNPRIVILEGED_PORT_START=''
CLI_UFW_RESET=''
CLI_SSH_PORT=''
CLI_ENABLE_DOCKER_COMPAT=''
CLI_INSTALL_PACKAGES=''
CLI_SSH_KEY_FILE=''
CLI_ROOTLESS_SSH_KEY_FILE=''
CLI_ENV_FILE=''
CLI_PRINT_CONFIG=false

need_value() { [[ -n ${2:-} ]] || die "Option $1 requires a value"; }

# --- Command-line arguments ---------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --admin-user)            need_value "$1" "${2:-}"; CLI_ADMIN_USER=${2:-}; shift 2 ;;
    --admin-user=*)          CLI_ADMIN_USER=${1#*=}; shift ;;
    --rootless-user)         need_value "$1" "${2:-}"; CLI_ROOTLESS_USER=${2:-}; shift 2 ;;
    --rootless-user=*)       CLI_ROOTLESS_USER=${1#*=}; shift ;;
    --rootless-uid)          need_value "$1" "${2:-}"; CLI_ROOTLESS_UID=${2:-}; shift 2 ;;
    --rootless-uid=*)        CLI_ROOTLESS_UID=${1#*=}; shift ;;
    --rootless-gid)          need_value "$1" "${2:-}"; CLI_ROOTLESS_GID=${2:-}; shift 2 ;;
    --rootless-gid=*)        CLI_ROOTLESS_GID=${1#*=}; shift ;;
    --unprivileged-port-start)    need_value "$1" "${2:-}"; CLI_UNPRIVILEGED_PORT_START=${2:-}; shift 2 ;;
    --unprivileged-port-start=*)  CLI_UNPRIVILEGED_PORT_START=${1#*=}; shift ;;
    --ufw-reset)             CLI_UFW_RESET=true; shift ;;
    --ssh-port)              need_value "$1" "${2:-}"; CLI_SSH_PORT=${2:-}; shift 2 ;;
    --ssh-port=*)            CLI_SSH_PORT=${1#*=}; shift ;;
    --docker-compat|--enable-docker-compat) CLI_ENABLE_DOCKER_COMPAT=true; shift ;;
    --no-docker-compat)      CLI_ENABLE_DOCKER_COMPAT=false; shift ;;
    --install-packages)      CLI_INSTALL_PACKAGES=true; shift ;;
    --no-install-packages)   CLI_INSTALL_PACKAGES=false; shift ;;
    --ssh-key-file)          need_value "$1" "${2:-}"; CLI_SSH_KEY_FILE=${2:-}; shift 2 ;;
    --ssh-key-file=*)        CLI_SSH_KEY_FILE=${1#*=}; shift ;;
    --rootless-ssh-key-file)          need_value "$1" "${2:-}"; CLI_ROOTLESS_SSH_KEY_FILE=${2:-}; shift 2 ;;
    --rootless-ssh-key-file=*)        CLI_ROOTLESS_SSH_KEY_FILE=${1#*=}; shift ;;
    --env-file)              need_value "$1" "${2:-}"; CLI_ENV_FILE=${2:-}; shift 2 ;;
    --env-file=*)            CLI_ENV_FILE=${1#*=}; shift ;;
    --print-config)          CLI_PRINT_CONFIG=true; shift ;;
    -h|--help)               usage; exit 0 ;;
    *)                       die "Unknown option: $1 (try --help)" ;;
  esac
done

# --- .env file ----------------------------------------------------------------
KNOWN_VARS='ADMIN_USER ROOTLESS_USER ROOTLESS_UID ROOTLESS_GID UNPRIVILEGED_PORT_START UFW_RESET SSH_PORT ENABLE_DOCKER_COMPAT INSTALL_PACKAGES SSH_KEY_FILE ROOTLESS_SSH_KEY_FILE'

# Parses KEY=VALUE lines without eval: comments (#) and blank lines are skipped,
# optional surrounding quotes are stripped, unknown keys are ignored.
load_env_file() {
  local file=$1 line key value
  [[ -r $file ]] || die "Cannot read env file: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*($|#) ]] && continue
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}
      value=${BASH_REMATCH[3]}
      value=${value#"${value%%[![:space:]]*}"}
      value=${value%"${value##*[![:space:]]}"}
      case $value in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
      esac
      case " $KNOWN_VARS " in
        *" $key "*) printf -v "FILE_$key" '%s' "$value" ;;
        *) warn "Ignoring unknown variable '$key' in $file" ;;
      esac
    else
      warn "Ignoring malformed line in $file: $line"
    fi
  done < "$file"
}

ENV_FILE=${CLI_ENV_FILE:-}
if [[ -z $ENV_FILE && -r ./.env ]]; then
  ENV_FILE=./.env
fi
if [[ -n $ENV_FILE ]]; then
  load_env_file "$ENV_FILE"
  log "Loaded configuration from $ENV_FILE"
fi

# --- Resolution: CLI args > environment > .env file > defaults ---------------
pick() {
  local name=$1 cli file def
  cli="CLI_$name"; file="FILE_$name"; def="DEF_$name"
  if [[ -n ${!cli:-} ]]; then
    printf '%s' "${!cli}"
  elif [[ -n ${!name:-} ]]; then
    printf '%s' "${!name}"
  elif [[ -n ${!file:-} ]]; then
    printf '%s' "${!file}"
  else
    printf '%s' "${!def}"
  fi
}

ADMIN_USER=$(pick ADMIN_USER)
ROOTLESS_USER=$(pick ROOTLESS_USER)
ROOTLESS_UID=$(pick ROOTLESS_UID)
ROOTLESS_GID=$(pick ROOTLESS_GID)
UNPRIVILEGED_PORT_START=$(pick UNPRIVILEGED_PORT_START)
UFW_RESET=$(pick UFW_RESET)
SSH_PORT=$(pick SSH_PORT)
ENABLE_DOCKER_COMPAT=$(pick ENABLE_DOCKER_COMPAT)
INSTALL_PACKAGES=$(pick INSTALL_PACKAGES)
SSH_KEY_FILE=$(pick SSH_KEY_FILE)
ROOTLESS_SSH_KEY_FILE=$(pick ROOTLESS_SSH_KEY_FILE)

# --- Validation ---------------------------------------------------------------
valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid username: $1"
  [[ ${#1} -le 32 ]] || die "Username is too long: $1"
}
valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}
valid_bool() {
  case $1 in true|false) return 0 ;; *) return 1 ;; esac
}

valid_user "$ADMIN_USER"
valid_user "$ROOTLESS_USER"
[[ "$ADMIN_USER" != "$ROOTLESS_USER" ]] || die 'ADMIN_USER and ROOTLESS_USER must be different'
valid_port "$SSH_PORT" || die "Invalid SSH_PORT: $SSH_PORT"
valid_bool "$ENABLE_DOCKER_COMPAT" || die "ENABLE_DOCKER_COMPAT must be true or false (got: $ENABLE_DOCKER_COMPAT)"
valid_bool "$INSTALL_PACKAGES" || die "INSTALL_PACKAGES must be true or false (got: $INSTALL_PACKAGES)"
valid_id() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 2147483647 ))
}
if [[ -n $ROOTLESS_UID ]]; then
  valid_id "$ROOTLESS_UID" || die "Invalid ROOTLESS_UID: $ROOTLESS_UID"
  (( 10#$ROOTLESS_UID >= 1000 )) || warn 'ROOTLESS_UID below 1000 is normally reserved for system accounts'
fi
if [[ -n $ROOTLESS_GID ]]; then
  valid_id "$ROOTLESS_GID" || die "Invalid ROOTLESS_GID: $ROOTLESS_GID"
fi
valid_port_start() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 0 <= 10#$1 && 10#$1 <= 65535 ))
}
valid_port_start "$UNPRIVILEGED_PORT_START" || die "Invalid UNPRIVILEGED_PORT_START: $UNPRIVILEGED_PORT_START (0-65535)"
valid_bool "$UFW_RESET" || die "UFW_RESET must be true or false (got: $UFW_RESET)"

# The sudo (admin) key and the rootless key must never be the same: the admin
# key grants sudo, so sharing it with the rootless/CI account would defeat the
# separation and let a leaked deploy key escalate to root.
if [[ -n $SSH_KEY_FILE && -n $ROOTLESS_SSH_KEY_FILE ]]; then
  shared=$(comm -12 <(key_lines "$SSH_KEY_FILE" | sort -u) <(key_lines "$ROOTLESS_SSH_KEY_FILE" | sort -u))
  if [[ -n $shared ]]; then
    desc=$(printf '%s\n' "$shared" | head -n1 | awk '{print $1, $3}')
    die "The admin (sudo) key and the rootless key must be different, but '$desc' appears in both $SSH_KEY_FILE and $ROOTLESS_SSH_KEY_FILE. Generate a dedicated key (ssh-keygen -t ed25519 -f ~/.ssh/app_deploy -N '') and pass its .pub via --rootless-ssh-key-file."
  fi
fi

if [[ $CLI_PRINT_CONFIG == true ]]; then
  printf 'ADMIN_USER=%s\n' "$ADMIN_USER"
  printf 'ROOTLESS_USER=%s\n' "$ROOTLESS_USER"
  printf 'ROOTLESS_UID=%s\n' "$ROOTLESS_UID"
  printf 'ROOTLESS_GID=%s\n' "$ROOTLESS_GID"
  printf 'UNPRIVILEGED_PORT_START=%s\n' "$UNPRIVILEGED_PORT_START"
  printf 'UFW_RESET=%s\n' "$UFW_RESET"
  printf 'SSH_PORT=%s\n' "$SSH_PORT"
  printf 'ENABLE_DOCKER_COMPAT=%s\n' "$ENABLE_DOCKER_COMPAT"
  printf 'INSTALL_PACKAGES=%s\n' "$INSTALL_PACKAGES"
  printf 'SSH_KEY_FILE=%s\n' "$SSH_KEY_FILE"
  printf 'ROOTLESS_SSH_KEY_FILE=%s\n' "$ROOTLESS_SSH_KEY_FILE"
  printf 'ENV_FILE=%s\n' "${ENV_FILE:-<none>}"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

[[ $EUID -eq 0 ]] || die 'Run this script as root (for example: sudo ./bootstrap.sh)'
[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable'

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Unsupported distribution: ${ID:-unknown}. Debian and Ubuntu are supported." ;;
esac

# --- Packages -----------------------------------------------------------------
if [[ "$INSTALL_PACKAGES" == true ]]; then
  log 'Updating package indexes'
  apt-get update

  log 'Installing base packages'
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssh-server ufw sudo uidmap slirp4netns fuse-overlayfs \
    libpam-systemd dbus-user-session containers-common

  log 'Installing Podman'
  apt-get install -y --no-install-recommends podman

  log 'Installing podman-compose'
  apt-get install -y --no-install-recommends podman-compose

  log 'Installing netavark + aardvark-dns + pasta (network backend with working container-name DNS)'
  apt-get install -y --no-install-recommends netavark aardvark-dns pasta || \
    warn 'netavark/aardvark-dns/pasta are unavailable on this release; keeping the default network backend (CNI on older releases)'
fi

command -v ufw >/dev/null || die 'UFW is not installed'
command -v podman >/dev/null || die 'Podman is not installed'
command -v sshd >/dev/null || die 'openssh-server is not installed; install it or run with INSTALL_PACKAGES=true so SSH access can be enabled safely'
# Without pam_systemd.so logind cannot open user sessions: user@UID fails with
# "$XDG_RUNTIME_DIR is not set" and rootless Podman falls back to cgroupfs.
[[ -e /usr/lib/security/pam_systemd.so ]] || warn 'libpam-systemd is missing (pam_systemd.so not found); user@UID will fail and rootless Podman will use cgroupfs. Install: apt-get install -y libpam-systemd dbus-user-session (or re-run with INSTALL_PACKAGES=true)'

# Short image names (e.g. dunglas/frankenphp) need unqualified-search-registries;
# with --no-install-recommends the default registries.conf may not define it.
log 'Configuring container registries (short image names, system-wide)'
if ! has_docker_search /etc/containers/registries.conf /etc/containers/registries.conf.d; then
  install -d -m 0755 /etc/containers/registries.conf.d
  printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf.d/00-unqualified-search.conf
  log 'Set unqualified-search-registries=["docker.io"] in /etc/containers/registries.conf.d/00-unqualified-search.conf'
else
  log 'docker.io already in system unqualified-search-registries'
fi

# netavark resolves container names via aardvark-dns; the legacy CNI backend
# (default on older releases) does not without extra plugins.
if command -v netavark >/dev/null 2>&1; then
  log 'Setting netavark as the Podman network backend'
  install -d -m 0755 /etc/containers/containers.conf.d
  printf '[network]\nnetwork_backend = "netavark"\n' > /etc/containers/containers.conf.d/10-netavark.conf
else
  warn 'netavark is not installed; container-name DNS may not resolve with the CNI backend. Install netavark aardvark-dns pasta and set network_backend="netavark" in /etc/containers/containers.conf.d/ (or run scripts/extras.sh --netavark)'
fi

# --- Users --------------------------------------------------------------------
log 'Creating users'
create_user() {
  local user=$1
  if id "$user" >/dev/null 2>&1; then
    warn "User $user already exists; leaving account settings unchanged"
  else
    useradd --create-home --shell /bin/bash "$user"
  fi
}

create_rootless_user() {
  if id "$ROOTLESS_USER" >/dev/null 2>&1; then
    warn "User $ROOTLESS_USER already exists; leaving account settings unchanged"
  else
    local args=()
    if [[ -n $ROOTLESS_UID ]]; then
      local by_uid
      by_uid=$(getent passwd "$ROOTLESS_UID" | cut -d: -f1 || true)
      [[ -z $by_uid ]] || die "UID $ROOTLESS_UID is already used by '$by_uid'. If that is the admin user of this same run, delete the conflicting account first (see README) or pick another UID."
      args+=(-u "$ROOTLESS_UID")
    fi
    if [[ -n $ROOTLESS_GID ]]; then
      local by_gid
      by_gid=$(getent group "$ROOTLESS_GID" | cut -d: -f1 || true)
      [[ -z $by_gid ]] || die "GID $ROOTLESS_GID is already used by group '$by_gid'. Pick another GID or delete the conflicting group."
      # useradd -g requires the group to exist, so create the user's primary
      # group with the requested GID first (unless a group with that name exists).
      if getent group "$ROOTLESS_USER" >/dev/null 2>&1; then
        args+=(-g "$ROOTLESS_USER")
      else
        groupadd -g "$ROOTLESS_GID" "$ROOTLESS_USER"
        args+=(-g "$ROOTLESS_GID")
      fi
    fi
    useradd --create-home --shell /bin/bash ${args[@]+"${args[@]}"} "$ROOTLESS_USER"
  fi
  # UIDs/GIDs of an existing user are not changed in place; warn if they differ.
  if [[ -n $ROOTLESS_UID ]]; then
    local actual_uid
    actual_uid=$(id -u "$ROOTLESS_USER")
    [[ $actual_uid == "$ROOTLESS_UID" ]] || warn "User $ROOTLESS_USER has UID $actual_uid, not the requested $ROOTLESS_UID. To change it, delete and recreate the user (see README) and re-run this script."
  fi
  if [[ -n $ROOTLESS_GID ]]; then
    local actual_gid
    actual_gid=$(id -g "$ROOTLESS_USER")
    [[ $actual_gid == "$ROOTLESS_GID" ]] || warn "User $ROOTLESS_USER has primary GID $actual_gid, not the requested $ROOTLESS_GID. To change it, delete and recreate the user (see README) and re-run this script."
  fi
}

# When a fixed UID/GID is requested for the rootless user, create it FIRST so it
# can claim that ID; the admin user (auto-assigned UID) then takes the next free
# one. Otherwise create the admin first, as before.
if [[ -n $ROOTLESS_UID || -n $ROOTLESS_GID ]]; then
  create_rootless_user
  create_user "$ADMIN_USER"
else
  create_user "$ADMIN_USER"
  create_rootless_user
fi

log 'Configuring passwordless sudo for the administrator'
install -d -m 0750 /etc/sudoers.d
cat > "/etc/sudoers.d/90-${ADMIN_USER}" <<EOF
${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "/etc/sudoers.d/90-${ADMIN_USER}"
visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}" >/dev/null || die 'The generated sudoers file is invalid'

if id "$ROOTLESS_USER" | grep -q 'sudo\|wheel'; then
  warn "Rootless user $ROOTLESS_USER appears to belong to a privileged group"
fi

log 'Enabling linger for rootless Podman services'
# loginctl enable-linger also asks logind to start the user manager (user@UID)
# right away; a plain linger file only takes effect on next login/boot.
if loginctl enable-linger "$ROOTLESS_USER" 2>/dev/null; then
  log "Linger enabled for '$ROOTLESS_USER' via loginctl"
else
  mkdir -p /var/lib/systemd/linger
  touch "/var/lib/systemd/linger/$ROOTLESS_USER"
  chmod 0644 "/var/lib/systemd/linger/$ROOTLESS_USER"
  warn 'loginctl enable-linger failed (is systemd-logind running?); created the linger file directly — it applies on next boot or login'
fi
ROOTLESS_RUNTIME_DIR=/run/user/$(id -u "$ROOTLESS_USER")
# Try to start the user manager right away (works when systemd-logind is running).
systemctl start "user@$(id -u "$ROOTLESS_USER").service" 2>/dev/null || true
if systemctl is-active --quiet "user@$(id -u "$ROOTLESS_USER")" 2>/dev/null; then
  log "User systemd manager for '$ROOTLESS_USER' is running"
else
  warn "User systemd manager for '$ROOTLESS_USER' is not running yet. Start it with: systemctl start user@$(id -u "$ROOTLESS_USER").service (or log in once as '$ROOTLESS_USER' / reboot; linger is already set). Podman will fall back to cgroupfs until then."
  if [[ ! -e /usr/lib/security/pam_systemd.so ]]; then
    warn "pam_systemd.so is missing: install libpam-systemd and dbus-user-session (apt-get install -y libpam-systemd dbus-user-session), then retry: systemctl start user@$(id -u "$ROOTLESS_USER").service"
  fi
fi

# --- SSH access (gated by an existing key) -------------------------------------
user_home() { getent passwd "$1" | cut -d: -f6; }

has_authorized_key() {
  local keyfile
  keyfile="$(user_home "$1")/.ssh/authorized_keys"
  [[ -r $keyfile ]] || return 1
  grep -Eq "$SSH_KEY_RE" "$keyfile"
}

install_authorized_key() {
  local user=$1 keyfile=$2 home line found=0 added=0
  home=$(user_home "$user")
  [[ -r $keyfile ]] || die "Cannot read SSH public key file: $keyfile"
  install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  # Accepts both a single .pub file and a full authorized_keys file:
  # comments, blank lines and invalid lines are skipped.
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    line=$(printf '%s' "$line" | tr -s '[:space:]' ' ')
    [[ $line =~ $SSH_KEY_RE ]] || continue
    found=1
    if ! grep -qxF "$line" "$home/.ssh/authorized_keys"; then
      printf '%s\n' "$line" >> "$home/.ssh/authorized_keys"
      added=1
    fi
  done < "$keyfile"
  (( found )) || die "No valid SSH public key found in: $keyfile"
  chown "$user:$user" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
  (( added )) && log "Installed SSH public key(s) from $keyfile for '$user'"
}

fix_ssh_perms() {
  local user=$1 home
  home=$(user_home "$user")
  [[ -d $home/.ssh ]] && { chown -R "$user:$user" "$home/.ssh"; chmod 0700 "$home/.ssh"; }
  [[ -f $home/.ssh/authorized_keys ]] && { chown "$user:$user" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"; }
}

if [[ -n $SSH_KEY_FILE ]]; then
  log "Seeding SSH public key(s) for '$ADMIN_USER' from $SSH_KEY_FILE"
  install_authorized_key "$ADMIN_USER" "$SSH_KEY_FILE"
fi

log 'Validating SSH access before opening the firewall'
if ! has_authorized_key "$ADMIN_USER"; then
  warn "No SSH public key found for '$ADMIN_USER' in $(user_home "$ADMIN_USER")/.ssh/authorized_keys"
  die "Aborting before enabling SSH/UFW to avoid locking out the server. Add a key first (ssh-copy-id $ADMIN_USER@host, copy one manually, or re-run with --ssh-key-file <pubkey-file-or-authorized_keys>, e.g. /root/.ssh/authorized_keys), then run this script again."
fi
log "SSH public key present for '$ADMIN_USER'"
fix_ssh_perms "$ADMIN_USER"

ssh-keygen -A >/dev/null 2>&1 || true
if sshd -T 2>/dev/null | grep -Eqi '^pubkeyauthentication[[:space:]]+no'; then
  die 'sshd is configured with PubkeyAuthentication no; enable key authentication before running this script'
fi

# SSH_PORT configures BOTH sshd's listening port and the UFW rule, so the two
# can never diverge (a custom port allowed in UFW while sshd still listens on
# 22 would lock out remote access once UFW is enabled).
log "Configuring sshd to listen on port $SSH_PORT"
install -d -m 0755 /etc/ssh/sshd_config.d
printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/50-bootstrap-port.conf
chmod 0644 /etc/ssh/sshd_config.d/50-bootstrap-port.conf

log 'Enabling the SSH service'
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd || die 'Could not enable the SSH service'

# --- Rootless user SSH policy ---------------------------------------------------
# Default: the rootless user is a service account, so it is explicitly denied
# SSH login. With --rootless-ssh-key-file it gets a key instead, hardened with
# forwarding disabled, so it can never be used as a pivot into the server.
SSHD_DROPIN=/etc/ssh/sshd_config.d/60-bootstrap-rootless.conf
ROOTLESS_SSH_DESC='denied (DenyUsers, default)'
install -d -m 0755 /etc/ssh/sshd_config.d
if [[ -n $ROOTLESS_SSH_KEY_FILE ]]; then
  # Also refuse keys that are already authorized for the sudo user, even if
  # they were installed manually (not via --ssh-key-file).
  admin_keys="$(user_home "$ADMIN_USER")/.ssh/authorized_keys"
  shared=$(comm -12 <(key_lines "$admin_keys" | sort -u) <(key_lines "$ROOTLESS_SSH_KEY_FILE" | sort -u))
  if [[ -n $shared ]]; then
    desc=$(printf '%s\n' "$shared" | head -n1 | awk '{print $1, $3}')
    die "The rootless key '$desc' is also authorized for the sudo user '$ADMIN_USER'. Use a dedicated key for the rootless user."
  fi
  log "Installing SSH key(s) for the rootless user '$ROOTLESS_USER' from $ROOTLESS_SSH_KEY_FILE"
  install_authorized_key "$ROOTLESS_USER" "$ROOTLESS_SSH_KEY_FILE"
  has_authorized_key "$ROOTLESS_USER" || die "Failed to install an SSH key for '$ROOTLESS_USER'"
  fix_ssh_perms "$ROOTLESS_USER"
  cat > "$SSHD_DROPIN" <<EOF
# Rootless service account with SSH access: no forwarding of any kind.
Match User $ROOTLESS_USER
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
  ROOTLESS_SSH_DESC="key installed, forwarding disabled (Match User $ROOTLESS_USER)"
  log "SSH login enabled for '$ROOTLESS_USER' with forwarding disabled"
else
  cat > "$SSHD_DROPIN" <<EOF
# The rootless user is a service account: no SSH login.
DenyUsers $ROOTLESS_USER
EOF
  log "SSH login denied for the rootless user '$ROOTLESS_USER' (default)"
fi
chmod 0644 "$SSHD_DROPIN"
sshd -t || die 'The generated sshd configuration is invalid'
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn 'sshd could not be reloaded; the drop-in applies on next restart'

# --- Firewall -------------------------------------------------------------------
log 'Configuring UFW'
ufw_active=false
ufw status 2>/dev/null | grep -q '^Status: active' && ufw_active=true
existing_rules=0
if $ufw_active; then
  existing_rules=$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)
fi
if $ufw_active && (( existing_rules > 0 )) && [[ $UFW_RESET != true ]]; then
  warn "UFW is active with $existing_rules existing rule(s): keeping them and only ensuring SSH ${SSH_PORT}/tcp is allowed. Re-run with --ufw-reset to wipe all rules and re-apply only SSH."
  ufw allow "${SSH_PORT}/tcp" comment 'SSH' 2>/dev/null || true
else
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw --force enable
fi

# --- Rootless Podman -------------------------------------------------------------
log 'Configuring rootless Podman'
log "Allowing the rootless user to bind ports >= $UNPRIVILEGED_PORT_START (net.ipv4.ip_unprivileged_port_start)"
sysctl -w "net.ipv4.ip_unprivileged_port_start=$UNPRIVILEGED_PORT_START" >/dev/null
printf 'net.ipv4.ip_unprivileged_port_start=%s\n' "$UNPRIVILEGED_PORT_START" > /etc/sysctl.d/99-bootstrap-unprivileged-port-start.conf
log "Persisted in /etc/sysctl.d/99-bootstrap-unprivileged-port-start.conf (now: $(sysctl -n net.ipv4.ip_unprivileged_port_start))"
if ! grep -q "^${ROOTLESS_USER}:" /etc/subuid 2>/dev/null; then
  usermod --add-subuids "100000-165535" "$ROOTLESS_USER"
fi
if ! grep -q "^${ROOTLESS_USER}:" /etc/subgid 2>/dev/null; then
  usermod --add-subgids "100000-165535" "$ROOTLESS_USER"
fi

# The per-user ~/.config/containers/registries.conf takes precedence over the
# system one; if it exists without docker.io, short image names break for this
# user. Ensure the rootless user also searches docker.io.
log 'Ensuring docker.io search registry for the rootless user'
user_registries_conf="$(user_home "$ROOTLESS_USER")/.config/containers/registries.conf"
user_registries_d="$(user_home "$ROOTLESS_USER")/.config/containers/registries.conf.d"
if ! has_docker_search "$user_registries_conf" "$user_registries_d"; then
  install -d -m 0755 -o "$ROOTLESS_USER" -g "$ROOTLESS_USER" "$user_registries_d"
  printf 'unqualified-search-registries = ["docker.io"]\n' > "$user_registries_d/00-unqualified-search.conf"
  chown "$ROOTLESS_USER:$ROOTLESS_USER" "$user_registries_d/00-unqualified-search.conf"
  chmod 0644 "$user_registries_d/00-unqualified-search.conf"
  log "Added docker.io to unqualified-search-registries for '$ROOTLESS_USER' ($user_registries_d/00-unqualified-search.conf)"
else
  log "docker.io already in '$ROOTLESS_USER' unqualified-search-registries"
fi

if [[ "$ENABLE_DOCKER_COMPAT" == true ]]; then
  log 'Installing Docker CLI-compatible docker compose wrapper'
  cat > /usr/local/bin/docker <<'EOF'
#!/usr/bin/env bash
# created by linux-server-bootstrap: docker compose -> podman compose wrapper
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
  runuser -u "$ROOTLESS_USER" -- env XDG_RUNTIME_DIR="$ROOTLESS_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$ROOTLESS_RUNTIME_DIR/bus" \
    systemctl --user enable --now podman.socket 2>/dev/null || \
    warn 'The Podman user socket could not be enabled from the installer session; enable it from a login session: systemctl --user enable --now podman.socket'
else
  # Re-run with the flag off: remove only the wrapper this script created.
  if [[ -f /usr/local/bin/docker ]] && grep -q 'created by linux-server-bootstrap' /usr/local/bin/docker; then
    rm -f /usr/local/bin/docker
    log 'Removed the docker compose wrapper (ENABLE_DOCKER_COMPAT=false)'
  fi
  runuser -u "$ROOTLESS_USER" -- env XDG_RUNTIME_DIR="$ROOTLESS_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$ROOTLESS_RUNTIME_DIR/bus" \
    systemctl --user disable podman.socket 2>/dev/null || true
fi

log 'Verifying Podman'
runuser -u "$ROOTLESS_USER" -- env XDG_RUNTIME_DIR="$ROOTLESS_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$ROOTLESS_RUNTIME_DIR/bus" \
  podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || \
  warn "Rootless Podman could not be verified from the installer session (no user runtime at $ROOTLESS_RUNTIME_DIR yet). After the first login/boot of '$ROOTLESS_USER', check with: runuser -u $ROOTLESS_USER -- podman info"

log 'Configuration complete'
printf '\nUsers:\n  sudo: %s\n  rootless: %s (uid=%s, gid=%s)\n\nSSH: enabled, port %s/tcp, key required for %s\nRootless SSH: %s\nUFW: SSH port %s/tcp allowed\nCompose: podman compose; docker compose=%s\n' \
  "$ADMIN_USER" "$ROOTLESS_USER" "$(id -u "$ROOTLESS_USER")" "$(id -g "$ROOTLESS_USER")" "$SSH_PORT" "$ADMIN_USER" "$ROOTLESS_SSH_DESC" "$SSH_PORT" "$ENABLE_DOCKER_COMPAT"
