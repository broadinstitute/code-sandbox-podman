# workspace/

Read-write workspace: bind-mounted at `/workspace` inside the sandbox, which is
also the container's working directory. Repos, loose files, scratch scripts — the
agent can read and write all of it, and what it writes stays owned by you.

## This is probably NOT your upload directory

This directory is the **standalone local** default — one person, own machine, this
checkout is theirs. It is `CLAUDE_SANDBOX_PROJECTS_DIR` only when your env file says
so, and on a shared server it does not.

**On a shared server, this checkout belongs to the admin and is read-only to you.**
Yours is `/mnt/sandbox/users/$USER/workspace/`, created by
`scripts/provision-sandbox-user.sh`, and already holding `warp` and `warp-tools`.

```bash
source /mnt/sandbox/users/$USER/env.$USER.sh
echo "$CLAUDE_SANDBOX_PROJECTS_DIR"     # where /workspace actually comes from
```

Use `context/` beside it for anything the agent should read but not modify; that
mount is `:ro`. Both are covered in
[Getting files into the sandbox](../CONFIG.md#getting-files-into-the-sandbox).

To point `/workspace` somewhere else entirely, set `CLAUDE_SANDBOX_PROJECTS_DIR` in
your own `env.<INSTANCE>.sh`.

This README is the only file tracked in git; everything else under `workspace/` is
ignored.
