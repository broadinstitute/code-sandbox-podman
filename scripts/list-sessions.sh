#!/usr/bin/env bash
# list-sessions.sh — browse this sandbox's previous Claude Code sessions and pick
# one to resume.
#
#     ./scripts/list-sessions.sh            # table, newest first
#     ./scripts/list-sessions.sh --pick     # fzf picker, then resume it
#
# Source your env file first, the same as for a launch: the transcripts live under
# $CLAUDE_SANDBOX_HOME, which only that file knows.
#
# Why this exists rather than `ls`: a directory of uuid.jsonl files tells you nothing
# about what any session was for. This prints the first real prompt of each, which is
# what people actually recognise a session by.
#
# start_sandbox.sh also has a session picker, but it is built around the local
# multi-instance layout — it discovers instances from env.*.sh files sitting next to
# itself, which on a shared host live in each user's own tree instead. This works from
# the environment you already sourced, so it behaves the same in both layouts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PICK=0
[[ "${1:-}" == "--pick" ]] && PICK=1

if [[ -z "${CLAUDE_SANDBOX_HOME:-}" ]]; then
    echo "CLAUDE_SANDBOX_HOME is not set — source your env file first:" >&2
    echo "    source /mnt/sandbox/users/\$USER/env.\$USER.sh" >&2
    echo "  (or your env.<INSTANCE>.sh on a standalone install)" >&2
    exit 1
fi

PROJECTS="${CLAUDE_SANDBOX_HOME}/.claude/projects"
if [[ ! -d "$PROJECTS" ]]; then
    echo "No transcripts yet: ${PROJECTS} does not exist." >&2
    echo "It appears after your first session." >&2
    exit 1
fi

# Parsing lives in python because the interesting part -- the first prompt that is a
# real human message rather than a hook caveat or a slash-command echo -- needs JSON
# per line. Deliberately cheap: file mtime for "when", wc for "how big", and an early
# exit as soon as a usable prompt is found, so a directory of multi-MB transcripts
# still lists instantly.
LIST=$(python3 - "$PROJECTS" <<'PY'
import json, os, sys, glob, datetime

projects = sys.argv[1]
# A "user" entry is not necessarily something the human typed. Slash-command echoes,
# hook output and command stdout are all recorded as user turns, and any of them can
# come first — which is how this listing ended up showing
# "<local-command-stdout>Login interrupted</local-command-stdout>" as the opening
# prompt of a 1880-message session. Skip the machinery and keep looking.
NOISE = ("<command-name>", "<command-message>", "<command-args>",
         "<system-reminder>", "Caveat: The messages below were generated")


def is_machine(text):
    t = text.lstrip()
    return t.startswith("<local-command") or any(n in text for n in NOISE)

rows = []
for path in glob.glob(os.path.join(projects, "*", "*.jsonl")):
    uuid = os.path.basename(path)[:-6]
    st = os.stat(path)
    prompt, entries = "", 0
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                entries += 1
                if prompt:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "user":
                    continue
                c = d.get("message", {}).get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                if not isinstance(c, str) or not c.strip():
                    continue
                if is_machine(c):
                    continue
                prompt = " ".join(c.split())[:72]
    except OSError:
        continue
    rows.append((st.st_mtime, uuid, entries, st.st_size,
                 os.path.basename(os.path.dirname(path)), prompt or "(no prompt found)"))

rows.sort(reverse=True)
for mtime, uuid, entries, size, proj, prompt in rows:
    when = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
    mb = f"{size/1048576:.1f}M" if size >= 1048576 else f"{size//1024}K"
    print(f"{when}\t{entries:>6}\t{mb:>6}\t{proj}\t{uuid}\t{prompt}")
PY
)

if [[ -z "$LIST" ]]; then
    echo "No sessions found under ${PROJECTS}." >&2
    exit 1
fi

if (( PICK == 0 )); then
    printf '%-16s %6s %6s  %s\n' "WHEN" "MSGS" "SIZE" "FIRST PROMPT"
    while IFS=$'\t' read -r when entries size proj uuid prompt; do
        printf '%-16s %6s %6s  %s\n' "$when" "$entries" "$size" "$prompt"
        printf '%-16s %6s %6s  %s\n' "" "" "" "resume: ./run_claude_docker.sh --resume $uuid"
    done <<< "$LIST"
    echo
    echo "Pick one interactively with: $0 --pick    (needs fzf)"
    exit 0
fi

command -v fzf >/dev/null 2>&1 || {
    echo "--pick needs fzf. Install it, or run without --pick and copy a uuid." >&2
    exit 1
}

# The preview pane shows the human turns, which is how you tell two similar sessions
# apart. jq would be another dependency; python is already required above.
CHOSEN=$(printf '%s\n' "$LIST" \
  | fzf --with-nth=1,2,3,6.. --delimiter='\t' \
        --header='Pick a session to resume (ESC to cancel)' \
        --preview-window='down,60%,wrap' \
        --preview='python3 -c "
import json,sys
p=sys.argv[1]
shown=0
for line in open(p, errors=\"replace\"):
    try: d=json.loads(line)
    except: continue
    if d.get(\"type\") not in (\"user\",\"assistant\"): continue
    c=d.get(\"message\",{}).get(\"content\")
    if isinstance(c,list): c=\" \".join(x.get(\"text\",\"\") for x in c if isinstance(x,dict))
    if not isinstance(c,str) or not c.strip(): continue
    if \"<system-reminder>\" in c or \"<local-command-caveat>\" in c: continue
    who=\"YOU\" if d.get(\"type\")==\"user\" else \"CLAUDE\"
    print(f\"[{who}] \" + \" \".join(c.split())[:400] + chr(10))
    shown+=1
    if shown>12: break
" '"${PROJECTS}"'/{4}/{5}.jsonl' \
  | cut -f5) || true

[[ -n "${CHOSEN:-}" ]] || { echo "Nothing picked." >&2; exit 1; }

echo "Resuming ${CHOSEN}"
exec "${REPO_ROOT}/run_claude_docker.sh" --resume "$CHOSEN"
