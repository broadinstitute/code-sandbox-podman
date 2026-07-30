#!/usr/bin/env bash
# uid-fixup-entrypoint.sh — runs as root, remaps the bundled "claude" user
# to match the host invoker's UID/GID (passed via HOST_UID / HOST_GID), then
# drops privileges and execs the real entrypoint as claude. Lets a single
# image be shared across hosts with different user IDs without rebuilding.
set -euo pipefail

DEFAULT_CMD=(/home/claude/start_script.sh)
TARGET_UID="${HOST_UID:-}"
TARGET_GID="${HOST_GID:-}"

# Already unprivileged? Then there is nothing to do here and no way to do it.
#
# Under rootless podman the launcher starts the container with
# --userns=keep-id:uid=<claude uid>, which lands us directly on the claude
# user — the remap below has already happened, by mapping rather than by
# usermod. Falling through would be fatal rather than merely useless:
# usermod/groupmod need real root, and `gosu` fails with
#     error: failed switching to "claude": operation not permitted
# because it calls setgroups(2), which needs CAP_SETGID — and an
# unprivileged starting uid has no capabilities to call it with. That is
# true even when the target uid equals the current uid, so gosu cannot be
# treated as a no-op in that case.
#
# exec the command directly instead. Keeps one image working under both
# rootful Docker (root start, remap, drop privileges) and rootless podman
# (non-root start, nothing to remap).
if [[ "$(id -u)" != "0" ]]; then
  exec "${@:-${DEFAULT_CMD[@]}}"
fi

CUR_UID="$(id -u claude)"
CUR_GID="$(id -g claude)"

if [[ -n "$TARGET_GID" && "$TARGET_GID" != "$CUR_GID" ]]; then
  # -o allows duplicate gid (some hosts share gid with another system group)
  groupmod -o -g "$TARGET_GID" claude
fi

if [[ -n "$TARGET_UID" && "$TARGET_UID" != "$CUR_UID" ]]; then
  usermod -o -u "$TARGET_UID" claude

  # Only /home/claude needs ownership fixup — it has 644-mode dotfiles
  # (.bashrc, .msmtprc) that need to be writable by claude. /opt/claude-venv,
  # /usr/local/cargo, and /usr/local/rustup were chmod'd a+rwX at image
  # build time, so any UID can read+write them without a costly chown -R.
  chown -R "$TARGET_UID":"${TARGET_GID:-$CUR_GID}" /home/claude 2>/dev/null || true
fi

# Drop to claude and run the real entrypoint. exec-form so signals reach it.
exec gosu claude "${@:-${DEFAULT_CMD[@]}}"
