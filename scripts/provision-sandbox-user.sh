#!/usr/bin/env bash
# provision-sandbox-user.sh — one-time per-user setup on a shared host.
#
# Run it as yourself, not as root, not with sudo:
#     ./scripts/provision-sandbox-user.sh
#
# It does the mechanical parts of getting one user ready and nothing else:
# checks the prerequisites that fail confusingly when absent, creates that
# user's directories on the data disk, enables linger, and writes their
# env.<USER>.sh from the GCP template.
#
# It deliberately does NOT authenticate anything. gcloud and GitHub logins are
# interactive, belong to the user, and are listed at the end as the steps only
# they can perform. No credential is read, written, copied or forwarded here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SANDBOX_ROOT="${CLAUDE_SANDBOX_ROOT:-/mnt/sandbox}"
USER_ROOT="${SANDBOX_ROOT}/users/${USER}"

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; RST=$'\033[0m'
FAIL=0
ok()    { echo "  ${GRN}ok${RST}      $*"; }
warn()  { echo "  ${YEL}warn${RST}    $*"; }
fatal() { echo "  ${RED}FAIL${RST}    $*"; FAIL=1; }

if [[ "$(id -u)" == "0" ]]; then
    echo "Run this as your own user, not root — it provisions whoever invokes it." >&2
    exit 1
fi

echo
echo "Provisioning sandbox for ${USER} (uid $(id -u))"
echo

# ---------------------------------------------------------------- checks ----
echo "=== prerequisites ==="

for b in podman pasta uv git; do
    if command -v "$b" >/dev/null 2>&1; then
        ok "$b present"
    else
        fatal "$b missing — the admin needs to install it (see README, GCP VM section)"
    fi
done

if command -v podman >/dev/null 2>&1; then
    v="$(podman --version 2>/dev/null | awk '{print $3}')"
    if [[ -n "${v%%.*}" ]] && (( ${v%%.*} >= 5 )); then
        ok "podman $v (>= 5 required for keep-id:uid= and pasta)"
    else
        fatal "podman $v is too old; >= 5.0 required"
    fi
fi

# subuid/subgid: the thing that silently breaks rootless podman. On a GCP VM
# using metadata SSH keys these are allocated by the guest agent's useradd. They
# are absent for OS Login users, which is why this host does not use OS Login.
for f in /etc/subuid /etc/subgid; do
    if line=$(grep -E "^${USER}:" "$f" 2>/dev/null); then
        count="${line##*:}"
        if (( count >= 65536 )); then
            ok "$f: $line"
        else
            warn "$f range is only ${count} ids; 65536 recommended"
        fi
    else
        fatal "no entry for '${USER}' in $f — rootless podman cannot work."
        echo "          An admin can add one with:"
        echo "            sudo usermod --add-subuids 100000-165535 \\"
        echo "                         --add-subgids 100000-165535 ${USER}"
        echo "          (pick a range that does not overlap another user's)"
    fi
done

# --memory is silently ignored without the memory controller delegated.
CG="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if [[ -r "$CG" ]] && grep -qw memory "$CG"; then
    ok "cgroup v2 memory controller delegated ($(cat "$CG"))"
else
    warn "memory controller not delegated — CLAUDE_SANDBOX_MEMORY will be ignored"
fi

if [[ ! -d "$SANDBOX_ROOT" ]]; then
    fatal "$SANDBOX_ROOT does not exist. The admin must format and mount the"
    echo "          data disk first (README, GCP VM section)."
fi

if [[ "$FAIL" == "1" ]]; then
    echo
    echo "${RED}Stopping: fix the failures above first.${RST}"
    exit 1
fi

# ------------------------------------------------------------------ dirs ----
echo
echo "=== directories on ${SANDBOX_ROOT} ==="
# Everything per-user lives on the data disk, NOT in $HOME: home directories are
# on the small boot disk, and the image plus workspaces do not fit there.
for d in "${USER_ROOT}/workspace" "${USER_ROOT}/state" "${USER_ROOT}/shared" \
         "${USER_ROOT}/fiss-mcp"; do
    if [[ -d "$d" ]]; then
        ok "exists: $d"
    else
        mkdir -p "$d" && ok "created: $d"
    fi
done
chmod 700 "$USER_ROOT"
ok "chmod 700 ${USER_ROOT}"
warn "700 stops other users reading this directly, but NOT via sudo. On a GCP"
warn "VM every metadata-SSH-key user is in google-sudoers, so anyone who can log"
warn "in can read your Claude token and gcloud credentials. Treat co-users as"
warn "trusted, or restrict who has a key."

# Seed the shared-state dir from the repo so this user gets working hooks,
# settings and the vendored plugins. Copied, not symlinked: the container mounts
# it read-write, and users must not write into a shared checkout.
if [[ ! -e "${USER_ROOT}/shared/.claude" ]]; then
    cp -a "${REPO_ROOT}/claude-sandbox-shared/.claude" "${USER_ROOT}/shared/.claude"
    ok "seeded ${USER_ROOT}/shared/.claude from the checkout"
else
    ok "shared state already present (left alone)"
fi

# --------------------------------------------------------------- env file ---
echo
echo "=== env file ==="
ENV_FILE="${REPO_ROOT}/env.${USER}.sh"
if [[ -e "$ENV_FILE" ]]; then
    ok "$(basename "$ENV_FILE") already exists (left alone)"
elif [[ -w "$REPO_ROOT" ]]; then
    sed -e "s|__USER_ROOT__|${USER_ROOT}|g" \
        -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
        -e "s|__USER__|${USER}|g" \
        "${REPO_ROOT}/env.gcp.example.sh" > "$ENV_FILE"
    ok "wrote $(basename "$ENV_FILE")"
else
    # Shared read-only checkout: keep the user's env file in their own tree.
    ENV_FILE="${USER_ROOT}/env.${USER}.sh"
    sed -e "s|__USER_ROOT__|${USER_ROOT}|g" \
        -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
        -e "s|__USER__|${USER}|g" \
        "${REPO_ROOT}/env.gcp.example.sh" > "$ENV_FILE"
    ok "checkout is read-only; wrote ${ENV_FILE}"
fi

# ------------------------------------------------------- shared image store --
echo
echo "=== container image store ==="
IMAGE_STORE="${CLAUDE_SANDBOX_IMAGE_STORE:-${SANDBOX_ROOT}/imagestore}"
STORAGE_CONF="${HOME}/.config/containers/storage.conf"

if [[ -d "$IMAGE_STORE" ]]; then
    if [[ -e "$STORAGE_CONF" ]] && grep -q "additionalimagestores" "$STORAGE_CONF"; then
        ok "storage.conf already references an additional image store"
    else
        if [[ -e "$STORAGE_CONF" ]]; then
            cp -a "$STORAGE_CONF" "${STORAGE_CONF}.bak"
            warn "existing storage.conf backed up to $(basename "${STORAGE_CONF}").bak"
        fi
        mkdir -p "$(dirname "$STORAGE_CONF")"
        cat > "$STORAGE_CONF" <<CONF
# Written by scripts/provision-sandbox-user.sh.
#
# The sandbox image is ~8.3 GB. additionalimagestores exposes one shared,
# root-populated copy read-only, so this account does not hold its own — with an
# empty graphroot plus the shared store, podman lists the image as
# ReadOnly=true, runs it without copying, and the local graphroot stays tiny.
#
# Consequence, and it is intended: you cannot rebuild or modify the image. An
# admin owns it via scripts/build-shared-image.sh, so everyone provably runs the
# same one.
[storage]
driver = "overlay"

[storage.options]
additionalimagestores = [ "${IMAGE_STORE}" ]
CONF
        ok "wrote ${STORAGE_CONF} -> ${IMAGE_STORE}"
    fi

    if podman images --format '{{.Repository}}' 2>/dev/null | grep -q claude-sandbox; then
        ok "claude-sandbox image visible from the shared store"
    else
        warn "shared store exists but no claude-sandbox image is visible."
        warn "An admin may still need to run: sudo ./scripts/build-shared-image.sh"
    fi
else
    warn "no shared image store at ${IMAGE_STORE}."
    warn "You will need your own copy of the image (~8.3 GB), or ask an admin to"
    warn "run: sudo ./scripts/build-shared-image.sh"
fi

# ---------------------------------------------------------------- linger ----
echo
echo "=== linger ==="
# Without this, systemd tears down your user slice at logout and kills both the
# container and the host-side fiss-mcp — so a long agent run dies when you
# disconnect.
if [[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
    ok "linger already enabled"
elif loginctl enable-linger "$USER" 2>/dev/null; then
    ok "linger enabled (your containers survive logout)"
else
    warn "could not enable linger; run: sudo loginctl enable-linger $USER"
fi

# ------------------------------------------------------------- what's left --
echo
echo "${GRN}Mechanical setup done.${RST} Nothing was authenticated — those steps are yours:"
cat <<EOF

  1. Google Cloud. Needed because fiss-mcp reads YOUR credentials from
     ~/.config/gcloud. Logging into this VM over SSH used your SSH key, not your
     Google identity, so this is a separate step:

       gcloud auth login --no-launch-browser
       gcloud auth application-default login --no-launch-browser

     Both print a URL. Open it on your laptop, paste the code back. Then set
     CLAUDE_SANDBOX_GCP_PROJECT in ${ENV_FILE}
     to a project where you have serviceusage.services.use — without it the
     fiss-mcp GCS tools fail with "Project was not passed".

  2. GitHub, if you want to push from this host:

       gh auth login --web

     Prints a one-time code; open the URL on your laptop. This also configures
     git's credential helper, so HTTPS pushes work afterwards.

     Note: this authenticates YOU on the host. The sandbox container carries no
     git credentials by design, so \`git push\` from inside it cannot succeed.
     Commit inside, push outside. That is deliberate, not a limitation.

  3. Build the fiss-mcp venv (installs nothing system-wide):

       source ${ENV_FILE}
       ./setup_host.sh

  4. Launch, and run /login once inside for Claude Code:

       ./run_claude_docker.sh

EOF
