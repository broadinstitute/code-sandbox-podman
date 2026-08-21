# context_reference/

Read-only context for the agent: it is bind-mounted at `/context` inside the
sandbox with `:ro`, so the agent can read what you put here but cannot change it.
That makes it the right place for a plan, a spec or notes you do not want rewritten.

## This is probably NOT your upload directory

This directory is the **standalone local** default — one person, own machine, this
checkout is theirs. It is `CLAUDE_SANDBOX_CONTEXT_DIR` only when your env file says
so, and on a shared server it does not.

**On a shared server, this checkout belongs to the admin and is read-only to you.**
Your own directories are under `/mnt/sandbox/users/$USER/`:

| Put files here | Appears inside as | Agent can write? |
|---|---|---|
| `/mnt/sandbox/users/$USER/context/` | `/context` | no — read-only |
| `/mnt/sandbox/users/$USER/workspace/` | `/workspace` | yes |

Those are created by `scripts/provision-sandbox-user.sh` (step 1 of per-user setup).
If they do not exist yet, run it — nothing else will work either, and looking for a
place to put files inside this checkout is the symptom.

Confirm where yours actually points before copying anything:

```bash
source /mnt/sandbox/users/$USER/env.$USER.sh
echo "$CLAUDE_SANDBOX_CONTEXT_DIR"
```

Full detail: [Getting files into the sandbox](../CONFIG.md#getting-files-into-the-sandbox).

This README is the only file tracked in git; everything else here is ignored.
