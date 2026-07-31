#!/usr/bin/env bash
# archive_sessions.sh — copy Claude Code session history out of every
# instance's live state dir into SESSION_ARCHIVE/, on demand.
#
# Sources scanned:
#   1. $REPO_ROOT/claude-sandbox-persistent-state-<INSTANCE>/.claude/
#        the default per-instance location, used when CLAUDE_SANDBOX_HOME
#        is not overridden.
#   2. $REPO_ROOT/claude-sandbox-shared/.claude/
#        shared-mode state (CLAUDE_SANDBOX_USE_SHARED=1).
#   3. $CLAUDE_SANDBOX_HOME/.claude/            (if that var is set)
#   4. $CLAUDE_SANDBOX_STATE_ROOT/*/.claude/    (each root, space-separated)
#   5. any directories passed as positional arguments
#
# Sources 3-5 exist because CLAUDE_SANDBOX_HOME routinely points OUTSIDE the
# checkout — state and workspace normally live on a data volume while the code
# lives in a git checkout. Scanning only 1 and 2 silently found nothing and
# printed "shared: 0 transcript(s)", which reads like "there is no history"
# rather than "I looked in the wrong place". Two things conspired to make that
# convincing:
#
#   * claude-sandbox-persistent-state-<INSTANCE>/ is a tracked placeholder in
#     the repo, so it exists but has no .claude/ and is skipped;
#   * claude-sandbox-shared/.claude/projects/ gets created as an empty
#     directory by the container engine, because it is the mountpoint for the
#     per-instance projects overlay. An empty dir that exists looked like a
#     real source with zero transcripts.
#
# To archive an instance whose state is elsewhere, either source its env file:
#     source env.<INSTANCE>.sh && ./SESSION_ARCHIVE/archive_sessions.sh
# or point at the parent of all instance state dirs once:
#     CLAUDE_SANDBOX_STATE_ROOT=/mnt/data/claude-sandbox/state \
#       ./SESSION_ARCHIVE/archive_sessions.sh
#
# For each source we copy:
#   .claude/projects/       session transcripts (<uuid>.jsonl) + sidecar dirs
#   .claude/history.jsonl   the command-history log, if it is a real file
#
# Destination: SESSION_ARCHIVE/<label>/ where <label> is the instance name
# (B, GATK, WHB, main, …) or "shared". Re-running overwrites with the live
# copy — transcripts are frozen once a session ends, so this is a safe mirror,
# not a destructive sync (nothing in the archive is deleted just because it
# vanished upstream).
#
# ponytail: cp-based mirror, no rsync (not installed on this host). If the
# transcript count grows into the thousands and full recopy gets slow,
# switch to `rsync -a --ignore-existing` — frozen files never need recopy.
set -euo pipefail

ARCHIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$ARCHIVE_DIR")"

copied_any=0
scanned_any=0
SEEN=""

# Canonicalize so the same directory reached two ways (say via
# CLAUDE_SANDBOX_HOME and via CLAUDE_SANDBOX_STATE_ROOT) is archived once.
canon() {
    [ -d "$1" ] && (cd -P "$1" && pwd) || printf '%s' "$1"
}

archive_one() {
    local src_claude="$1" label="$2"
    [ -d "$src_claude" ] || return 0

    local key
    key="$(canon "$src_claude")"
    if printf '%s\n' "$SEEN" | grep -qxF "$key"; then
        return 0
    fi
    SEEN="${SEEN}${key}"$'\n'

    # Count transcripts at the SOURCE before copying. The old code counted at
    # the destination after copying, so a source with no transcripts still
    # printed a success line.
    local n_src
    n_src=$(find "$src_claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')

    # history.jsonl is a symlink to a container-only path in shared-mode state
    # dirs; -f dereferences, so a dangling link is correctly skipped here.
    local has_hist=0
    [ -f "$src_claude/history.jsonl" ] && has_hist=1

    if [ "$n_src" = 0 ] && [ "$has_hist" = 0 ]; then
        # Nothing worth copying. Report it as scanned-but-empty rather than
        # staying silent, so "no history" is distinguishable from "not found".
        printf '  %-10s no transcripts, no history   (%s)\n' "${label}:" "$src_claude"
        scanned_any=1
        return 0
    fi

    local dest="$ARCHIVE_DIR/$label"
    local what=""

    if [ "$n_src" != 0 ]; then
        mkdir -p "$dest/projects"
        cp -a "$src_claude/projects/." "$dest/projects/"
        what="${n_src} transcript(s)"
    fi
    if [ "$has_hist" = 1 ]; then
        mkdir -p "$dest"
        cp -a "$src_claude/history.jsonl" "$dest/history.jsonl"
        what="${what:+${what}, }history.jsonl"
    fi

    printf '  %-10s %s -> %s\n' "${label}:" "$what" "${dest#$REPO_ROOT/}"
    printf '  %-10s   from %s\n' "" "$src_claude"
    copied_any=1
    scanned_any=1
}

echo "Archiving session history into ${ARCHIVE_DIR#$REPO_ROOT/}/ ..."

# 1. Default per-instance state dirs inside the checkout.
for d in "$REPO_ROOT"/claude-sandbox-persistent-state-*; do
    [ -d "$d" ] || continue
    archive_one "$d/.claude" "${d##*-state-}"
done

# 2. Shared-mode state (one dir, all shared instances write here).
archive_one "$REPO_ROOT/claude-sandbox-shared/.claude" "shared"

# 3. The instance named by the current environment, wherever it lives.
if [ -n "${CLAUDE_SANDBOX_HOME:-}" ]; then
    label="${CLAUDE_SANDBOX_INSTANCE:-$(basename "$CLAUDE_SANDBOX_HOME")}"
    archive_one "${CLAUDE_SANDBOX_HOME}/.claude" "$label"
fi

# 4. Every instance under one or more state roots, without needing to source
#    each env file. Label is the instance directory's own basename.
for root in ${CLAUDE_SANDBOX_STATE_ROOT:-}; do
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
        [ -d "$d/.claude" ] || continue
        archive_one "${d%/}/.claude" "$(basename "${d%/}")"
    done
done

# 5. Explicit directories on the command line. Accepts either an instance
#    state dir or the .claude dir inside it.
for arg in "$@"; do
    if [ -d "$arg/.claude" ]; then
        archive_one "$arg/.claude" "$(basename "$arg")"
    elif [ -d "$arg" ]; then
        archive_one "$arg" "$(basename "$(dirname "$arg")")"
    else
        echo "  skipping '$arg': not a directory" >&2
    fi
done

if [ "$copied_any" = 0 ]; then
    if [ "$scanned_any" = 0 ]; then
        echo "  no state dirs found at all."
    else
        echo "  nothing to archive — every source scanned was empty."
    fi
    echo
    echo "  If state lives outside the checkout (CLAUDE_SANDBOX_HOME is"
    echo "  overridden), tell this script where to look:"
    echo "    source env.<INSTANCE>.sh && ./SESSION_ARCHIVE/archive_sessions.sh"
    echo "  or:"
    echo "    CLAUDE_SANDBOX_STATE_ROOT=/path/to/state ./SESSION_ARCHIVE/archive_sessions.sh"
fi
echo "Done."
