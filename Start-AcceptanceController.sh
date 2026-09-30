#!/usr/bin/env bash
# Run the old/current-laptop acceptance controller from inside WSL.
set -euo pipefail

[[ -n ${WSL_DISTRO_NAME:-} || $(uname -r) == *[Mm]icrosoft* ]] || {
  printf 'Run this script inside WSL.\n' >&2
  exit 2
}
command -v powershell.exe >/dev/null || { printf 'Windows PowerShell interop is unavailable in this WSL distro.\n' >&2; exit 2; }
command -v wslpath >/dev/null || { printf 'wslpath is unavailable in this WSL distro.\n' >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
controller="$script_dir/Start-AcceptanceController.ps1"
[[ -f $controller ]] || { printf 'Start-AcceptanceController.ps1 is missing.\n' >&2; exit 2; }
windows_controller=$(wslpath -w "$controller")

# The execution-policy override applies only to this child process. It does not
# alter CurrentUser, LocalMachine, or Group Policy configuration.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_controller" "$@"
