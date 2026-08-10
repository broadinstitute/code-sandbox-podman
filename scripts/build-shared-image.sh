#!/usr/bin/env bash
# build-shared-image.sh — build the sandbox image once into a shared, read-only
# image store so N users do not each hold their own 8.3 GB copy.
#
# Run as root (the store must be populated by a real uid, not by one user's
# subuid range — see the note on ownership below):
#
#     sudo ./scripts/build-shared-image.sh
#
# Users then get the image read-only through `additionalimagestores` in their
# own containers-storage.conf, which scripts/provision-sandbox-user.sh writes.
#
# Why a shared store rather than each user building or pulling:
#   * 8.3 GB once instead of 8.3 GB x N users.
#   * Everyone provably runs the same image. Users cannot rebuild it, which is
#     a feature here: the image is the trust boundary, and drift between users
#     would make "it works for me" unfalsifiable.
#
# Verified mechanism: with an empty graphroot plus an additional store, podman
# lists the image as ReadOnly=true, runs it without copying, and the local
# graphroot stays at ~150 KB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STORE="${CLAUDE_SANDBOX_IMAGE_STORE:-/mnt/sandbox/imagestore}"
TAG_VERSION="$(awk -F'= *' '/^VERSION/{print $2}' "${REPO_ROOT}/docker/Makefile" | tr -d ' ')"
: "${TAG_VERSION:=0.0.1}"

if [[ "$(id -u)" != "0" ]]; then
    echo "build-shared-image.sh: run as root (sudo)." >&2
    echo "" >&2
    echo "  The store has to be populated by a real uid. A rootless build writes" >&2
    echo "  layer files owned by the builder's SUBUID range, and another user's" >&2
    echo "  user namespace cannot map those, so the image would be unreadable to" >&2
    echo "  everyone but the person who built it." >&2
    exit 1
fi

echo "Building claude-sandbox:${TAG_VERSION} into shared store ${STORE}"
echo

mkdir -p "$STORE"

# --root redirects the whole storage tree, so this build never touches the
# invoking user's ~/.local/share/containers.
podman --root "$STORE" build \
    -t "claude-sandbox:${TAG_VERSION}" \
    -t "claude-sandbox:latest" \
    "${REPO_ROOT}/docker"

# Readable and traversable by every user. Layer contents are root-owned; users
# read them by permission bits, so a+rX is what makes the store usable from
# another user's namespace. No write bit: the store is read-only to users by
# design, and podman enforces that too.
chmod -R a+rX "$STORE"

echo
echo "=== store contents ==="
podman --root "$STORE" images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
echo
du -sh "$STORE" | sed 's/^/  store size: /'

cat <<EOF

Done. Each user picks this up through ~/.config/containers/storage.conf:

    [storage]
    driver = "overlay"
    [storage.options]
    additionalimagestores = [ "${STORE}" ]

scripts/provision-sandbox-user.sh writes that automatically. Verify as a
NON-admin user with:

    podman images                      # should list claude-sandbox, ReadOnly=true
    podman run --rm localhost/claude-sandbox:${TAG_VERSION} claude --version
    du -sh ~/.local/share/containers   # should stay small: no local copy

To update the image later, re-run this script. Users need do nothing; they pick
up the new layers on their next launch.
EOF
