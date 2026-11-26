#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bootstrap="$script_dir/../bootstrap.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$bootstrap"
printf 'Shell syntax is valid.\n'

help_out=$(bash "$bootstrap" --help)
for opt in --admin-user --rootless-user --ssh-port --docker-compat --ssh-key-file --env-file --print-config; do
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
MALFORMED LINE WITHOUT EQUALS
UNKNOWN_VAR=ignored
EOF

# .env file values are picked up when no args/env override them
out=$(cd "$tmp" && bash "$bootstrap" --print-config)
[[ $out == *'ADMIN_USER=ops'* ]] || fail ".env ADMIN_USER not applied: $out"
[[ $out == *'SSH_PORT=2222'* ]] || fail ".env SSH_PORT not applied: $out"
[[ $out == *'ENABLE_DOCKER_COMPAT=true'* ]] || fail ".env ENABLE_DOCKER_COMPAT not applied: $out"
[[ $out == *'ROOTLESS_USER=app'* ]] || fail 'default ROOTLESS_USER missing'
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

printf 'All tests passed.\n'
