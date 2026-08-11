# Configuration reference

Everything is driven by environment variables; nothing is hardcoded in
`run_claude_docker.sh`. Put your settings in an `env.<INSTANCE>.sh` and source it
before launching. Templates: `env.podman.example.sh` (local),
`env.gcp.example.sh` (shared server). Any `env.*.sh` other than the tracked
`*.example.sh` files is gitignored, so your real paths never land in a commit.

## Contents

- [Core variables](#core-variables)
- [Mount layout](#mount-layout)
- [Read-only reference mounts](#read-only-reference-mounts)
- [Read-write project mounts, and how pushing works](#read-write-project-mounts-and-how-pushing-works)
- [Installing packages](#installing-packages)
- [Persistence](#persistence)
- [Customizing the image](#customizing-the-image)

## Core variables

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_SANDBOX_INSTANCE` | required | Unique instance name. Suffixes the container name, state dir, and the hashed MCP port. |
| `CLAUDE_SANDBOX_PROJECTS_DIR` | required | Host dir mounted at `/workspace`, read-write. The container's cwd. |
| `CLAUDE_SANDBOX_CONTEXT_DIR` | required | Host dir mounted at `/context`, **read-only**. |
| `CLAUDE_SANDBOX_HOME` | `claude-sandbox-persistent-state-<INSTANCE>/` | Per-instance state dir. Must be absolute. |
| `CLAUDE_SANDBOX_SHARED` | `claude-sandbox-shared/` | Shared state dir used when `USE_SHARED=1`. Must be absolute. |
| `CLAUDE_SANDBOX_USE_SHARED` | `0` in code, `1` in every template | Shared vs per-instance layout — see [Mount layout](#mount-layout). |
| `CLAUDE_SANDBOX_ENGINE` | `podman` | Set to `docker` to take upstream's inherited, untested path. |
| `CLAUDE_SANDBOX_MEMORY` | `16g` | `--memory` / `--memory-swap`. Only enforced with cgroup v2 delegation. |
| `CLAUDE_SANDBOX_CPUS` | unset | `--cpus`. |
| `CLAUDE_SANDBOX_SHM_SIZE` | `2g` | The 64 MB default breaks matplotlib/jupyter. |
| `CLAUDE_SANDBOX_GPU` | `0` | Needs a CDI spec on the host: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`. Whole procedure, including the VM rebuild a GPU requires, in [SERVER.md](SERVER.md#attaching-a-gpu). Missing spec = warns and runs **without** the GPU. |
| `CLAUDE_SANDBOX_RO_MOUNTS` | unset | Space-separated host dirs → `/read-only-reference/<name>`. |
| `CLAUDE_SANDBOX_RW_MOUNTS` | unset | Space-separated host dirs → `/projects/<name>`, read-write. |
| `CLAUDE_SANDBOX_GCP_PROJECT` | unset | Forwarded to host fiss-mcp as `GOOGLE_CLOUD_PROJECT`. Required for the GCS tools. |
| `CLAUDE_SANDBOX_IMAGE_STORE` | `/mnt/sandbox/imagestore` | Shared read-only image store (server deployments). |
| `CLAUDE_NOTIFY_EMAIL` | unset | Leave unset and the notify hooks no-op; no MTA is configured. |

Component toggles — `HEADROOM`, `HEADROOM_PORT`, `FISS_MCP`,
`FISS_MCP_ALLOW_WRITES`, `FISS_MCP_PORT`, `CODEGRAPH`, and the Vertex signals —
are documented with their components in [COMPONENTS.md](COMPONENTS.md). All of
them can be set in `env.<INSTANCE>.sh` to make them sticky for one sandbox.

## Mount layout

Two layouts, picked per launch by `CLAUDE_SANDBOX_USE_SHARED`. Both mount
`$PROJECTS_DIR` at `/workspace` and `$CONTEXT_DIR` at `/context:ro`; they differ
only in where Claude's own state comes from.

**Per-instance (`=0`)** — all state lives in `$SANDBOX_HOME/.claude` for this one
instance. Instances are fully independent and no shared dir is touched.

| Host path | Container path | Holds |
|---|---|---|
| `$SANDBOX_HOME/.claude/` | `/home/claude/.claude` | Everything: settings, memory, sessions, plugins, caches, **OAuth token** |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | Onboarding state, project history |

**Shared (`=1`, what every template sets)** — settings, skills, plugins, hooks,
plans, tasks and sessions come from `$SHARED_HOME`, one copy across all
shared-mode instances. The write-hot paths stay per-instance and bind-mount on top:

| Host path | Container path | Scope |
|---|---|---|
| `$SHARED_HOME/.claude/` | `/home/claude/.claude` | shared |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | per-instance |
| `$SANDBOX_HOME/.claude/cache` | `…/cache` | per-instance |
| `$SANDBOX_HOME/.claude/file-history` | `…/file-history` | per-instance |
| `$SANDBOX_HOME/.claude/backups` | `…/backups` | per-instance |
| `$SANDBOX_HOME/.claude/shell-snapshots` | `…/shell-snapshots` | per-instance |
| `$SANDBOX_HOME/.claude/session-env` | `…/session-env` | per-instance |
| `$SANDBOX_HOME/.claude/projects` | `…/projects` | per-instance — session transcripts |
| `$SANDBOX_HOME/.claude/history.jsonl` | `…/history.jsonl` | per-instance |

`.claude.json` and `projects/` are per-instance because they are rewritten on
every change and hold per-project `allowedTools`/`mcpServers`/history that would
race if shared.

In shared mode the OAuth token lands at `$SHARED_HOME/.claude/.credentials.json`
and is reused by every shared-mode sandbox on the host — log in once. In
per-instance mode each instance logs in separately. Either way the host's
`~/.claude/` is **not** mounted, and nothing else on the host is visible to the
container.

Switching between the two is safe: remove `CLAUDE_SANDBOX_USE_SHARED=1` and the
launcher seeds a copy of the tracked settings and hooks into the per-instance dir
on first launch.

**Concurrency in shared mode.** Hot dirs are per-instance, so no race. Shared
items are write-rare, but two instances writing one file can interleave:
sessions are uuid-named files (practical overlap ~zero); installing a plugin in
one instance while another reads `installed_plugins.json` wants a restart of the
second; memory files are per-file atomic writes.

## Read-only reference mounts

For reference datasets, shared corpora, system config — anything the agent should
read but never mutate. Space-separated **host directories** only; the launcher
picks the container path:

```bash
export CLAUDE_SANDBOX_RO_MOUNTS="/data/reference /srv/corpus /etc/shared-config"
```

Each appears at `/read-only-reference/<name>`, where `<name>` is the host
basename. On collision the launcher prepends parent segments joined by
underscores until every name is unique:

| Host paths | Container paths |
|---|---|
| `/data/reference` `/srv/corpus` | `/read-only-reference/reference` `…/corpus` |
| `/a/b/data` `/x/y/data` | `/read-only-reference/b_data` `…/y_data` |
| `/a/x/foo` `/b/x/foo` | `/read-only-reference/a_x_foo` `…/b_x_foo` |

Paths must be absolute and must already exist — the launcher refuses to start
otherwise, rather than letting the engine create an empty directory in their
place. Each accepted mount prints `ro-mount: <host> -> /read-only-reference/<name>`
at launch.

**Enforcement is at the mount, not the inode.** `:ro` sets `MS_RDONLY`, so every
write returns `EROFS` at the syscall layer — file permissions and `sudo` do not
help. The sandbox is not `--privileged` and grants no `CAP_SYS_ADMIN`, so
`mount -o remount,rw` from inside fails with `EPERM`. Host-side edits are visible
immediately (bind mounts share inodes); that is the operator's channel for
updating reference material.

`/context` uses the same mechanism for the same reason.

## Read-write project mounts, and how pushing works

The agent edits real checkouts in place; **you** push them. The container holds
no git credentials of any kind, so this is enforced by construction rather than by
policy or by asking the agent nicely.

### You usually do not need a mount

`$PROJECTS_DIR` is already mounted as `/workspace`, so cloning a repo there makes
it visible inside with no configuration at all:

```bash
cd /mnt/sandbox/users/$USER/workspace     # already mounted as /workspace
git clone https://github.com/your-org/your-repo
# visible inside at /workspace/your-repo — nothing else to do
```

Reach for `CLAUDE_SANDBOX_RW_MOUNTS` only when a repo must live somewhere *else*:
a checkout shared between users, or one already outside your workspace.

```bash
export CLAUDE_SANDBOX_RW_MOUNTS="$HOME/git/warp $HOME/git/warp-tools"
```

Each surfaces at `/projects/<basename>`, with the same collision handling and
must-already-exist rule as read-only mounts. It ships commented out in both
templates, so out of the box the agent sees only `/workspace`.

Never point it at your own `workspace/` — that mounts the same repo twice, at
`/workspace/<name>` and `/projects/<name>`, which reliably confuses both you and
the agent. On a shared VM, clone onto the data disk rather than `$HOME` either
way: home directories are on the small boot disk, and the data disk is what
survives a rebuild.

Files the agent writes come out owned by **you** on the host, because the
container runs with `--userns=keep-id:uid=1015`. No `sudo`, no ownership repair —
`cd` in and use git normally.

### Authenticating yourself to GitHub

On the host, as your own user — never inside the container:

```bash
command -v gh || sudo apt-get install -y gh
gh auth login --web
gh auth setup-git          # REQUIRED; login alone does not configure git
```

`--web` prints a one-time code you complete in a browser on your own machine,
which is what makes this work on a headless VM. Paste it into the **browser**, not
into a shared terminal or a chat log — it is single-use credential material.

That writes two things, both in your home directory: the token at
`~/.config/gh/hosts.yml`, and a `credential.helper` entry in `~/.gitconfig`.
**Neither is ever mounted into the container.** The host `~/.gitconfig` is
excluded deliberately; only `user.name` and `user.email` are forwarded, as
`SANDBOX_GIT_USER_NAME`/`_EMAIL`, so commits are attributed but unpushable. It
fails twice over: even if a repo's own `.git/config` carried that helper, the
helper shells out to `gh`, which is not in the image.

If `gh auth setup-git` is skipped, or a push touches `.github/workflows/`, see
[the FAQ](FAQ.md#github-and-pushing).

### The loop

```bash
# 1. agent works inside, and commits
./run_claude_docker.sh
#    `git push` cannot authenticate, by design

# 2. exit, and review on the host — same repo, host-side path
cd /mnt/sandbox/users/$USER/workspace/your-repo
git log  --oneline origin/HEAD..HEAD    # what it added
git diff origin/HEAD..HEAD              # what it actually changed

# 3. you push
git push origin HEAD
```

### Two things this does not protect

**Review is the real control.** The credential boundary stops the agent *reaching*
GitHub. It does not stop it authoring something you then push yourself —
including changes to CI workflows or build scripts. `git diff origin/HEAD..HEAD`
before pushing is the actual gate, not the missing token.

**Local git history is unprotected.** In `bypassPermissions` mode, with no
destructive-git deny rules, `git reset --hard`, `git clean -fd`, `branch -D` and
history rewrites all work inside the mounted checkouts. Nothing can leave the
machine, but uncommitted or unpushed work can be destroyed. Commit or stash
anything you cannot lose before a long unattended run.

Deny rules are the only control that still applies in `bypassPermissions` mode, so
to close that gap:

```json
{
  "permissions": {
    "deny": [
      "Bash(git reset --hard:*)",
      "Bash(git clean -fd:*)",
      "Bash(git stash drop:*)",
      "Bash(git stash clear:*)",
      "Bash(git branch -D:*)"
    ]
  }
}
```

`Bash(git push:*)`, `git remote add` and `git remote set-url` are already denied
in the shipped settings — redundant while there is no credential to use, but it
keeps the boundary a stated rule rather than an artefact of what happens not to be
installed.

## Persistence

- **Per-instance mode** — everything in `$SANDBOX_HOME`, preserved across runs of
  that instance only.
- **Shared mode** — settings, skills, plugins, hooks, memory, sessions, plans,
  tasks and onboarding live in `$SHARED_HOME` and are visible to all shared-mode
  instances. Cache, file-history, backups, shell-snapshots, session-env and
  `history.jsonl` stay per-instance.
- **Ephemeral**, gone when the container exits: anything written outside the
  mounts. `uv pip install`, `cargo install`, `sudo apt install`, `/tmp`. To keep
  them, bake them into the image or mount the relevant directory.

## Installing packages

Anything written outside a mount is gone when the container exits, which decides
where a package should go. Three options, in the order you should reach for them.

### What is already there

`/opt/claude-venv` is on `PATH` as `python`, with `numpy`, `pandas`, `scipy`,
`scikit-learn`, `matplotlib`, `seaborn`, `ipython`, `jupyter`, `requests`,
**`anndata`** (plus `h5py`) and **`scanpy[leiden]`** (plus `igraph`, `leidenalg`,
`numba`, `umap-learn`). Verified end to end in the image: normalize → log1p → PCA →
neighbors → leiden → UMAP, with no installing at all.

There is **no pip**, on the host or in the container — all Python is uv-managed.

One pin worth knowing about: `numba<0.67`. Left unconstrained this set resolves to
numpy 2.5.2 with **numba 0.67.0rc1**, because stable numba requires numpy < 2.5 and
uv reaches for a prerelease when nothing stable fits. A release-candidate JIT under
everyone's numerics is a poor default, so the image takes numpy 2.4.6 and numba
0.66.0 instead; scanpy is 1.12.3 either way. (`--prerelease=disallow` is *not* the
tidier fix — measured, it keeps numpy 2.5.2 and instead drags scanpy back to 1.9.8
and numba to 0.53.1.) If a project needs numpy ≥ 2.5, put it in a project venv,
where that decision is local.

### 1. A per-project venv under `/workspace` — the durable option

This is the one to use for real work. `/workspace` is a bind mount, so the venv
survives container exit and is visible to you on the host:

```bash
cd /workspace/your-project
export UV_CACHE_DIR=/workspace/.uv-cache      # so re-installs do not re-download
uv venv .venv
uv pip install --torch-backend cpu scvi-tools # or -r requirements.txt / -e .
.venv/bin/python -c 'import scvi; print(scvi.__version__)'
```

Measured: `scvi-tools` this way took **39 s**, produced a **1.6 GB** venv and a
1.5 GB cache, landed `torch 2.13.0+cpu`, and imported fine from a fresh container.
The venv is owned by you on the host. Add `.venv/` and `.uv-cache/` to the
project's `.gitignore`.

**`--torch-backend cpu` matters on this deployment.** The default resolution pulls
109 packages including 15 `nvidia-*` CUDA wheels — several GB for hardware the
shared VM does not have. With the flag: 90 packages, zero CUDA wheels. uv also
accepts `cu126`, `cu130` and `auto` if you do have a GPU.

`uv` picks up `.venv` in the current directory automatically, which is why
`uv pip install` needs no `--python` here.

### 2. Into the image venv — fine for a throwaway, lost on exit

```bash
uv pip install --python /opt/claude-venv/bin/python anndata
```

This works even on a shared image store, because `/opt/claude-venv` is made
world-writable at build time. But the container filesystem is ephemeral: verified
gone from the next `podman run`. Use it to try something, not to set up a project.

A bare `uv pip install <pkg>` with no venv in the current directory does **not**
silently pick a target — it stops:

```
error: No virtual environment found; run `uv venv` to create an environment,
or pass `--system` to install into a non-virtual environment
```

### 3. Bake it into the image — for what everyone needs

Add it to the `uv pip install` line in `docker/Dockerfile` and rebuild. The test is
whether the dependency closure is cheap **and** shared by everyone:

| | dependency closure | verdict |
|---|---|---|
| `anndata` | ~15 MB with `h5py` | **baked** — every single-cell task starts by opening an `.h5ad` |
| `scanpy[leiden]` | 48 packages against a bare venv, but most were already present; the real additions are `numba`, `llvmlite`, `umap-learn`, `pynndescent`, `igraph`, `leidenalg` | **baked** — ~0.5 GB of image, and it covers most day-to-day work. Installed with the `leiden` extra because bare `scanpy` raises *"Please install the igraph package"* the first time anyone clusters |
| `scvi-tools` | **109 packages**, 15 of them `nvidia-*` CUDA wheels | not baked — several GB, wanted by some projects, version should be pinned per project, and no GPU here to use it |

Those counts are measured with `uv pip install --dry-run scvi-tools`, which resolves
without downloading — worth running before adding anything to the image.

On a shared server users cannot rebuild, so a baked package needs an admin: see
[updating the image](SERVER.md#updating-the-image-later).

### What does not work

`sudo apt install` fails on a shared image store — `sudo` itself cannot run there.
See [in-container root](COMPONENTS.md#in-container-root-works-locally-not-on-a-shared-store).
System packages on a shared host have to be baked in.

## Customizing the image

Edit `docker/Dockerfile` and rebuild:

- **Python packages** — extend the `uv pip install` line. Pin versions there if
  you want reproducibility.
- **System packages** — extend the `apt-get install` line.
- **Java** — change `FROM docker.io/library/eclipse-temurin:17-jdk`.
- **Rust channel** — change `--default-toolchain stable`.
- **Claude Code / CodeGraph versions** — bump `CLAUDE_CODE_VERSION` /
  `CODEGRAPH_VERSION`, then `make rebuild` (plain `make` will not re-fetch a
  cached layer).

```bash
cd docker
make             # cache-friendly; use this 99% of the time
make rebuild     # forced: --no-cache + --pull
make clean       # drop the local tags
```

On a shared server, users cannot build — see
[the shared image store](SERVER.md#the-shared-image-store).
