# claude-sandbox-persistent-state-main/

Per-instance state for the `main` instance: `.claude.json`, caches, file history,
shell snapshots and session transcripts. This is the default
`CLAUDE_SANDBOX_HOME` for the **standalone local** layout.

**Do not put your own files here.** It is machine state, rewritten by Claude Code on
every run, and nothing in it is mounted anywhere a person would look for a document.
If you are looking for somewhere to put a plan or a dataset, you want one of these
instead:

| Put files here | Appears inside as | Agent can write? |
|---|---|---|
| `$CLAUDE_SANDBOX_PROJECTS_DIR` — on a shared server, `/mnt/sandbox/users/$USER/workspace/` | `/workspace` | yes |
| `$CLAUDE_SANDBOX_CONTEXT_DIR` — on a shared server, `/mnt/sandbox/users/$USER/context/` | `/context` | no, `:ro` |

See [Getting files into the sandbox](../CONFIG.md#getting-files-into-the-sandbox) and
[Mount layout](../CONFIG.md#mount-layout).

On a shared server your state dir is `/mnt/sandbox/users/$USER/state/`, not this one —
this checkout belongs to the admin and is read-only to you.

This README is the only file tracked in git; everything else here is ignored.
