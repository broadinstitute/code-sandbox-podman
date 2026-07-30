#!/usr/bin/env bash
# setup_host.sh — host bootstrap dispatcher.
#
# Detects the host OS via `uname -s` and forwards execution to the
# OS-specific helper under scripts/. Users always invoke this script,
# not the helpers, so the entry point stays the same across platforms.
#
# Supported helpers:
#   scripts/setup_host_linux.sh   (Linux: Debian/Ubuntu apt path)
#   scripts/setup_host_macos.sh   (macOS: Homebrew + Docker Desktop/OrbStack)
#
# Args + env are forwarded verbatim. To force a specific helper for
# testing, set SETUP_HOST_OS=linux or SETUP_HOST_OS=macos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OS_KEY="${SETUP_HOST_OS:-}"
if [[ -z "$OS_KEY" ]]; then
  case "$(uname -s)" in
    Linux)
      # setup_host_linux.sh is an apt path: it installs Docker CE 28.x,
      # sysbox-runc and postfix. On a host that has podman and no docker --
      # RHEL/Fedora family, typically -- that is both unusable (no apt) and
      # wrong (sysbox is Docker-only; there is no podman equivalent). Route
      # those hosts to the verify-only podman helper instead.
      if ! command -v apt-get >/dev/null 2>&1 \
         && command -v podman >/dev/null 2>&1 \
         && ! command -v docker >/dev/null 2>&1; then
        OS_KEY=podman
      else
        OS_KEY=linux
      fi
      ;;
    Darwin) OS_KEY=macos ;;
    *)
      echo "setup_host.sh: unsupported host OS '$(uname -s)'." >&2
      echo "                Supported: Linux (Debian/Ubuntu apt, or rootless podman), macOS." >&2
      exit 1
      ;;
  esac
fi

HELPER="${SCRIPT_DIR}/scripts/setup_host_${OS_KEY}.sh"
if [[ ! -x "$HELPER" ]]; then
  if [[ -f "$HELPER" ]]; then
    echo "setup_host.sh: helper exists but is not executable: $HELPER" >&2
    echo "                Run: chmod +x $HELPER" >&2
  else
    echo "setup_host.sh: no helper for OS '$OS_KEY' at $HELPER" >&2
  fi
  exit 1
fi

echo "setup_host.sh: dispatching to $(basename "$HELPER")"
exec "$HELPER" "$@"
