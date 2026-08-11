<p align="center">
  <img src="assets/seal_sandbox.png" alt="code-sandbox-podman" width="600">
</p>

# code-sandbox-podman

A **rootless [podman](https://podman.io/)** sandbox for running a coding agent
with filesystem isolation. The container sees a workspace directory you choose
and its own state — the host's home directory, `/etc`, other users, and
everything else stay invisible to the agent.

It carries no credentials. No ssh keys, no `~/.git-credentials`, no `gh`, no
cloud CLIs, no tokens. **The agent can commit; only you can push.** That is
enforced by there being nothing to authenticate with, not by policy.

The image is a batteries-included dev environment (Python via uv, Rust, Java 17,
Node) so `uv pip install` and `cargo install` work inside without a slow first
launch. (`sudo apt install` works on a standalone local install but **not** on the
shared server — see [in-container root](COMPONENTS.md#in-container-root-works-locally-not-on-a-shared-store).)

> A fork of [jonn-smith/claude-docker-sandbox](https://github.com/jonn-smith/claude-docker-sandbox),
> which is Docker-based. This fork is **podman-only** — see [Scope](#scope), and
> [FORK.md](FORK.md) for every change and why.

---

## Two ways to run it

Pick one; they share the same image and launcher but differ in who provisions
what.

| | **A. Standalone local** | **B. Shared server** |
|---|---|---|
| Who | One person on their own machine | Several people on one Linux VM |
| Image | You build it | An admin builds one read-only copy everyone shares |
| State | Anywhere you like | `/mnt/sandbox/users/$USER/` on a data disk |
| Setup | [Local quick start](#a-standalone-local) — three commands | [Per-user setup](#per-user-setup-every-user-does-this-once) — five steps, no root |
| Admin work | none | [SERVER.md](SERVER.md), once |

Both need the same host prerequisites:

- **rootless podman ≥ 5.0** — for the `keep-id:uid=` userns syntax and the pasta
  network backend.
- **`pasta`** (Debian/Ubuntu: `passt`) — how the container reaches the host-side
  Terra MCP server.
- **`/etc/subuid` + `/etc/subgid` ranges** for your user, 65536 wide. Add with
  `sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 $USER`.
  Accounts created by `useradd` get these automatically; OS Login accounts do
  **not** (see [SERVER.md](SERVER.md#ssh-access-and-firewall)).
- **`uv`** — all Python here is uv-managed and there is no pip anywhere.
- **cgroup v2 with the `memory` controller delegated**, if you want
  `CLAUDE_SANDBOX_MEMORY` to be enforced rather than silently ignored.

`./setup_host.sh` checks all of this and **installs nothing** — no packages, no
systemd units, and no writes outside the sandbox tree.

---

## A. Standalone local

```bash
# 1. Configure. Copy a template and edit the paths; env.*.sh is gitignored
#    apart from the tracked *.example.sh files.
cp env.podman.example.sh env.main.sh
$EDITOR env.main.sh
source env.main.sh

# 2. Check the host and build the host-side fiss-mcp venv. Installs nothing.
./setup_host.sh

# 3. Build the image. Takes ~36 minutes and ~9.0 GB the first time.
cd docker && make && cd ..

# 4. Launch.
./run_claude_docker.sh
```

On first launch Claude Code asks you to pick a login method — choose the first
option (Claude account with subscription) and complete the URL-and-code prompt it
shows. No need to type `/login`. The OAuth token persists into that sandbox's own
state directory, so later launches go straight to a session. No host-side Claude
Code install is needed and the host's `~/.claude/` is never mounted.

Then give the agent something to work on — clone into the directory you set as
`CLAUDE_SANDBOX_PROJECTS_DIR`, which is already mounted as `/workspace`:

```bash
cd <your projects dir> && git clone https://github.com/your-org/your-repo
```

**Other ways to launch:**

```bash
./run_claude_docker.sh --continue                  # resume most recent session
./run_claude_docker.sh --resume <session-id>       # resume a specific one
./start_sandbox.sh                                 # fzf menu: instance, session, workdir
```

`start_sandbox.sh` needs `fzf`. It annotates sessions with the host workdir they
ran against, so two `main` sessions are distinguishable. For a second concurrent
sandbox, copy the env file and change `CLAUDE_SANDBOX_INSTANCE`; ports and state
dirs are derived from it.

Everything configurable is in [CONFIG.md](CONFIG.md).

---

## B. Shared server

One VM, one image, many users. Each user provisions themselves with **their own
account only** — no root, and no admin involvement after the machine exists.

An admin does [SERVER.md](SERVER.md) once: create the VM and data disk, install
host packages, build the shared image store, and add each person's SSH key.
Everything below is what a *user* does.

Verified on Debian 13 with podman 5.4.2 and multiple users. Debian 12 cannot host
it (podman 4.3.1); see [Choosing the OS](SERVER.md#choosing-the-os).

### Per-user setup (every user does this once)

Five steps. 1, 4 and 5 are one or two commands each; 2 and 3 are interactive
logins only you can do. Step 1 reprints steps 2-5 when it finishes using the same
numbering as this document, so you can follow either. Following these in order
should require no fixes afterwards — if it does, that is a bug in this document.

Step 1 also clones `warp` and `warp-tools` into your workspace, so step 5 opens
onto real code rather than an empty directory.

Everything of yours lives under `/mnt/sandbox/users/$USER/`: your env file,
workspace, state, Claude token and fiss-mcp venv. Nothing per-user goes in the
shared checkout, and none of it is in `$HOME` — home directories are on the small
boot disk, while the data disk is large and survives a VM rebuild.

```
/mnt/sandbox/users/<user>/          chmod 700
├── env.<user>.sh                   your config; the only place it lives
├── workspace/                      -> /workspace (rw); clone your repos here
├── state/                          per-instance hot state, .claude.json
├── shared/.claude/                 settings, hooks, plugins, YOUR Claude token
└── fiss-mcp/{venv,fiss-mcp}/       your own uv venv and pinned clone
```

**Logging in to the VM does not authenticate you to Google Cloud.** SSH used your
*SSH key* from project metadata, which has nothing to do with your Google
identity. Step 2 is required even though you got in "with GCP".

**0. SSH in — from your own laptop, not from the VM.** Substitute the real
instance name and zone; nothing sets `$VM`/`$ZONE` for you, and the zone is a
*zone*, not a region (`us-central1-c`, not `us-central1`).

```bash
gcloud compute ssh <instance-name> --zone <zone>
```

If you are already on the VM — the Cloud Console *SSH* button works fine — skip
this step. Running it from *inside* the VM fails with `Request had insufficient
authentication scopes`, which is [not about your access](FAQ.md#error-request-had-insufficient-authentication-scopes).

**1. Provision.** Creates your directories on the data disk, seeds your Claude
settings, clones `warp` and `warp-tools` into your workspace, writes your
`env.<USER>.sh`, and enables linger. Authenticates nothing.

```bash
cd /mnt/sandbox/repo        # wherever the admin put the shared checkout
./scripts/provision-sandbox-user.sh
```

**Run this before anything else podman-related.** It writes your
`~/.config/containers/storage.conf`, which is what makes the shared image store
visible to you; without it `podman images` looks empty and `podman run` tries to
pull from a registry.

The two repos are cloned over HTTPS and both are public, so this needs no
credentials — pushing does, which is step 3, and stays a host-side action. They are
full clones, not `--depth 1`, because the review-then-push workflow needs real
history. To change or skip that, set `CLAUDE_SANDBOX_SEED_REPOS` to a
space-separated list of clone URLs, or to the empty string.

**No root, and no sudo.** Everything it touches is your own home or your own
directory on the data disk. If a host-level prerequisite is missing it stops and
prints the exact command an admin should run. It also enables linger, without
which systemd tears down your user slice at logout and kills a long-running agent
mid-task.

**2. Google Cloud.** Both commands print a URL to open on your laptop;
`--no-launch-browser` because the VM is headless.

```bash
gcloud auth login --no-launch-browser
gcloud auth application-default login --no-launch-browser
```

The second one warns that it is "not necessary" on a GCE VM. **Answer `Y`** — that
advice is wrong here, because the VM's service account is a different identity
and is not what has access to your Terra workspaces. fiss-mcp needs *your*
credentials.

`CLAUDE_SANDBOX_GCP_PROJECT` is already set in your rendered `env.<USER>.sh`.
It is needed even though gcloud reports adding a quota project — a quota project
is [not a project source](FAQ.md#fiss-mcp-gcs-tools-fail-with-project-was-not-passed-and-could-not-be-determined-from-the-environment).

**3. GitHub** — to push from this host. Everyone needs this: pushing is what your
host account is *for*, since the agent cannot do it.

```bash
gh auth login --web
gh auth setup-git                              # REQUIRED, separate step
git config --get-all credential.helper         # must print: !/usr/bin/gh auth git-credential
```

`gh auth login` gives *gh* a token; it does not necessarily configure *git*. Skip
`setup-git` and `git push` falls back to asking for a password, which GitHub no
longer accepts. Verify with the `credential.helper` line rather than finding out
at push time. Pushes touching `.github/workflows/` need
[one more scope](FAQ.md#push-rejected-for-a-githubworkflows-change).

This authenticates **you on the host**. The container carries no git credentials,
so `git push` from inside cannot succeed. Commit inside, push outside.

**4. Build your fiss-mcp venv.** Installs nothing system-wide; uv fetches its own
pinned Python 3.12 into your directory.

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./setup_host.sh
```

**5. Launch.** Claude Code authenticates itself on the first run — you do not need
to type `/login`. It shows a login-method picker: choose the **first option**
(Claude account with subscription), and it prints a URL and a code. Open the URL on
your laptop, since the VM is headless, and paste the code there.

The token goes to your own state dir, so later launches start straight into a
session; the host's `~/.claude` is never mounted. `/login` still works if you ever
need to re-authenticate or switch accounts.

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./run_claude_docker.sh
```

Later sessions: `./run_claude_docker.sh --resume <session-id>`. Session IDs are
per-sandbox and invisible to the host's `claude`.

Inside, `/workspace` already contains `warp` and `warp-tools` from step 1, so there
is nothing else to set up before the agent can do useful work.

### Adding more repos

`workspace/` is bind-mounted as `/workspace`, so a clone is all it takes — no mount
configuration, read-write, and files the agent writes stay owned by you:

```bash
cd /mnt/sandbox/users/$USER/workspace
git clone https://github.com/your-org/your-repo
```

You push from the host side at
`/mnt/sandbox/users/$USER/workspace/<repo>`; see
[how pushing works](CONFIG.md#read-write-project-mounts-and-how-pushing-works).

### Installing packages: scvi-tools, worked example

The image already has `numpy`, `pandas`, `scipy`, `scikit-learn`, `matplotlib`,
`seaborn`, `ipython`, `jupyter`, `anndata` and **`scanpy`** (with `igraph` and
`leidenalg`, so clustering works), which covers a lot of single-cell work with no
installing at all.

Heavier, project-specific stacks go in a **venv under `/workspace`**, which is a
bind mount and therefore survives container exit — anything installed elsewhere in
the container is gone when it stops. `scvi-tools` is the case worth spelling out:

```bash
# inside the sandbox
cd /workspace/your-project
export UV_CACHE_DIR=/workspace/.uv-cache      # so re-installs do not re-download
uv venv .venv
uv pip install --torch-backend cpu scvi-tools
.venv/bin/python -c 'import scvi; print(scvi.__version__)'
```

Measured on this deployment: **39 seconds**, a **1.6 GB** venv, and `torch
2.13.0+cpu`. It survives into a fresh container, and `.venv` ends up owned by you on
the host.

**`--torch-backend cpu` is the part not to skip.** Without it you get 109 packages
including 15 `nvidia-*` CUDA wheels — several GB per user, for hardware neither the
shared VM nor most laptops here have. With it: 90 packages, **zero** CUDA wheels.

Add `.venv/` and `.uv-cache/` to the project's `.gitignore`. Pin what you install in
the project's own `pyproject.toml` or `requirements.txt` — the point of a per-project
venv is that two projects can disagree about versions.

Full detail, including why `sudo apt install` is not an option on the shared server,
is in [CONFIG.md](CONFIG.md#installing-packages).

---

## What the isolation does and does not cover

**Covered.** An agent in the sandbox cannot read the host filesystem outside its
own mounts, cannot reach another user's directories on a shared host, cannot
obtain a cloud or git credential, and cannot start a process on the host. There is
no docker or podman socket, no `--privileged`, no added capabilities, no host PID
or network namespace. `sudo` inside grants root *in the container's user
namespace*, which maps to your subuid range and confers nothing outside it. Each
claim is verified by probe in
[the FAQ](FAQ.md#can-an-agent-reach-another-users-sandbox-on-a-shared-host).

**Deliberately not covered.**

- **Humans on a shared VM can read each other's directories via `sudo`.** Every
  metadata-SSH-key user on a GCE VM lands in `google-sudoers`. Accepted: co-users
  are trusted people. Agents are not, and they are what the boundary is for.
  If you would rather your *own* agent sessions could not do that either, run them
  from a `useradd` account, which gets no `google-sudoers` and needs no sudo to run
  the sandbox — see
  [running agents as a sudo-less account](SERVER.md#logging-in-to-a-sudo-less-agent-account).
- **Review is the real control on what leaves the machine.** The agent cannot
  reach GitHub, but it can author something you then push — including CI workflow
  changes. `git diff origin/HEAD..HEAD` before pushing is the gate.
- **Local git history is unprotected.** Under `bypassPermissions`,
  `git reset --hard` and friends work inside the mounted checkouts. Nothing leaves
  the machine, but unpushed work can be destroyed. [Deny rules close
  this](CONFIG.md#two-things-this-does-not-protect).
- **Network egress is unrestricted.** The agent can reach the Anthropic API, npm,
  PyPI, crates.io and the open internet. The goal is filesystem isolation, not a
  firewall. Combine with `--network none` or a restricted network if you need it.

## What you get beyond the isolation

- **[fiss-mcp](https://github.com/broadinstitute/fiss-mcp)** for Terra, running on
  the **host** rather than in the container — so the sandbox has no `gcloud`, no
  `gsutil` and no credentials, and the MCP tools are the only path to Terra/GCP.
  Read-only by default; the write tools are not registered at all unless you opt
  in.
- **[CodeGraph](https://github.com/colbymchenry/codegraph)** MCP: a pre-indexed
  tree-sitter code graph, so symbol and call-tree questions do not become
  grep+Read chains. Auto-indexes per workdir.
- **[Headroom](https://github.com/chopratejas/headroom)** prompt-compression proxy,
  off by default.
- **Two skill plugins, vendored** so a fresh clone needs no network round-trip and
  every user of a shared image runs identical versions:
  [caveman](https://github.com/JuliusBrussee/caveman) (prompt compression) and
  [ponytail](https://github.com/DietrichGebert/ponytail) (writes less code for the
  same result). Both on by default, both pinned by commit SHA and re-checked at
  container boot — see [PLUGIN_PINS.md](claude-sandbox-shared/.claude/PLUGIN_PINS.md).
- **Email notification** for prompts that outlive a threshold (default 120 s),
  off unless `CLAUDE_NOTIFY_EMAIL` is set.
- **Resource ceilings** — `--memory`, `--cpus`, `--shm-size`, enforced through
  cgroup v2.

Details and toggles: [COMPONENTS.md](COMPONENTS.md).

## Documentation

| Document | What is in it |
|---|---|
| [CONFIG.md](CONFIG.md) | Every environment variable, mount layouts, read-only/read-write mounts, the push workflow, installing packages, persistence |
| [COMPONENTS.md](COMPONENTS.md) | What is in the image, fiss-mcp, CodeGraph, Headroom, Vertex mode |
| [SERVER.md](SERVER.md) | Admin guide for the shared VM: disk, instance, users, image store, capacity, rebuilds |
| [FAQ.md](FAQ.md) | Every error we hit, with the diagnosis that turned out to be right |
| [FORK.md](FORK.md) | What changed from upstream, and the measurements behind each decision |

## Scope

**Supported:** rootless podman ≥ 5.0 on Linux, with pasta and cgroup v2.
Developed on Nobara 44 (Fedora 44 base) with podman 5.8.4 and deployed on Debian
13 (trixie) with podman 5.4.2. Nothing is distro-specific beyond package names —
what matters is the podman version, pasta, and subuid ranges. An
SELinux-enforcing host additionally needs `:z` on the bind mounts, which is not
handled yet.

**Not supported: Docker.** Upstream's Docker path still exists in the code — every
podman change is gated on `CLAUDE_SANDBOX_ENGINE` — but `podman` is the default,
nothing here is tested against Docker, and the Docker path depends on
[sysbox-runc](https://github.com/nestybox/sysbox), which has no podman equivalent.
Treat `CLAUDE_SANDBOX_ENGINE=docker` as inherited, unverified code. If you want
Docker, use upstream.

**Not supported: macOS.** Removed rather than left to rot: the macOS helper
installed Docker Desktop or OrbStack, which is a different engine, and every
`IS_DARWIN` branch is gone from the launcher. `./setup_host.sh` exits with a
pointer to upstream on a Darwin host. podman does run there via `podman machine`,
but `--userns=keep-id` mapping and pasta loopback forwarding behave differently
inside that VM, so claiming support would be a guess.

**Dropped on this path:**

| Upstream feature | Status | Why |
|---|---|---|
| sysbox-runc runtime | removed | Docker-only shim needing rootful `dockerd`. Rootless podman's user namespace already provides the isolation this depends on. |
| Docker-in-Docker | removed | Without sysbox a nested daemon cannot mount overlay2. `SANDBOX_HAS_DIND=0`. |
| host postfix / email relay | not set up | Only feeds the optional notify hooks, which no-op when `CLAUDE_NOTIFY_EMAIL` is unset. |
| GPU passthrough | opt-in, off | Rootless podman needs a CDI spec and `--device`, not `--gpus`. `CLAUDE_SANDBOX_GPU=1`. |

## License

[PolyForm Shield License 1.0.0](https://polyformproject.org/licenses/shield/1.0.0)
— see [LICENSE.md](LICENSE.md). Use, modify and redistribute freely for any
purpose **except** providing a product that competes with this software. Standard
fair-use rights are preserved.
