#!/usr/bin/env bash
# Bootstrap the clean Windows acceptance target from inside WSL.
set -euo pipefail

usage() {
  printf 'Usage: %s --pairing-id ID --launcher-commit SHA [--destination PATH]\n' "$0" >&2
  exit 2
}

pairing_id=''
launcher_commit=''
destination=''
while (($#)); do
  case "$1" in
    --pairing-id) pairing_id=${2:-}; shift 2 ;;
    --launcher-commit) launcher_commit=${2:-}; shift 2 ;;
    --destination) destination=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

[[ $pairing_id =~ ^[0-9a-f]{12}$ ]] || usage
[[ $launcher_commit =~ ^[0-9a-f]{40}$ ]] || usage
[[ -n ${WSL_DISTRO_NAME:-} || $(uname -r) == *[Mm]icrosoft* ]] || {
  printf 'Run this script inside WSL.\n' >&2
  exit 2
}
command -v powershell.exe >/dev/null || { printf 'Windows PowerShell interop is unavailable in this WSL distro.\n' >&2; exit 2; }
command -v wslpath >/dev/null || { printf 'wslpath is unavailable in this WSL distro.\n' >&2; exit 2; }
[[ -n ${WSL_DISTRO_NAME:-} ]] || { printf 'WSL_DISTRO_NAME is unavailable; launch this from a normal WSL session.\n' >&2; exit 2; }

if [[ -z $destination ]]; then
  windows_destination=$(powershell.exe -NoProfile -Command '[IO.Path]::Combine([Environment]::GetFolderPath("UserProfile"),"PersonalRecoveryAcceptance")' | tr -d '\r')
  [[ $windows_destination == ?:\\* ]] || { printf 'Could not resolve the Windows user profile.\n' >&2; exit 2; }
  destination=$(wslpath -u "$windows_destination")
fi

if ! command -v git >/dev/null; then
  command -v apt-get >/dev/null || { printf 'Git is absent and apt-get is unavailable.\n' >&2; exit 2; }
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
fi

origin='https://github.com/KotdaPK/personal-recovery-bootstrap.git'
if [[ -e $destination ]]; then
  [[ -d $destination && -z $(find "$destination" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    printf 'Destination must be absent or empty: %s\n' "$destination" >&2
    exit 2
  }
else
  mkdir -p -- "$destination"
fi

git init --quiet "$destination"
git -C "$destination" remote add origin "$origin"
git -C "$destination" fetch --depth 1 origin "$launcher_commit"
git -C "$destination" checkout --quiet --detach "$launcher_commit"

[[ $(git -C "$destination" rev-parse HEAD) == "$launcher_commit" ]] || { printf 'Immutable checkout verification failed.\n' >&2; exit 2; }
[[ $(git -C "$destination" config --get remote.origin.url) == "$origin" ]] || { printf 'Canonical origin verification failed.\n' >&2; exit 2; }
[[ -z $(git -C "$destination" status --porcelain=v1) ]] || { printf 'Launcher checkout is not clean.\n' >&2; exit 2; }

target_script="$destination/Start-AcceptanceTarget.ps1"
[[ -f $target_script ]] || { printf 'Start-AcceptanceTarget.ps1 is missing from the verified checkout.\n' >&2; exit 2; }
windows_target=$(wslpath -w "$target_script")

# Process-scoped Bypass lets the reviewed immutable script run without changing
# the machine or user execution-policy configuration.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_target" \
  -PairingId "$pairing_id" \
  -BootstrapWslDistro "$WSL_DISTRO_NAME" \
  -BootstrapWslRepoRoot "$destination"
