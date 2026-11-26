#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

bash -n "$script_dir/bootstrap.sh"
printf 'Shell syntax is valid.\n'
