#!/usr/bin/env bash
# Run the old/current-laptop acceptance controller from inside WSL.
set -euo pipefail

[[ -n ${WSL_DISTRO_NAME:-} || $(uname -r) == *[Mm]icrosoft* ]] || {
  printf 'Run this script inside WSL.\n' >&2
  exit 2
}
powershell_bin=$(command -v powershell.exe || true)
if [[ -z $powershell_bin && -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
  powershell_bin=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
fi
[[ -n $powershell_bin ]] || { printf 'Windows PowerShell interop is unavailable in this WSL distro.\n' >&2; exit 2; }
command -v wslpath >/dev/null || { printf 'wslpath is unavailable in this WSL distro.\n' >&2; exit 2; }
wsl_distro=${WSL_DISTRO_NAME:-}
if [[ -z $wsl_distro ]]; then
  windows_wsl_root=$(wslpath -w / | tr -d '\r\n' | tr '\\' '/')
  windows_wsl_root=${windows_wsl_root%/}
  wsl_distro=${windows_wsl_root##*/}
fi
[[ $wsl_distro =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'Could not resolve the current WSL distro name.\n' >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
controller="$script_dir/Start-AcceptanceController.ps1"
[[ -f $controller ]] || { printf 'Start-AcceptanceController.ps1 is missing.\n' >&2; exit 2; }
windows_controller=$(wslpath -w "$controller")

# The execution-policy override applies only to this child process. It does not
# alter CurrentUser, LocalMachine, or Group Policy configuration.
"$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$windows_controller" \
  -BootstrapWslDistro "$wsl_distro" \
  -BootstrapWslRepoRoot "$script_dir" \
  "$@"
