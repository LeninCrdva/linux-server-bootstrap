#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bootstrap="$script_dir/../bootstrap.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$bootstrap"
bash -n "$script_dir/extras.sh"
printf 'Shell syntax is valid (bootstrap.sh and extras.sh).\n'

help_out=$(bash "$bootstrap" --help)
for opt in --admin-user --rootless-user --rootless-uid --rootless-gid --unprivileged-port-start --ssh-port --ufw-reset --no-sudo --docker-compat --ssh-key-file --rootless-ssh-key-file --env-file --print-config; do
  [[ $help_out == *"$opt"* ]] || fail "--help output is missing $opt"
done
printf -- '--help lists all expected options.\n'

if bash "$bootstrap" --definitely-not-an-option >/dev/null 2>&1; then
  fail 'unknown option was accepted'
fi
printf 'Unknown options are rejected.\n'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/.env" <<'EOF'
# comment line
ADMIN_USER=ops
SSH_PORT=2222
ENABLE_DOCKER_COMPAT=true
ROOTLESS_SSH_KEY_FILE=/root/.ssh/authorized_keys
MALFORMED LINE WITHOUT EQUALS
UNKNOWN_VAR=ignored
EOF

# .env file values are picked up when no args/env override them
out=$(cd "$tmp" && bash "$bootstrap" --print-config)
[[ $out == *'ADMIN_USER=ops'* ]] || fail ".env ADMIN_USER not applied: $out"
[[ $out == *'SSH_PORT=2222'* ]] || fail ".env SSH_PORT not applied: $out"
[[ $out == *'ENABLE_DOCKER_COMPAT=true'* ]] || fail ".env ENABLE_DOCKER_COMPAT not applied: $out"
[[ $out == *'ROOTLESS_USER=app'* ]] || fail 'default ROOTLESS_USER missing'
[[ $out == *'ROOTLESS_SSH_KEY_FILE=/root/.ssh/authorized_keys'* ]] || fail ".env ROOTLESS_SSH_KEY_FILE not applied: $out"
printf '.env file values and defaults resolve correctly.\n'

# environment variables beat the .env file
out=$(cd "$tmp" && ADMIN_USER=envadmin bash "$bootstrap" --print-config)
[[ $out == *'ADMIN_USER=envadmin'* ]] || fail "environment did not override .env: $out"
printf 'Environment variables override the .env file.\n'

# command-line arguments beat environment variables and the .env file
out=$(cd "$tmp" && ADMIN_USER=envadmin bash "$bootstrap" --print-config --admin-user cliadmin --ssh-port 2200)
[[ $out == *'ADMIN_USER=cliadmin'* ]] || fail "argument did not override environment: $out"
[[ $out == *'SSH_PORT=2200'* ]] || fail "--ssh-port did not override .env: $out"
printf 'Command-line arguments override environment and .env.\n'

# --env-file beats the implicit ./.env
cat > "$tmp/other.env" <<'EOF'
ADMIN_USER=other
EOF
out=$(cd "$tmp" && bash "$bootstrap" --print-config --env-file "$tmp/other.env")
[[ $out == *'ADMIN_USER=other'* ]] || fail "--env-file not honored: $out"
[[ $out != *'SSH_PORT=2222'* ]] || fail '--env-file should replace ./.env, not merge it'
printf -- '--env-file replaces the implicit ./.env.\n'

# invalid values are rejected before any change is made
if bash "$bootstrap" --print-config --ssh-port 70000 >/dev/null 2>&1; then
  fail 'invalid SSH port was accepted'
fi
if bash "$bootstrap" --print-config --admin-user 'Bad User' >/dev/null 2>&1; then
  fail 'invalid username was accepted'
fi
printf 'Invalid usernames and ports are rejected.\n'

# the admin (sudo) key and the rootless key must be different
key_a="$tmp/key_a.pub"
key_b="$tmp/key_b.pub"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI keyA\n' > "$key_a"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI keyB\n' > "$key_b"
cp "$key_a" "$tmp/key_same.pub"
if bash "$bootstrap" --print-config --ssh-key-file "$key_a" --rootless-ssh-key-file "$tmp/key_same.pub" >/dev/null 2>&1; then
  fail 'identical admin/rootless keys were accepted'
fi
printf 'Identical admin/rootless SSH keys are rejected.\n'
out=$(bash "$bootstrap" --print-config --ssh-key-file "$key_a" --rootless-ssh-key-file "$key_b")
[[ $out == *"ROOTLESS_SSH_KEY_FILE=$key_b"* ]] || fail "distinct rootless key not accepted: $out"
printf 'Distinct admin/rootless SSH keys are accepted.\n'

# rootless UID/GID options resolve and validate
out=$(bash "$bootstrap" --print-config --rootless-uid 1000 --rootless-gid 1000)
[[ $out == *'ROOTLESS_UID=1000'* && $out == *'ROOTLESS_GID=1000'* ]] || fail "rootless uid/gid not applied: $out"
printf 'Rootless UID/GID options resolve correctly.\n'
if bash "$bootstrap" --print-config --rootless-uid abc >/dev/null 2>&1; then
  fail 'invalid ROOTLESS_UID was accepted'
fi
if bash "$bootstrap" --print-config --rootless-uid 0 >/dev/null 2>&1; then
  fail 'ROOTLESS_UID=0 was accepted'
fi
printf 'Invalid rootless UID/GID values are rejected.\n'

# unprivileged port start option resolves and validates
out=$(bash "$bootstrap" --print-config --unprivileged-port-start 80)
[[ $out == *'UNPRIVILEGED_PORT_START=80'* ]] || fail "UNPRIVILEGED_PORT_START not applied: $out"
[[ $(bash "$bootstrap" --print-config) == *'UNPRIVILEGED_PORT_START=80'* ]] || fail 'default UNPRIVILEGED_PORT_START should be 80'
if bash "$bootstrap" --print-config --unprivileged-port-start 99999 >/dev/null 2>&1; then
  fail 'invalid UNPRIVILEGED_PORT_START was accepted'
fi
printf 'UNPRIVILEGED_PORT_START resolves, defaults to 80 and validates.\n'

# UFW_RESET defaults to false (existing rules are kept unless explicitly reset)
[[ $(bash "$bootstrap" --print-config) == *'UFW_RESET=false'* ]] || fail 'default UFW_RESET should be false'
out=$(bash "$bootstrap" --print-config --ufw-reset)
[[ $out == *'UFW_RESET=true'* ]] || fail '--ufw-reset not applied'
if bash "$bootstrap" --print-config --ufw-reset=yes >/dev/null 2>&1; then
  fail 'invalid UFW_RESET value was accepted'
fi
printf 'UFW_RESET defaults to false, is settable and validated.\n'

# INSTALL_SUDO defaults to true and --no-sudo disables it
[[ $(bash "$bootstrap" --print-config) == *'INSTALL_SUDO=true'* ]] || fail 'default INSTALL_SUDO should be true'
out=$(bash "$bootstrap" --print-config --no-sudo)
[[ $out == *'INSTALL_SUDO=false'* ]] || fail '--no-sudo not applied'
if bash "$bootstrap" --print-config --no-sudo=yes >/dev/null 2>&1; then
  fail 'invalid INSTALL_SUDO value was accepted'
fi
printf 'INSTALL_SUDO defaults to true and --no-sudo works.\n'

# extras.sh: help and argument validation work without root changes
extras_help=$(bash "$script_dir/extras.sh" --help)
for opt in --unprivileged-port-start --docker-compat --registries --project-dir --netavark --all; do
  [[ $extras_help == *"$opt"* ]] || fail "extras.sh --help is missing $opt"
done
if bash "$script_dir/extras.sh" --bogus-option >/dev/null 2>&1; then
  fail 'extras.sh accepted an unknown option'
fi
printf 'extras.sh --help lists its options and rejects unknown ones.\n'

# root must be able to run the scripts directly on minimal images (no sudo
# installed yet): neither script may invoke sudo as a command (help examples ok)
if grep -nE '^[[:space:]]*sudo[[:space:]]|[;&|][[:space:]]*sudo[[:space:]]' "$bootstrap" "$script_dir/extras.sh" \
   | grep -vE 'bash \./bootstrap\.sh|bash scripts/extras\.sh'; then
  fail 'a script invokes sudo internally; root should run it directly'
fi
printf 'Neither script invokes sudo internally (root runs them directly).\n'

printf 'All tests passed.\n'
