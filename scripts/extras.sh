#!/usr/bin/env bash
set -Eeuo pipefail

# Applies optional "special" settings WITHOUT running the full bootstrap:
# UFW, users and SSH are left untouched. Every step is idempotent.

log() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/extras.sh [OPTIONS]

Options:
  --rootless-user NAME          Rootless user to configure          (default: app)
  --unprivileged-port-start N   Allow rootless binding of ports >= N via
                                net.ipv4.ip_unprivileged_port_start (persisted in
                                /etc/sysctl.d), e.g. 80 for web ports 80/443
  --docker-compat               Install the `docker compose` -> `podman compose`
                                wrapper and enable the rootless Podman API socket
  --registries                  Ensure docker.io is in unqualified-search-registries
                                (system-wide and for the rootless user), so short
                                image names like dunglas/frankenphp resolve
  --all                         All of the above (port start 80)
  -h, --help                    Show this help

Examples:
  sudo bash scripts/extras.sh --all
  sudo bash scripts/extras.sh --unprivileged-port-start 80 --registries
  sudo bash scripts/extras.sh --docker-compat --rootless-user bluesky
EOF
}

ROOTLESS_USER=app
DO_PORT=''
PORT_START=''
DO_DOCKER=false
DO_REGISTRIES=false

need_value() { [[ -n ${2:-} ]] || die "Option $1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --rootless-user)              need_value "$1" "${2:-}"; ROOTLESS_USER=${2:-}; shift 2 ;;
    --rootless-user=*)            ROOTLESS_USER=${1#*=}; shift ;;
    --unprivileged-port-start)    need_value "$1" "${2:-}"; DO_PORT=1; PORT_START=${2:-}; shift 2 ;;
    --unprivileged-port-start=*)  DO_PORT=1; PORT_START=${1#*=}; shift ;;
    --docker-compat)              DO_DOCKER=true; shift ;;
    --registries)                 DO_REGISTRIES=true; shift ;;
    --all)                        DO_PORT=1; PORT_START=80; DO_DOCKER=true; DO_REGISTRIES=true; shift ;;
    -h|--help)                    usage; exit 0 ;;
    *)                            die "Unknown option: $1 (try --help)" ;;
  esac
done

if [[ -z $DO_PORT && $DO_DOCKER == false && $DO_REGISTRIES == false ]]; then
  usage >&2
  die 'Nothing to do: pass --unprivileged-port-start, --docker-compat, --registries or --all'
fi

[[ $EUID -eq 0 ]] || die 'Run as root, e.g.: sudo bash scripts/extras.sh --all'

has_docker_search() {
  grep -rqs '^[[:space:]]*unqualified-search-registries.*docker\.io' "$@" 2>/dev/null
}

if [[ -n $DO_PORT ]]; then
  [[ "$PORT_START" =~ ^[0-9]+$ ]] && (( 0 <= 10#$PORT_START && 10#$PORT_START <= 65535 )) \
    || die "Invalid port start: $PORT_START (0-65535)"
  log "Setting net.ipv4.ip_unprivileged_port_start=$PORT_START"
  sysctl -w "net.ipv4.ip_unprivileged_port_start=$PORT_START" >/dev/null
  printf 'net.ipv4.ip_unprivileged_port_start=%s\n' "$PORT_START" > /etc/sysctl.d/99-bootstrap-unprivileged-port-start.conf
  log "Persisted in /etc/sysctl.d/99-bootstrap-unprivileged-port-start.conf (current: $(sysctl -n net.ipv4.ip_unprivileged_port_start))"
fi

if [[ $DO_REGISTRIES == true ]]; then
  log 'Ensuring docker.io in unqualified-search-registries (system-wide)'
  if ! has_docker_search /etc/containers/registries.conf /etc/containers/registries.conf.d; then
    install -d -m 0755 /etc/containers/registries.conf.d
    printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf.d/00-unqualified-search.conf
    log 'Wrote /etc/containers/registries.conf.d/00-unqualified-search.conf'
  else
    log 'System registries already include docker.io'
  fi
  if id "$ROOTLESS_USER" >/dev/null 2>&1; then
    uhome=$(getent passwd "$ROOTLESS_USER" | cut -d: -f6)
    uconf="$uhome/.config/containers/registries.conf"
    uconfd="$uhome/.config/containers/registries.conf.d"
    if ! has_docker_search "$uconf" "$uconfd"; then
      install -d -m 0755 -o "$ROOTLESS_USER" -g "$ROOTLESS_USER" "$uconfd"
      printf 'unqualified-search-registries = ["docker.io"]\n' > "$uconfd/00-unqualified-search.conf"
      chown "$ROOTLESS_USER:$ROOTLESS_USER" "$uconfd/00-unqualified-search.conf"
      chmod 0644 "$uconfd/00-unqualified-search.conf"
      log "Wrote $uconfd/00-unqualified-search.conf for '$ROOTLESS_USER'"
    else
      log "'$ROOTLESS_USER' registries already include docker.io"
    fi
  else
    warn "User $ROOTLESS_USER does not exist; skipped user-level registries"
  fi
fi

if [[ $DO_DOCKER == true ]]; then
  id "$ROOTLESS_USER" >/dev/null 2>&1 || die "User $ROOTLESS_USER does not exist"
  command -v podman >/dev/null || die 'podman is not installed'
  log 'Installing docker compose -> podman compose wrapper'
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

  log 'Enabling linger and the rootless Podman API socket'
  if ! loginctl enable-linger "$ROOTLESS_USER" 2>/dev/null; then
    mkdir -p /var/lib/systemd/linger
    touch "/var/lib/systemd/linger/$ROOTLESS_USER"
    chmod 0644 "/var/lib/systemd/linger/$ROOTLESS_USER"
  fi
  uid=$(id -u "$ROOTLESS_USER")
  systemctl start "user@$uid.service" 2>/dev/null || true
  rdir=/run/user/$uid
  runuser -u "$ROOTLESS_USER" -- env XDG_RUNTIME_DIR="$rdir" DBUS_SESSION_BUS_ADDRESS="unix:path=$rdir/bus" \
    systemctl --user enable --now podman.socket 2>/dev/null || \
    warn "podman.socket not enabled (user manager not running?). Start it with: systemctl start user@$uid.service, or log in once as $ROOTLESS_USER"
fi

log 'Extras applied'
