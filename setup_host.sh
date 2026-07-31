#!/usr/bin/env bash
# setup_host.sh — host bootstrap dispatcher.
#
# Detects the host OS via `uname -s` and forwards execution to the
# OS-specific helper under scripts/. Users always invoke this script,
# not the helpers, so the entry point stays the same across platforms.
#
# Supported helpers:
#   scripts/setup_host_podman.sh  (rootless podman — the supported path)
#   scripts/setup_host_linux.sh   (Linux: Debian/Ubuntu apt path, upstream's,
#                                  unverified in this fork)
#
# Args + env are forwarded verbatim. To force a specific helper for
# testing, set SETUP_HOST_OS=podman or SETUP_HOST_OS=linux.
#
# macOS support was removed in this fork: the helper it dispatched to installed
# Docker Desktop or OrbStack, which is upstream's engine, not this one. podman
# does run on macOS via `podman machine`, but the two things this sandbox
# depends on — `--userns=keep-id` uid mapping and pasta loopback forwarding —
# behave differently inside that VM and are untested. Claiming support would be
# guessing, so the path is gone rather than left to rot.
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
      # This fork targets rootless podman, so prefer that helper whenever
      # podman is present. setup_host_linux.sh (apt + Docker CE 28.x +
      # sysbox-runc + postfix) is upstream's path and is not exercised here;
      # force it with SETUP_HOST_OS=linux if you actually want it.
      if command -v podman >/dev/null 2>&1; then
        OS_KEY=podman
      else
        OS_KEY=linux
      fi
      ;;
    Darwin)
      echo "setup_host.sh: macOS is not supported by this fork." >&2
      echo "                It targets rootless podman on a Fedora/RHEL-family" >&2
      echo "                host. For the Docker/macOS path use upstream:" >&2
      echo "                https://github.com/jonn-smith/claude-docker-sandbox" >&2
      exit 1
      ;;
    *)
      echo "setup_host.sh: unsupported host OS '$(uname -s)'." >&2
      echo "                Supported: Linux with rootless podman." >&2
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
