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
#
# It also needs NO root. Everything it touches is either the user's own home or
# their own directory under the data disk. That is a deliberate constraint: an
# admin sets the host up once, and every user after that onboards themselves.
# The only prerequisites that need root are the one-time host steps in the README
# (packages, uv, the data disk, `chmod 1777` on users/, and building the shared
# image store). This script checks each of those and names the exact command an
# admin should run if one is missing, rather than failing obscurely.
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

# fuse-overlayfs is in this list because the shared image store does not work
# without it — see the storage.conf written further down.
for b in podman pasta uv git fuse-overlayfs; do
    if command -v "$b" >/dev/null 2>&1; then
        ok "$b present"
    else
        fatal "$b missing — the admin needs to install it (see README, GCP VM section)"
    fi
done

if command -v podman >/dev/null 2>&1; then
    # `|| true` matters: under `set -o pipefail` a failing `podman --version`
    # makes this assignment non-zero, and `set -e` then kills the script with no
    # output at all -- exactly when the user most needs to be told what is wrong.
    v="$(podman --version 2>/dev/null | awk '{print $3}')" || true
    if [[ -z "$v" ]]; then
        fatal "podman is on PATH but \`podman --version\` produced nothing."
        echo "          It is probably misconfigured. Try running it directly to"
        echo "          see the error: podman --version"
    elif [[ -n "${v%%.*}" ]] && (( ${v%%.*} >= 5 )); then
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

# Optional, but the closing message tells the user to run both, so a missing
# binary belongs here rather than surfacing as "command not found" three steps
# later.
for b in gcloud gh; do
    if command -v "$b" >/dev/null 2>&1; then
        ok "$b present"
    else
        warn "$b not installed — needed for the auth steps printed at the end."
        warn "  install with: sudo apt-get install -y $b"
    fi
done

if [[ ! -d "$SANDBOX_ROOT" ]]; then
    fatal "$SANDBOX_ROOT does not exist. The admin must format and mount the"
    echo "          data disk first (README, GCP VM section)."
elif [[ ! -d "${SANDBOX_ROOT}/users" ]]; then
    fatal "${SANDBOX_ROOT}/users does not exist. One-time admin step:"
    echo "            sudo mkdir -p ${SANDBOX_ROOT}/users"
    echo "            sudo chmod 1777 ${SANDBOX_ROOT}/users"
elif [[ ! -w "${SANDBOX_ROOT}/users" ]]; then
    # This is the check that keeps user setup root-free. Without a writable
    # parent, every new user would need an admin to mkdir for them.
    fatal "${SANDBOX_ROOT}/users is not writable by you, so you cannot create"
    echo "          your own directory. One-time admin step:"
    echo "            sudo chmod 1777 ${SANDBOX_ROOT}/users"
    echo "          The sticky bit means you can create your own directory but"
    echo "          cannot remove or rename anyone else's."
else
    ok "${SANDBOX_ROOT}/users is writable — no root needed for your setup"
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
# One location, always: the user's own tree. It is always writable, it is on the
# data disk so it survives a boot-disk rebuild, and it keeps per-user files out of
# a shared checkout. An earlier version put it in the checkout when that happened
# to be writable, so two users on one host could have it in different places.
ENV_FILE="${USER_ROOT}/env.${USER}.sh"
if [[ -e "$ENV_FILE" ]]; then
    ok "env file already exists, left alone: ${ENV_FILE}"
else
    sed -e "s|__USER_ROOT__|${USER_ROOT}|g" \
        -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
        -e "s|__USER__|${USER}|g" \
        "${REPO_ROOT}/env.gcp.example.sh" > "$ENV_FILE"
    ok "wrote ${ENV_FILE}"
fi

# Migrate a stray copy left in the checkout by an older version, so a user does
# not end up sourcing a stale file that no longer matches the template.
LEGACY_ENV="${REPO_ROOT}/env.${USER}.sh"
if [[ -e "$LEGACY_ENV" ]]; then
    warn "an older env file exists in the checkout: ${LEGACY_ENV}"
    warn "  the current one is ${ENV_FILE} -- delete the old one to avoid confusion"
fi

# ------------------------------------------------------------- staleness ----
echo
echo "=== checkout freshness ==="
# The instructions printed at the end come from THIS checkout. If it is behind
# its remote, a user follows outdated steps and hits problems that were already
# fixed upstream -- which has happened repeatedly. Read-only check: fetch into
# FETCH_HEAD without touching any branch, so it is safe for a user who does not
# own the checkout.
# Deliberately `ls-remote`, not `fetch`. A shared checkout is owned by the admin,
# so a normal user has no write access to .git and `fetch` dies with
# "cannot open '.git/FETCH_HEAD': Permission denied" — measured. That would make
# this check useless for exactly the users who most need it. `ls-remote` queries
# the remote and writes nothing locally.
if [[ -d "${REPO_ROOT}/.git" ]]; then
    _branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    _local=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
    _remote=$(git -C "$REPO_ROOT" ls-remote origin "refs/heads/${_branch}" 2>/dev/null | cut -f1)

    if [[ -z "$_remote" ]]; then
        warn "could not reach the remote to check if this checkout is current"
    elif [[ "$_local" != "$_remote" ]]; then
        warn "this checkout differs from origin/${_branch}."
        warn "  local  ${_local:0:8}"
        warn "  remote ${_remote:0:8}"
        warn "  The steps printed at the end come from THIS checkout, so some may"
        warn "  be out of date. Ask whoever owns ${REPO_ROOT} to run:"
        warn "    git -C ${REPO_ROOT} pull && chmod -R a+rX ${REPO_ROOT}"
    else
        ok "checkout matches origin/${_branch} (${_local:0:8})"
    fi
else
    warn "${REPO_ROOT} is not a git checkout; cannot check freshness"
fi

# ------------------------------------------------------- shared image store --
echo
echo "=== container image store ==="
IMAGE_STORE="${CLAUDE_SANDBOX_IMAGE_STORE:-${SANDBOX_ROOT}/imagestore}"
STORAGE_CONF="${HOME}/.config/containers/storage.conf"

if [[ -d "$IMAGE_STORE" ]]; then
    # Treat a storage.conf that references the store but lacks mount_program as
    # INCOMPLETE and rewrite it, rather than skipping. An earlier version of this
    # script wrote the file without mount_program, and the result is not a
    # cosmetic difference -- containers fail to start with
    #   Error: creating container storage: error during chown: remove
    #   usr/bin/bzcat: permission denied
    # because a rootless consumer cannot chown layers written by rootful podman.
    # Skipping on "additionalimagestores is present" left those users broken with
    # no indication why, and re-running the script did not repair them.
    if [[ -e "$STORAGE_CONF" ]] \
       && grep -q "additionalimagestores" "$STORAGE_CONF" \
       && ! grep -q "mount_program" "$STORAGE_CONF"; then
        warn "storage.conf references the image store but has no mount_program."
        warn "That combination fails at container start. Rewriting it."
        rm -f "$STORAGE_CONF"
    fi

    if [[ -e "$STORAGE_CONF" ]] && grep -q "additionalimagestores" "$STORAGE_CONF"; then
        ok "storage.conf already references an additional image store (with mount_program)"
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
# root-populated copy read-only, so this account does not hold its own: podman
# lists it as R/O=true, runs it without copying, and this user's own graphroot
# stays at a couple of hundred KB.
#
# Consequence, and it is intended: you cannot rebuild or modify the image. An
# admin owns it via scripts/build-shared-image.sh, so everyone provably runs the
# same one.
#
# mount_program is REQUIRED, not a tuning knob. The shared store is populated by
# ROOTFUL podman, whose overlay layers carry trusted.overlay.* xattrs. A rootless
# consumer mounts overlay with userxattr and cannot interpret those, so the
# merged rootfs comes up incomplete and the container dies with something
# thoroughly unhelpful:
#
#   crun: open `.../merged/run/.containerenv`: No such file or directory:
#   OCI runtime attempted to invoke a command that was not found
#
# The image still LISTS fine in that state, because its metadata is readable —
# only running fails, which makes it easy to believe the store is working when it
# is not. fuse-overlayfs resolves layer ownership in userspace instead of relying
# on kernel xattr semantics, and fixes it. Verified end to end on a second,
# sudo-less account: image R/O=true, \`claude --version\` runs, local store 196K.
[storage]
driver = "overlay"

[storage.options]
additionalimagestores = [ "${IMAGE_STORE}" ]

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
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
echo "${GRN}Step 1 done.${RST}  (\"Per-user setup\" in the README — this script is step 1.)"
echo
echo "Nothing was authenticated. Steps 2-6 below are yours, and the numbering"
echo "matches the README exactly, so you can follow either one."

cat <<EOF

  Step 2. Google Cloud. Needed because fiss-mcp reads YOUR credentials from
     ~/.config/gcloud. Logging into this VM over SSH used your SSH key, not your
     Google identity, so this is a separate step:

       gcloud auth login --no-launch-browser
       gcloud auth application-default login --no-launch-browser

     Both print a URL. Open it on your laptop, paste the code back.

     On a GCE VM the second command warns that it is "not necessary" because the
     VM's service credentials would be used automatically, and asks to confirm.
     Answer Y. The VM's service account is not you: it is a different identity
     with narrow scopes, and it is not what has access to your Terra workspaces.
     fiss-mcp needs YOUR credentials.

     Then set CLAUDE_SANDBOX_GCP_PROJECT in
     ${ENV_FILE}
     to a project where you have serviceusage.services.use.

     Do this even though gcloud reports 'Quota project "..." was added to ADC'.
     That sets quota_project_id, which is NOT a project source:
     google.auth.default() still returns project=None, and the fiss-mcp GCS tools
     fail with "Project was not passed and could not be determined from the
     environment". Measured, not assumed.

  Step 3. GitHub, if you want to push from this host:

       command -v gh || sudo apt-get install -y gh
       gh auth login --web
       gh auth setup-git
       git config --get-all credential.helper   # must print the gh helper

     Paste the code into the BROWSER, not into a chat or a terminal log — it is
     single-use credential material.

     'gh auth setup-git' is a SEPARATE REQUIRED STEP. Logging in gives gh a
     token; it does not necessarily configure git to use it. Without it, git
     push asks for a username and password, and GitHub removed password auth,
     so it can never succeed. Check the credential.helper line above rather
     than finding out at push time.

     If a branch touches .github/workflows/, the push is rejected even with a
     working login: "refusing to allow an OAuth App to create or update
     workflow ... without workflow scope". Grant it with:

       gh auth refresh -s workflow

     Worth a look before you do. A modified workflow runs with your Actions
     permissions and secrets, and it is the one thing the credential boundary
     does not cover: the agent cannot reach GitHub, but it can author a
     workflow change that you then push.

       git diff origin/HEAD...HEAD -- .github/workflows/

     Note: this authenticates YOU on the host. The sandbox container carries no
     git credentials by design, so \`git push\` from inside it cannot succeed.
     Commit inside, push outside. That is deliberate, not a limitation.

  Step 4. Build the fiss-mcp venv (installs nothing system-wide):

       source ${ENV_FILE}
       ./setup_host.sh

  Step 5. Launch, and run /login once inside for Claude Code:

       ./run_claude_docker.sh


  Step 6. Give the agent something to work on. Straight after step 5 it can see only
     an empty /workspace. Clone whatever you want worked on into your workspace:

       cd ${USER_ROOT}/workspace
       git clone https://github.com/your-org/your-repo

     That is all. workspace/ is already mounted as /workspace, so the repo shows
     up inside at /workspace/your-repo with no further configuration, read-write,
     and files the agent writes stay owned by you on the host.

     You push from the host side, at ${USER_ROOT}/workspace/your-repo. The agent
     cannot: the container holds no git credentials.

     (CLAUDE_SANDBOX_RW_MOUNTS exists for repos that must live somewhere OTHER
     than your workspace, mounting them at /projects/<name>. You do not need it
     for the normal case, and you should not point it at workspace/ -- that would
     mount the same repo twice, under two different paths.)
EOF
