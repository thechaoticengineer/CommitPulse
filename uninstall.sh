#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lifecycle.sh
source "$repository_root/scripts/lifecycle.sh"

commitpulse_uninstall "$repository_root" "$@"
