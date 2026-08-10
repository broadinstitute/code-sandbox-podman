<p align="center">
  <img src="assets/seal_sandbox.png" alt="code-sandbox-podman" width="600">
</p>

# code-sandbox-podman

A **rootless [podman](https://podman.io/)** sandbox for running a coding agent with
local filesystem isolation. The container sees only a designated workspace
directory and its own persistent state — the host's home directory, `/etc`, and
everything else on the host stay invisible to the agent.

The image is a batteries-included dev environment, so `uv pip install`,
`cargo install`, and `sudo apt install` work without network delay on launch.

Python is managed entirely by **uv**. The venv at `/opt/claude-venv` is built
with `uv venv` against a uv-pinned CPython 3.12 rather than the base image's
python3, and there is no pip anywhere in the toolchain — on the host or in the
container.

> **This fork is podman-only.** It is a fork of
> [jonn-smith/claude-docker-sandbox](https://github.com/jonn-smith/claude-docker-sandbox),
> which is Docker-based and assumes a Debian/Ubuntu host. See
> [Scope](#scope) for exactly what that means and
> [FORK.md](FORK.md) for every change and why.

## Scope

**Supported:** rootless podman >= 5.0 on a Fedora/RHEL-family host.
Developed and verified on Nobara 44 (Fedora 44 base) with podman 5.8.4.

**Not supported: Docker.** Upstream's Docker path still exists in the code —
every podman change is gated on `CLAUDE_SANDBOX_ENGINE`, and setting it to
`docker` will take the original branches. But `podman` is now the **default**,
nothing in this fork is tested against Docker, and the Docker path depends on
[sysbox-runc](https://github.com/nestybox/sysbox), which has no podman
equivalent and is not installed here. Treat `CLAUDE_SANDBOX_ENGINE=docker` as
inherited, unverified code rather than a supported configuration. If you want
Docker, use upstream — it is better maintained for that case.

**Not supported: macOS.** Removed outright rather than left to rot — the
`setup_host.sh` macOS helper installed Docker Desktop or OrbStack, which is not
this engine, and every `IS_DARWIN` branch has been deleted from the launcher.
`./setup_host.sh` now exits with a pointer to upstream on a Darwin host. podman
itself does run on macOS via `podman machine`, but the two mechanisms this
sandbox depends on — `--userns=keep-id` uid mapping and pasta loopback
forwarding — behave differently inside that VM and are untested, so claiming
support would be a guess.

**Deliberately dropped on this path:**

| Upstream feature | Status here | Why |
|---|---|---|
| sysbox-runc runtime | removed | Docker-only OCI shim; needs rootful `dockerd` plus its own daemons. Rootless podman's user namespace already provides the host-filesystem isolation this sandbox depends on. |
| Docker-in-Docker | removed | Without sysbox a nested daemon cannot mount overlay2. `SANDBOX_HAS_DIND=0`. |
| host postfix / email notifications | not set up | Only feeds the optional notify hooks. Leave `CLAUDE_NOTIFY_EMAIL` unset and they no-op. |
| GPU passthrough | opt-in, off | Rootless podman needs a CDI spec and `--device`, not `--gpus`. Enable with `CLAUDE_SANDBOX_GPU=1`. |

## Using it with agents other than Claude Code

The isolation is **agent-agnostic**. Nothing about the security model is
Claude-specific — it is all engine-level and would hold for any process:

- rootless podman user namespace, so the host filesystem is unreachable
- `--userns=keep-id` so written files stay owned by the invoking user
- explicit bind mounts as the only way in or out
- `--memory` / `--cpus` ceilings enforced via cgroup v2
- no credentials in the image: no ssh keys, no `~/.git-credentials`, no `gh`,
  no cloud CLIs, no tokens — so `git push` to an authenticated remote cannot
  succeed from inside, by construction rather than by policy

What *is* Claude-specific is the tooling layered on top: the pinned
`@anthropic-ai/claude-code` install in `docker/Dockerfile`, the MCP wiring and
plugin-pin checks in `docker/start_script.sh`, and the `.claude` state layout
the launcher mounts.

To host a different agent, add its runtime to the Dockerfile and swap the final
`claude "$@"` in `docker/start_script.sh` for that agent's entrypoint. The
launcher, mount layout, resource limits and host-side
[fiss-mcp](https://github.com/broadinstitute/fiss-mcp) bridge need no changes —
they only care that *something* runs in the container. Expect to add tools: the
image ships Python, Node, Rust, Java and the usual CLI kit, but an agent with
different expectations will want its own.

# Features
This carries a heavy image and is shaped around its authors' needs. You may
still find it useful.

Beyond the normal setup and build features, this sandbox has:
- Automated email notifications for prompts that take longer than <CONFIGURABLE> seconds to complete (default 120)
- A built-in, pre-configured [headroom](https://github.com/chopratejas/headroom) installation (runtime-disable-able)
- A built-in [fiss-mcp](https://github.com/broadinstitute/fiss-mcp) server for interacting with Terra. The server runs on the **host**, not inside the container, so the sandbox has no `gcloud` / `gsutil` / `google-cloud-*` libs and no `~/.config/gcloud` mount — the only path from inside the sandbox to Terra/GCP is the MCP tools the server exposes. Read-only by default; opt-in write mode via `FISS_MCP_ALLOW_WRITES=1`, which prints a loud red ASCII-art banner on the host **and** inside the container so it is impossible to miss (banner is pre-rendered, no `figlet` dependency).
- A built-in [CodeGraph](https://github.com/colbymchenry/codegraph) MCP server (stdio, in-container) that gives the agent a pre-indexed tree-sitter code graph — `codegraph_search`, `codegraph_callers`, `codegraph_callees`, `codegraph_impact`, etc. — instead of grep+Read chains. Maintainer benchmarks claim ~58% fewer tool calls and ~16% cheaper turns (directional, single-author). Index is auto-built on first session per workdir via a SessionStart hook and kept current by an in-process file watcher. Disable per-launch with `CODEGRAPH=0`.
- The [caveman](https://github.com/JuliusBrussee/caveman) compression plugin **vendored at v1.8.2** under `claude-sandbox-shared/.claude/plugins/marketplaces/caveman/`. No network round-trip at first session — fresh clones get the plugin source directly. Enabled by default at intensity `full` (tracked via `.caveman-active`), with the `[CAVEMAN]` chip wired into the statusline. Override per session with `/caveman lite|full|ultra` or `stop caveman`. Bump procedure in `claude-sandbox-shared/.claude/PLUGIN_PINS.md`.
- An interactive launcher (`start_sandbox.sh`) that lets you pick instance, resume an existing Claude session, and choose a workdir from an fzf menu, instead of hand-sourcing `env.<INSTANCE>.sh` and running `run_claude_docker.sh` directly.

I've tried to include everything I need for my typical work.

User-facing scripts (`./setup_host.sh`, `./run_claude_docker.sh`,
`./start_sandbox.sh`) detect the host and dispatch internally; you never invoke
a platform-specific script directly. On a host with podman, `setup_host.sh`
routes to `scripts/setup_host_podman.sh`, which **verifies rather than
installs** — it adds no packages, no systemd units, and writes nothing outside
the sandbox tree.

> **Tested configuration** —
> - **Nobara 44** (Fedora 44 base), x86_64, **podman 5.8.4 rootless**,
>   netavark + pasta, cgroup v2 with the `memory` controller delegated,
>   SELinux disabled.
>
> Other Fedora/RHEL-family hosts should work through the same codepath. An
> SELinux-enforcing host will additionally need `:z` on the bind mounts — that
> is not handled yet. macOS is not supported and its code paths are gone; the
> Docker path survives only behind `CLAUDE_SANDBOX_ENGINE=docker` and is
> untested here. See [Scope](#scope).

## Quick start (fresh clone)

```bash
# 1. Verify host prerequisites and build the host-side fiss-mcp venv.
#    Installs nothing and changes no system state.
source env.podman.example.sh   # or your env.<INSTANCE>.sh
./setup_host.sh

# 2. Build the image
# NOTE: This step takes ~2200s or 36 minutes.
cd docker && make && cd ..

# 3. Launch the default "main" shared-mode instance.
#    env.example.sh defaults to in-repo workspace/ + context_reference/.
source env.example.sh
./run_claude_docker.sh
```

First launch in any sandbox prompts `/login` inside the container. The resulting OAuth token persists into that sandbox's state dir (`claude-sandbox-shared/.claude/.credentials.json` in shared mode, `claude-sandbox-persistent-state-<INSTANCE>/.claude/.credentials.json` in per-instance mode), so subsequent launches of the same sandbox skip the login. No host-side Claude Code install is required, and credentials are not shared with the host's `~/.claude/`.

### Interactive launcher (alternative to step 4)

`start_sandbox.sh` opens an fzf menu: pick instance, optionally resume an existing Claude session, pick a workdir, launch. It seeds workdir candidates from any `env.*.sh` plus every workdir you've previously picked (master registry at `workdirs.txt`). Sessions are annotated with their host workdir in the picker so you can tell two `main` sessions apart by what they were operating on.

```bash
./start_sandbox.sh
```

### Multi-instance mode

For a second concurrent instance, copy the template and change the instance name:

```bash
cp env.example.sh env.B.sh
$EDITOR env.B.sh   # set CLAUDE_SANDBOX_INSTANCE=B (and PROJECTS_DIR if different)
source env.B.sh && ./run_claude_docker.sh
```

`env.*.sh` (other than `env.example.sh`) is gitignored — your per-instance files won't accidentally land in commits.

For details on per-instance vs shared layouts and parallel launches, see [Mounts](#mounts).

## What's in the image

Base: `node:22-slim`.

- **Claude Code CLI** — `claude`, installed globally via npm.
- **Python 3** — venv at `/opt/claude-venv` (on `PATH`, writable by the sandbox user), preloaded with: `numpy`, `pandas`, `matplotlib`, `scipy`, `scikit-learn`, `seaborn`, `ipython`, `jupyter`, `requests`, `headroom-ai[proxy]`.
- **Rust** — stable toolchain (`rustc`, `cargo`, `rustup`) at `/usr/local/{cargo,rustup}`.
- **Java 17** — Eclipse Temurin JDK at `/opt/java/openjdk`, `JAVA_HOME` exported.
- **CodeGraph** — `codegraph` binary (self-contained bundle, vendored Node runtime) at `/usr/local/bin/codegraph` → `/opt/codegraph/current/bin/codegraph`. Version pinned via `CODEGRAPH_VERSION` in `docker/Dockerfile`; bump + `make rebuild` to refresh.
- **Dev tooling** — `git`, `curl`, `ripgrep`, `vim`, `build-essential`.
- **Passwordless `sudo`** for the container's `claude` user (uid 1015). On the podman path the invoking user is mapped onto that uid by `--userns=keep-id:uid=1015`, so files written to mounts stay owned by the invoker on the host and no `usermod` runs. `HOST_UID` / `HOST_GID` are passed empty; they only drive the remap on upstream's Docker path.

Image size: **8.68 GB** as built here. (Upstream's README says ~3 GB; the
measured size of this build is well above that.)

## Prerequisites

### Host requirements

A Fedora/RHEL-family host running rootless podman. Verified on Nobara 44
(Fedora 44 base) with podman 5.8.4. No Docker, no sysbox-runc, and nothing
needs installing on the host beyond podman itself.

- **podman >= 5.0.** Needs the `keep-id:uid=` userns syntax (podman 4.3+) and
  the pasta network backend (podman 5 default).
- **`/etc/subuid` + `/etc/subgid`** must have a range for your user, 65536
  wide. Add with
  `sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 $USER`.
- **cgroup v2 with the `memory` controller delegated** to the user slice, if
  you want `CLAUDE_SANDBOX_MEMORY` to be enforced rather than ignored.
- **`uv`** (recommended) so the host fiss-mcp venv gets a pinned Python 3.12.
- Run `./setup_host.sh` — it dispatches to `scripts/setup_host_podman.sh`
  whenever podman is present. That helper only **verifies**: it installs no
  packages, adds no systemd units, and writes nothing outside the sandbox tree.
- Build with `make` (podman is the default; `make ENGINE=docker` would take
  upstream's path, which is untested here).

### Why this differs from upstream

For readers arriving from upstream. This is a summary; [FORK.md](FORK.md) has
the full reasoning and the measurements behind each row.

| Concern | Docker path | podman path |
|---|---|---|
| Runtime | `--runtime=sysbox-runc` | none. Sysbox is a Docker-only runtime shim needing rootful `dockerd` plus its own daemons; no podman equivalent exists. Rootless podman's user namespace already puts the host filesystem out of reach, which is the isolation property this sandbox depends on. |
| UID mapping | `usermod` in `uid-fixup-entrypoint.sh`, driven by `HOST_UID`/`HOST_GID` | `--userns=keep-id:uid=1015,gid=1015` pins the invoker onto the image's baked `claude` uid. `HOST_UID`/`HOST_GID` are passed empty so the entrypoint no-ops through to `exec gosu claude`. Without this, rootless podman maps the invoker to container root and everything written to `/workspace` lands under a subuid the host user cannot read. |
| Docker-in-Docker | works under sysbox | **unavailable.** `SANDBOX_HAS_DIND=0`; no DinD volume is created or mounted. Plain runc cannot mount overlay2 for a nested dockerd. |
| Reaching host services (fiss-mcp, vertex_proxy) | bind to the docker bridge gateway, container connects to `host.docker.internal` | bind to `127.0.0.1`; container connects to `127.0.0.1` through a pasta forward (`--network=pasta:-T,<port>`). Measured: pasta `-T` reaches a loopback-bound listener, while both `host.containers.internal` and `host.docker.internal:host-gateway` get connection-refused because they resolve to a non-loopback host address. The forward keeps the listener strictly on loopback — tighter than the bridge-gateway bind, not looser. |
| GPU | `--gpus all` on plain runc | opt-in via `CLAUDE_SANDBOX_GPU=1`, needs a CDI spec (`sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`) and uses `--device nvidia.com/gpu=all`. Off by default. |
| Mail relay | host postfix, configured by `setup_host_linux.sh` | not set up. Leave `CLAUDE_NOTIFY_EMAIL` unset; the notify hooks no-op and `start_script.sh` tolerates postfix failing to start. |
| Login/group step | requires log out + log back in for the `docker` group | none — rootless podman uses no group membership. |


- No host-side Claude Code install required. Each sandbox prompts `/login` on its own first launch and stores the resulting OAuth token inside its own state dir (`claude-sandbox-shared/.claude/.credentials.json` in shared mode, `claude-sandbox-persistent-state-<INSTANCE>/.claude/.credentials.json` in per-instance mode). The host's `~/.claude/` is NOT mounted into the container.

## Running on a GCP VM (multi-user)

Verified end to end on `warp-pipeline-dev`. Every value below was checked against
a real deployment rather than copied from Google's docs.

### Why Debian 13 and not 12

The host needs **podman >= 5** with a current **pasta**. Debian 12 (bookworm)
ships podman **4.3.1** (`libpod 4.3.1+ds1-8+deb12u1`) and a passt snapshot from
March 2023, so `setup_host.sh` refuses it and the launcher's
`--network=pasta:-T,<port>` forward does not exist. Debian 13 (trixie) ships
podman **5.4.2** and current passt, and has no SELinux to relabel mounts for.

RHEL 10 / Rocky 10 also satisfy the version requirement, but SELinux is
enforcing there and the bind mounts would need `:z`, which this fork does not
handle yet. Fedora Cloud is not in GCP's standard image projects.

### Disk: a separate data disk is mandatory, not optional

The image is **8.08 GiB**. A default 10 GB boot disk leaves ~6.4 GB free, so it
does not fit at all — and `make rebuild` transiently needs room for a second
copy. Create the data disk **independently of the instance** so it survives a
VM rebuild:

```bash
gcloud compute disks create sandbox-data \
  --zone us-central1-c --size 200GB --type pd-balanced
```

Sizing: `8 GB image + 8 GB rebuild headroom + ~2 GB per user`. Measured per-user
footprint is fiss-mcp venv 122 MB, uv's pinned Python 112 MB, checkout 33 MB,
plus workspaces and session transcripts (one real session was 3.8 MB). 200 GB
covers 10-20 users comfortably; 100 GB is the floor. Use `pd-balanced` rather
than `pd-standard` — IOPS scale with size, and image builds plus CodeGraph
indexing are IO-bound.

### Create the instance

```bash
gcloud compute instances create warp-claude-sandbox-2 \
  --zone us-central1-c \
  --machine-type e2-highmem-8 \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced \
  --network warp-firewall-network --subnet warp-firewall-network \
  --disk name=sandbox-data,device-name=sandbox-data,mode=rw,auto-delete=no
```

Notes that cost real debugging time:

* **`--network` / `--subnet` are required** if the project has no `default`
  network. Without them the create fails with
  `Invalid value for field 'resource.networkInterfaces[0].network' ... cannot be
  found`. Copy the values from a working instance:
  `gcloud compute instances describe <vm> --format="yaml(networkInterfaces)"`.
* **`auto-delete=no`** on the data disk. This is what makes future VM rebuilds
  cheap: delete the instance, keep the data.
* **50 GB boot, not 10.** Home directories live on the boot disk.
* **Keep the external IP.** There is no Cloud NAT in this project (no routers at
  all), so a `--no-address` instance would have no outbound internet, and the
  sandbox needs egress for npm, pip, GitHub and the Anthropic API. The org
  firewall policy does permit the IAP range, so
  `gcloud compute ssh --tunnel-through-iap` works — but only with an external IP
  present, absent a NAT.
* The instance gets a **fresh ephemeral IP**. Reserve one with
  `gcloud compute addresses create ... --region us-central1` and pass
  `--address` if several people will be connecting.

### Format and mount the data disk

Attaching a disk does not format or mount it. Do this once:

```bash
# The boot disk may enumerate as /dev/sdb, putting the data disk on /dev/sda.
# The by-id path is stable, so device order does not matter.
lsblk; ls -l /dev/disk/by-id/google-sandbox-data

sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \
  /dev/disk/by-id/google-sandbox-data

sudo mkdir -p /mnt/sandbox
echo "UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/google-sandbox-data) \
/mnt/sandbox ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a && df -h /mnt/sandbox

sudo mkdir -p /mnt/sandbox/users
sudo chmod 751 /mnt/sandbox /mnt/sandbox/users   # traversable, not listable
```

`nofail` is deliberate: without it a missing or renamed disk wedges boot, which
is painful on a box where you may only have root.

### SSH access and firewall

Check the **effective** firewalls, not just the VPC rules —
`gcloud compute firewall-rules list` does not show org-level policies:

```bash
gcloud compute instances network-interfaces get-effective-firewalls \
  <vm> --zone <zone> --network-interface nic0
```

On this org an **org-level firewall policy** allows ingress from the
institution's IP ranges and from the IAP range `35.235.240.0/20`, with **no
target tags**, so it covers every VM. That is why the instances here carry no
network tags even though the VPC-level tcp:22 rule requires a `broad-allow`
tag — that rule is redundant. Do not assume tags are unnecessary on another org
without running the command above.

### Users

Access is by **project metadata SSH keys**, which is also what makes rootless
podman work:

```bash
gcloud compute project-info add-metadata \
  --metadata-from-file ssh-keys=all-keys.txt
```

The Google guest agent creates each key's user with `useradd`, and `useradd`
allocates `/etc/subuid` + `/etc/subgid` ranges from `login.defs`. Rootless
podman requires those ranges. Confirm for any user with:

```bash
grep "^$USER:" /etc/subuid /etc/subgid     # e.g. rcox:624288:65536
```

**Do not switch to OS Login for this.** OS Login users resolve through NSS with
no `/etc/passwd` entry, so they get **no subuid ranges** and rootless podman
fails for them. There is no clean upstream fix: shadow-utils >= 4.9 supports a
pluggable `subid:` NSS database, but the only shipped provider is SSSD's
`libsubid_sss.so`, which needs FreeIPA/LDAP; podman has ignored `subid: sss`
outright in some versions (containers/podman#25041); and Red Hat documents that
enabling NSS subid *breaks* rootless podman for local users
(access.redhat.com/solutions/6961540). Making OS Login work would mean a
`pam_exec` hook allocating ranges at first login — workable, but a broken PAM
stack locks everyone out.

### Admin: one-time host setup

Debian's cloud image is minimal — nothing container-related ships by default.

```bash
sudo apt-get update
sudo apt-get install -y \
  podman passt uidmap fuse-overlayfs crun \
  dbus-user-session slirp4netns \
  git jq fzf gh
```

Every package is load-bearing:

| package | why it is needed |
|---|---|
| `podman` | 5.4.2 in trixie; the launcher requires >= 5 |
| `passt` | provides `pasta`, which `--network=pasta:-T` needs to reach host fiss-mcp |
| `uidmap` | `newuidmap`/`newgidmap`. **Rootless podman fails outright without it** |
| `fuse-overlayfs`, `crun` | rootless storage driver and OCI runtime |
| `dbus-user-session` | systemd user session; `loginctl enable-linger` does not hold without it |
| `git`, `jq`, `fzf` | repo operations, host-side JSON, the `start_sandbox.sh` menu |
| `gh` | GitHub CLI (2.46.0 in trixie) for each user's `gh auth login` |

Then **uv**, which is not packaged in Debian. Install it once, system-wide, so
every user has it rather than each running a `curl | sh`:

```bash
curl -LsSf https://github.com/astral-sh/uv/releases/download/0.12.3/uv-x86_64-unknown-linux-gnu.tar.gz \
  | sudo tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/uv' '*/uvx'
uv --version
```

This extracts a binary rather than piping a script into `sudo sh`. **uv is
required, not optional:** trixie's python3 is 3.13, and `terra-mcp` depends on
`firecloud` 0.16.x — a legacy `setup.py` package that will not build on 3.13.
uv fetches a pinned 3.12 interpreter, which is the only reason the host venv
builds at all. `host_fiss_mcp/install.sh` fails with instructions if uv is absent.

Finally, put the checkout somewhere every user can read:

```bash
sudo git clone https://github.com/broadinstitute/code-sandbox-podman /opt/code-sandbox-podman
cd /opt/code-sandbox-podman/docker && sudo make && cd ..
```

The image is built once by an admin. Users do not need to build it, and if the
image store is shared read-only (below) they cannot.

### Per-user setup (every user does this once)

Five steps. Steps 1 and 5 are one command each; 2 and 3 are the interactive
logins only you can do.

**Important:** logging in to this VM does **not** authenticate you to Google
Cloud. SSH used your *SSH key* from project metadata, which has nothing to do
with your Google identity. fiss-mcp reads credentials from your own
`~/.config/gcloud`, so step 2 is required even though you got in "with GCP".

```bash
# 0. ssh in
gcloud compute ssh warp-claude-sandbox-2 --zone us-central1-c
```

**1. Provision.** Creates your directories on the data disk, seeds your Claude
settings, writes your `env.<USER>.sh`, and enables linger. Authenticates nothing.

```bash
cd /opt/code-sandbox-podman        # wherever the shared checkout lives
./scripts/provision-sandbox-user.sh
```

It stops with an explanation if anything is missing — notably a `/etc/subuid`
range, without which rootless podman cannot work at all.

**2. Google Cloud.** Both commands print a URL: open it on your laptop, paste
the code back. `--no-launch-browser` because the VM is headless.

```bash
gcloud auth login --no-launch-browser
gcloud auth application-default login --no-launch-browser
```

Then set your project in `env.<USER>.sh`:

```bash
export CLAUDE_SANDBOX_GCP_PROJECT=<project where you have serviceusage.services.use>
```

Without it, fiss-mcp's four GCS tools fail with `Project was not passed and could
not be determined from the environment`. Note that
`gcloud auth application-default set-quota-project` does **not** satisfy this —
it sets `quota_project_id`, but `google.auth.default()` still returns
`project=None`.

**3. GitHub** (skip if you never push from this host):

```bash
gh auth login --web
```

Prints a one-time code; open the URL on your laptop. This also configures git's
credential helper, so HTTPS pushes work afterwards. An SSH key is the
alternative, but `--web` avoids generating and registering one.

This authenticates **you on the host**. The container deliberately carries no
git credentials — no ssh keys, no `~/.git-credentials`, no `gh`, no tokens — so
`git push` from inside the sandbox cannot succeed. **Commit inside, push
outside.** That is the design: the agent can write code and history, and a human
decides what leaves the machine.

**4. Build your fiss-mcp venv.** Installs nothing system-wide; uv fetches its own
pinned Python 3.12 into your directory.

```bash
source env.$USER.sh
./setup_host.sh
```

**5. Launch.** On the very first run, type `/login` inside to authenticate Claude
Code. The token is stored in your own state dir; the host's `~/.claude` is never
mounted.

```bash
./run_claude_docker.sh
```

Later sessions resume with `./run_claude_docker.sh --resume <session-id>`.
Session IDs are per-sandbox and are not visible to the host's `claude`.

#### What each user gets

```
/mnt/sandbox/users/<user>/          chmod 700 — other users cannot read it
├── workspace/                      -> /workspace  (rw) — provision this yourself
├── state/                          per-instance hot state, .claude.json
├── shared/.claude/                 settings, hooks, plugins, YOUR Claude token
└── fiss-mcp/{venv,fiss-mcp}/       your own uv venv and pinned clone
```

Nothing of one user's is reachable by another, and none of it is in `$HOME` —
home directories are on the small boot disk, and the 8.33 GB image plus
workspaces do not fit there.

#### Adding a user

Append their public key to the project metadata; the Google guest agent creates
the account with `useradd`, which is what allocates the `/etc/subuid` ranges
rootless podman needs:

```bash
gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items.filter(\"key:ssh-keys\").extract(\"value\"))" > keys.txt
printf '%s\n' "newuser:ssh-rsa AAAA... newuser@laptop" >> keys.txt
gcloud compute project-info add-metadata --metadata-from-file ssh-keys=keys.txt
```

They then run the five steps above. No admin action beyond the key.

### Capacity, not disk, is the real limit

`e2-highmem-8` is 8 vCPU / 64 GB. At the default `CLAUDE_SANDBOX_MEMORY=16g`
that is about **3 concurrent sandboxes** before the host is oversubscribed. For
more simultaneous users drop the per-user cap to `8g` or size the machine up —
a config change, not a rebuild. Confirm the cap is actually enforced, because
without cgroup v2 delegation the flag is silently ignored:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
# must list `memory`
```

Also run `loginctl enable-linger $USER` so a user's containers and their
host-side fiss-mcp survive their SSH session closing.

## Build

```bash
cd docker
make             # cache-friendly build — use 99% of the time
make rebuild     # forced: --no-cache + --pull base image
make clean       # drop the local tags so the next `build` starts clean
```

Tags the image as `claude-sandbox:0.0.1` and `claude-sandbox:latest`. First build pulls the Temurin JDK image, the Rust toolchain, and a few hundred MB of Python wheels — expect several minutes.

Use `make rebuild` when you need a newer Claude Code from npm (the `RUN npm install -g @anthropic-ai/claude-code` layer is unpinned, so cache-friendly builds will not re-fetch it), when bumping `CODEGRAPH_VERSION` in the Dockerfile, when base-image security updates need to land, or when the cache feels stale.

## Run

The launcher script (`run_claude_docker.sh`) forwards any arguments to `claude` inside the container:

```bash
./run_claude_docker.sh                                     # fresh session
./run_claude_docker.sh --continue                          # resume most recent
./run_claude_docker.sh --resume <session-id>               # resume specific
./run_claude_docker.sh --dangerously-skip-permissions      # no prompts
./run_claude_docker.sh --continue --dangerously-skip-permissions
```

To drop into a shell instead of `claude`, change the trailing `claude "$@"` in `run_claude_docker.sh` to `/bin/bash`.

## Headroom proxy (token compression)

The image bundles [Headroom](https://github.com/chopratejas/headroom), a local HTTP proxy that compresses prompts, tool outputs, and history before forwarding to the Claude API. Off by default. Toggle per launch:

```bash
HEADROOM=1 ./run_claude_docker.sh                  # on
./run_claude_docker.sh                             # off
HEADROOM=1 ./run_claude_docker.sh --continue       # on + resume
HEADROOM_PORT=9000 HEADROOM=1 ./run_claude_docker.sh   # custom port
```

How it works: when `HEADROOM=1`, `start_script.sh` launches `headroom proxy` on `127.0.0.1:$HEADROOM_PORT` (default 8787) and exports `ANTHROPIC_BASE_URL` so `claude` routes through it. The proxy applies AST-aware code compression, JSON-output stripping, prompt-cache prefix alignment, and recovery-on-demand for dropped messages, then forwards to `api.anthropic.com` using the existing OAuth token. Process dies with the container; nothing persists across runs. Stats: `curl http://127.0.0.1:8787/stats` from inside the container.

Trust model: the proxy reads every byte of every request — that's how compression works. It runs entirely inside the same container as `claude`, so it sees the same OAuth token Claude already has and no wider trust boundary is opened. Code is Apache-2.0; pin the version in `Dockerfile`. If you don't want a third-party dep in the request path, leave `HEADROOM` unset and traffic goes direct.

Per-instance default: add `export HEADROOM=1` to the matching `env.<INSTANCE>.sh` to make it sticky for that sandbox.

## CodeGraph MCP (in-container, stdio)

The image bakes the [CodeGraph](https://github.com/colbymchenry/codegraph) bundle into `/opt/codegraph` and symlinks `codegraph` onto `PATH`. Pinned via `ENV CODEGRAPH_VERSION=v0.9.9` in `docker/Dockerfile` — bump that line and `make rebuild` to land a newer release. The bundle ships its own Node runtime, so there is no Node/npm dependency at runtime.

On every container boot, `start_script.sh` registers `mcpServers.codegraph` in `~/.claude.json` (same idempotent jq pattern as fiss-mcp). Claude Code then spawns `codegraph serve --mcp` as a stdio subprocess per session; the subprocess dies with `claude`, so there is no orphan daemon. A file watcher inside the MCP server (inotify, 2 s debounce) keeps the SQLite index live as files change.

Auto-index per workdir: the SessionStart hook `claude-sandbox-shared/.claude/hooks/codegraph-init.sh` detached-spawns `codegraph init -i` when `/workspace` is a git repo **and** `/workspace/.codegraph/codegraph.db` is missing. Indexing runs in the background; the prompt does not block on it. MCP queries during the initial index return partial results. Subsequent sessions in the same workdir reuse the existing index, and the live watcher handles incremental updates. Skip indexing for a specific workdir by `touch /workspace/.codegraph-disable`.

```bash
./run_claude_docker.sh             # codegraph on (default)
CODEGRAPH=0 ./run_claude_docker.sh # disable MCP registration this launch
```

The agent gets MCP tools `codegraph_search`, `codegraph_callers`, `codegraph_callees`, `codegraph_impact`, `codegraph_explore`, `codegraph_node`, `codegraph_files`, and `codegraph_status` — designed to replace grep+Read chains for symbol lookup and call-tree navigation. The index lives in `/workspace/.codegraph/` so it persists across container restarts via the workdir bind mount. Add `.codegraph/` to your per-repo `.gitignore` so the SQLite file does not land in commits.

Resource cost: ~50 MB image bundle; idle MCP server ~80-150 MB RSS while a session is open; ~1-10 MB SQLite DB per 100k LOC; CPU spike only on file change. Initial index of a fresh medium-sized repo is seconds to a couple of minutes.

## fiss-mcp (Terra MCP server) — runs on the host

The launcher spawns [fiss-mcp](https://github.com/broadinstitute/fiss-mcp) as a host-side HTTP MCP server before starting the container, then advertises its URL to the container via `FISS_MCP_URL`. The in-container `start_script.sh` registers an HTTP MCP entry in `~/.claude.json` pointing at `http://host.docker.internal:<PORT>/mcp/`. When `run_claude_docker.sh` exits (or you ^C it), a bash `EXIT` trap kills the host process.

**Why host-side**: the container never sees `gcloud`, `gsutil`, `google-cloud-*` libs, `~/.config/gcloud`, or any service-account key file. The agent's only reachable path to Terra/GCP is the MCP tools the host server exposes — which are read-only by default. There is no shell-level bypass.

**Install**: `setup_host.sh` runs `host_fiss_mcp/install.sh` once. It clones fiss-mcp into `host_fiss_mcp/fiss-mcp/` (next to the script in this repo) and creates a venv at `host_fiss_mcp/venv/` — both gitignored — so everything is self-contained inside the checkout and isolated from any other Python install on the host. The venv is pinned to Python 3.12 and built with `uv`, which downloads that interpreter if the host lacks it — `terra-mcp` depends on `firecloud` 0.16.x, a legacy `setup.py` package that will not build on newer interpreters such as Fedora 44's 3.14. Nothing is installed system-wide. If you launch `run_claude_docker.sh` with `FISS_MCP=1` and the install dir is absent, the run script errors out and tells you to run `./setup_host.sh`.

The installer pins fiss-mcp to a specific release tag **and** verifies the resolved commit SHA against a recorded value. If the upstream tag has been moved, the install aborts rather than silently building a different version. A marker file in the venv encodes the pinned ref + SHA; a re-install runs automatically the next time you bump either constant in `host_fiss_mcp/install.sh`.

**Auth**: the host server inherits the host's gcloud credentials directly — no mount, no env var forwarding. Set up once on the host:

```bash
gcloud auth login                              # user creds (the Terra-registered identity)
gcloud auth application-default login          # ADC (FISS uses this)
```

On a GCE VM with a default service account, the metadata server is picked up automatically — but Terra is user-identity-based, so a workspace-registered Google account is generally required.

**Toggle and write-access:**

```bash
./run_claude_docker.sh                            # fiss-mcp on, read-only (default)
FISS_MCP=0 ./run_claude_docker.sh                 # off (no spawn, no registration)
FISS_MCP_ALLOW_WRITES=1 ./run_claude_docker.sh    # on, WRITE MODE (loud banner)
```

> **Warning**: `FISS_MCP_ALLOW_WRITES=1` lets the agent submit workflows, mutate workspace attributes, and spend money on your Terra/GCP account. Both `run_claude_docker.sh` and `start_script.sh` print a red ASCII-art banner (pre-rendered figlet output, no host or image dependency) when write mode is on, on the host and inside the container respectively, so the warning shows up no matter where you're reading the terminal.

**Ports**: each instance gets a deterministic port in `39000-39999` hashed from `CLAUDE_SANDBOX_INSTANCE`, so concurrent sandboxes don't collide. Override with `FISS_MCP_PORT=<port>` if the auto-pick clashes with something else on the host.

**Container connectivity**: on the podman path the host server binds to `127.0.0.1` and the container reaches it through a pasta port forward (`--network=pasta:-T,<port>`), so the listener never leaves loopback. `--add-host=host.docker.internal:host-gateway` is still declared so the name resolves, but it is not the transport — measured on a loopback-bound listener, both `host.docker.internal` and `host.containers.internal` get connection-refused because they resolve to a non-loopback host address.

**Bind address**: the host server binds **only** the docker bridge gateway IP (auto-detected via `docker network inspect bridge`), not `0.0.0.0` and not `127.0.0.1`. That's the same address the container reaches us at via `host.docker.internal`, so container ingress is unchanged — but the listener is not present on `eth0` / `wlan0` / any external interface, so no iptables fence is required to keep it off the host's outside-world network. If the bridge gateway can't be determined (broken docker setup), the launcher fails fast rather than silently widening the bind to `0.0.0.0`.

**Lifecycle**: trap on `EXIT INT TERM` kills the host fastmcp process. If the launcher is `kill -9`'d, the orphan can be reaped with `pkill -f run-server.py`. The MCP log lives at `${SANDBOX_HOME}/.claude/host_fiss_mcp.log`.

Per-instance default: set `FISS_MCP` / `FISS_MCP_ALLOW_WRITES` / `FISS_MCP_PORT` in `env.<INSTANCE>.sh`.

## Vertex AI mode (Google Cloud auth)

The sandbox can route `claude` traffic through [Google Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/use-claude) instead of the default Anthropic API. Same security pattern as fiss-mcp: the gcloud-shaped pieces (access-token mint, GCP service-account or ADC creds) stay on the **host** — the container has no `gcloud`, no `google-cloud-*` libs, and no `~/.config/gcloud` mount. A small host-side script (`vertex_proxy.py`) accepts Anthropic-shape POST bodies, strips the incoming Authorization header, signs with a fresh `gcloud auth print-access-token`, and forwards to Vertex.

**Architecture (Option B — chained, compression-compatible):**

```
claude (Anthropic mode, in container)
   └─ ANTHROPIC_BASE_URL = headroom (when HEADROOM=1) or vertex_proxy (when HEADROOM=0)
        └─ headroom (in container, optional)
             └─ ANTHROPIC_TARGET_API_URL = vertex_proxy URL
                  └─ vertex_proxy.py (on host, gcloud token mint)
                       └─ Vertex AI
```

`claude` does **NOT** run in Vertex SDK mode. It stays in standard Anthropic mode, sending Anthropic-shape POST bodies. Vertex's `:rawPredict` endpoint accepts the Anthropic Messages body format unchanged, so no body translation is needed at any hop. The host proxy replaces the auth header — compression and routing stay orthogonal.

**Activate**: copy the template, edit your project id, source it, launch:

```bash
cp SET_VERTEX_MODE.example.sh SET_VERTEX_MODE.sh
$EDITOR SET_VERTEX_MODE.sh           # set ANTHROPIC_VERTEX_PROJECT_ID and CLOUD_ML_REGION
source SET_VERTEX_MODE.sh
./run_claude_docker.sh               # optionally HEADROOM=1 for compression
```

`SET_VERTEX_MODE.sh` is gitignored — your real project id won't accidentally land in a commit. To go back to default Anthropic-API (subscription) mode, `source UNSET_VERTEX_MODE.sh` (or open a fresh shell).

**Toggle**: per-launch, not mid-session. claude reads env at startup. Different `env.<INSTANCE>.sh` files can pin different modes (one sandbox always Vertex, another always subscription).

| HEADROOM | USE_VERTEX | Flow |
|---|---|---|
| 0 | 0 | claude → api.anthropic.com (OAuth, no compression) |
| 1 | 0 | claude → headroom → api.anthropic.com (OAuth + compression) |
| 0 | 1 | claude → vertex_proxy → Vertex (gcloud token, no compression) |
| 1 | 1 | claude → headroom → vertex_proxy → Vertex (gcloud token + compression) |

**Requires gcloud on the host**: the proxy mints OAuth tokens via `gcloud auth print-access-token`. `setup_host.sh` checks for `gcloud` on `PATH` at install time and prints a warning if missing — it does **not** install gcloud automatically (picking a distribution channel is a host-policy decision). On a workstation, install the SDK from your distro or [Google's instructions](https://cloud.google.com/sdk/docs/install), then:

```bash
gcloud auth login
gcloud auth application-default login
```

The launcher refuses to start in Vertex mode if `gcloud` isn't on `PATH`, or if `ANTHROPIC_VERTEX_PROJECT_ID` / `CLOUD_ML_REGION` are unset.

**How the container is wired**: when `CLAUDE_CODE_USE_VERTEX=1` is present in the launching shell, `run_claude_docker.sh`:

1. Spawns `vertex_proxy.py` bound only to the docker bridge gateway IP, on a per-instance hashed port in `38000-38999` (disjoint from fiss-mcp's 39xxx range).
2. Waits for it to come up, registers a trap on `EXIT INT TERM` so the proxy dies with the launcher.
3. Forwards `ANTHROPIC_TARGET_API_URL=http://host.docker.internal:<port>` into the container — that env var is read by **headroom** (`--backend anthropic` mode, the default) and overrides its upstream from `api.anthropic.com` to the host proxy.
4. Also forwards `ANTHROPIC_MODEL` and `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (orthogonal to Vertex). Does **not** forward `CLAUDE_CODE_USE_VERTEX` itself — that's a launcher-side signal only.

When HEADROOM=0, `start_script.sh` instead sets `ANTHROPIC_BASE_URL=$ANTHROPIC_TARGET_API_URL` so `claude` bypasses the (absent) headroom and hits the host proxy directly.

**Bind address**: same model as fiss-mcp — bridge gateway IP only, never `0.0.0.0`. Launcher fails fast if the bridge IP can't be determined.

**Port override**: `VERTEX_PROXY_PORT=<port>` on the launcher line picks a specific port if the auto-pick clashes.

**Log**: `${SANDBOX_HOME}/.claude/host_vertex_proxy.log`. Tail this when debugging auth failures or upstream Vertex errors.

**fiss-mcp and Vertex are orthogonal** — you can run both simultaneously (separate processes, separate port ranges, separate trap cleanups) or either alone.

Per-instance default: add `source SET_VERTEX_MODE.sh` at the top of `env.<INSTANCE>.sh` if you want a specific sandbox to always run in Vertex mode.

## Mounts

Two layout modes, picked per launch by `CLAUDE_SANDBOX_USE_SHARED`:

- **Per-instance (`=0` or unset)** — full Claude state lives in `$SANDBOX_HOME/.claude` for this one instance. Instances are fully independent. No shared dir touched.
- **Shared (`=1`)** — settings/skills/plugins/hooks/plans/tasks/sessions come from `$SHARED_HOME` (one copy across all shared-mode instances). `.claude.json` plus write-hot dirs (cache, file-history, backups, shell-snapshots, session-env, projects, history.jsonl) stay in `$SANDBOX_HOME` and bind-mount on top of the shared `.claude`. `.claude.json` and `projects/` are per-instance because they're rewritten on every change and hold per-project allowedTools/mcpServers/history/transcripts that would race if shared.

The example envs (`env.example.sh`, `env.B.sh`, `env.WHB.sh`, `env.GATK.sh`, `env.main.sh`) all set `CLAUDE_SANDBOX_USE_SHARED=1` — shared is the de-facto default on this checkout. The code-level fallback (when neither set nor sourced) is per-instance.

### Per-instance mode (default)

| Host path | Container path | Purpose |
|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | Read/write workspace. CWD on launch. |
| `$SANDBOX_HOME/.claude/` | `/home/claude/.claude` | All Claude state (settings, memory, sessions, plugins, caches, **OAuth token**). |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | Onboarding state, project history. |

The host's `~/.claude/` is NOT mounted. The OAuth token from `/login` lands at `$SANDBOX_HOME/.claude/.credentials.json` (inside the directory mount above) and stays scoped to this sandbox.

(fiss-mcp / Terra creds are **not** mounted — the MCP server runs on the host. See [fiss-mcp section](#fiss-mcp-terra-mcp-server--runs-on-the-host).)

### Shared mode (opt-in)

| Host path | Container path | Scope |
|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | per-instance (caller-supplied) |
| `$SHARED_HOME/.claude/` | `/home/claude/.claude` | shared — settings, skills, plugins, hooks, projects, plans, tasks, sessions |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | per-instance — onboarding state, per-project allowedTools/mcpServers/history. Rewritten whole on every change, would race if shared. |
| `$SANDBOX_HOME/.claude/cache` | `/home/claude/.claude/cache` | per-instance |
| `$SANDBOX_HOME/.claude/file-history` | `/home/claude/.claude/file-history` | per-instance |
| `$SANDBOX_HOME/.claude/backups` | `/home/claude/.claude/backups` | per-instance |
| `$SANDBOX_HOME/.claude/shell-snapshots` | `/home/claude/.claude/shell-snapshots` | per-instance |
| `$SANDBOX_HOME/.claude/session-env` | `/home/claude/.claude/session-env` | per-instance |
| `$SANDBOX_HOME/.claude/projects` | `/home/claude/.claude/projects` | per-instance — Claude session transcripts (one jsonl per session, plus `.workdir` sidecar files written by `start_sandbox.sh` so the picker can show which host workdir each session ran against) |
| `$SANDBOX_HOME/.claude/history.jsonl` | `/home/claude/.claude/history.jsonl` | per-instance |

The OAuth token from `/login` lands inside the shared `.claude/` (at `$SHARED_HOME/.claude/.credentials.json`) and is therefore shared across every shared-mode sandbox on this host — log in once, every shared-mode instance reuses the token. The host's `~/.claude/` is NOT mounted.

`$SHARED_HOME` defaults to `claude-sandbox-shared/` next to `run_claude_docker.sh` (override: `CLAUDE_SANDBOX_SHARED`). `$SANDBOX_HOME` defaults to `claude-sandbox-persistent-state-${CLAUDE_SANDBOX_INSTANCE}/` (override: `CLAUDE_SANDBOX_HOME`). Both must be absolute paths.

Nothing else on the host is visible to the container.

### Adopting shared mode safely (no risk to existing instances)

Opt a sandbox into shared mode by adding `export CLAUDE_SANDBOX_USE_SHARED=1` to its `env.<INSTANCE>.sh` (the bundled `env.*.sh` files already do this). First launch on a fresh clone uses the tracked `claude-sandbox-shared/.claude/` (CLAUDE.md, settings.json, hooks, skills, **vendored caveman plugin source**, caveman defaults) directly; subsequent launches reuse it. Switch back to per-instance any time by removing that line — `run_claude_docker.sh` will seed a copy of the tracked settings + hooks into the per-instance dir on first launch (`seed_settings` / `seed_hooks`).

### Concurrency caveats (shared mode)

Hot dirs are per-instance — no race. Shared items are write-rare in practice, but two shared-mode instances writing the same file at the same time can interleave or last-write-wins:

- **Sessions**: each session is its own file (`sessions/<id>.json`). Two instances using the same session id concurrently would corrupt it. Sessions are uuid-named so practical overlap is near zero.
- **Plugin install/upgrade**: if you install a plugin in one instance while another reads `installed_plugins.json`, restart the second to pick it up cleanly.
- **Memory (`projects/`)**: per-file atomic writes; rare contention.

## Read-only reference mounts

Optional caller-supplied read-only bind mounts for reference datasets, shared corpora, system config — anything the agent should be able to read but never mutate. Set `CLAUDE_SANDBOX_RO_MOUNTS` in your `env.<INSTANCE>.sh` to a **space-separated list of host directories** (no container path — the launcher picks one):

```bash
export CLAUDE_SANDBOX_RO_MOUNTS="/data/reference /srv/corpus /etc/shared-config"
```

Each entry shows up at `/read-only-reference/<name>` inside the container, where `<name>` is the host basename by default. On basename collision, the launcher prepends parent-dir segments joined by underscores until every name is unique:

| Host paths | Container paths |
|---|---|
| `/data/reference` `/srv/corpus` | `/read-only-reference/reference` `/read-only-reference/corpus` |
| `/a/b/data` `/x/y/data` | `/read-only-reference/b_data` `/read-only-reference/y_data` |
| `/a/x/foo` `/b/x/foo` `/c/x/foo` | `/read-only-reference/a_x_foo` `/read-only-reference/b_x_foo` `/read-only-reference/c_x_foo` |

Each accepted mount prints `ro-mount: <host> -> /read-only-reference/<name>` at launch.

**Validation** (CRITICAL ERROR on failure):
- Absolute paths only.
- Host path must already exist on disk — refuses to launch otherwise so Docker doesn't auto-create the source as a directory (same trap the `check_not_directory` guard protects against on the credentials side).

**Enforcement**: the `:ro` flag sets `MS_RDONLY` on the mount in the container's mount namespace. Every write attempt (`open(O_WRONLY)`, `unlink`, `rename` into the tree) returns `EROFS` at the syscall layer — file permissions and `sudo` don't help because the restriction is at the mount, not the inode. The sandbox does not run `--privileged` and does not grant `CAP_SYS_ADMIN`, so a `mount -o remount,rw` from inside also fails with `EPERM`. Host-side edits to the directory are visible to the container immediately (bind mount shares inodes); that's the operator's intentional channel for updating reference material.

The interactive launcher (`start_sandbox.sh`) shows a one-line `RO mounts` summary in each area's preview pane — count + first three basenames.

## Persistence

- **Per-instance mode** — everything in `$SANDBOX_HOME` (settings + state + sessions + caches), preserved across runs of that instance only.
- **Shared mode** — settings, skills, plugins, hooks, memory, sessions, plans, tasks, onboarding live in `$SHARED_HOME` (visible to all shared-mode instances). Cache, file-history, backups, shell-snapshots, session-env, history.jsonl stay per-instance.
- **Shared with the host**: OAuth credentials (single token refreshed by whichever process needs it first).
- **Ephemeral** (gone on `--rm` container exit): anything written outside the mounts — `uv pip install`, `cargo install`, `sudo apt install`, files in `/tmp`, etc. If you want these to persist, either rebuild the image with them baked in, or add the relevant directories (e.g. `/opt/claude-venv`, `/usr/local/cargo`) as additional mounts.

## Customization

- **Add Python packages**: extend the `uv pip install` line in the `Dockerfile` and rebuild. Pin versions there if you want reproducibility (`numpy==1.26.4`, etc.).
- **Add system packages**: extend the `apt-get install` line.
- **Switch Java versions**: change the `FROM eclipse-temurin:17-jdk AS temurin` line to e.g. `21-jdk`.
- **Rust channels**: change `--default-toolchain stable` to `nightly` or a specific version.

## Isolation scope

This sandbox restricts **filesystem access only**. Network access from inside the container is unrestricted — the agent can reach the Claude API, npm, PyPI, crates.io, and the open internet. This is intentional: the goal is to keep the agent out of the host's home directory and system files, not to firewall its tool use. If you need network restrictions too, combine this with `--network none`, a custom Docker network, or the official Claude Code devcontainer's firewall (which is a separate, more restrictive setup).

## Adapting paths for your machine

Paths are driven by environment variables — nothing is hardcoded in `run_claude_docker.sh`. Set these in your `env.<INSTANCE>.sh` (start from `env.example.sh`):

- `CLAUDE_SANDBOX_PROJECTS_DIR` — host dir mounted at `/workspace` (required).
- `CLAUDE_SANDBOX_CONTEXT_DIR` — host dir mounted at `/context` (required).
- `CLAUDE_SANDBOX_INSTANCE` — unique instance name (required; suffixes container, DinD volume, state dir).
- `CLAUDE_SANDBOX_HOME` — override the per-instance state dir (default: `claude-sandbox-persistent-state-<INSTANCE>/` alongside the launcher).
- `CLAUDE_SANDBOX_SHARED` — override the shared dir in shared mode (default: `claude-sandbox-shared/`).

Per-instance overrides also cover `HEADROOM`, `HEADROOM_PORT`, `FISS_MCP`, `FISS_MCP_ALLOW_WRITES`, `FISS_MCP_PORT`, `CODEGRAPH` (set `=0` to skip CodeGraph MCP registration in that sandbox), `CLAUDE_SANDBOX_USE_SHARED`, `CLAUDE_SANDBOX_RO_MOUNTS` (space-separated host directories — no container path; each shows up at `/read-only-reference/<basename>` inside the container, with parent-dir prefixes underscored on collision; host paths must exist or the launcher refuses), and the Vertex-mode launcher signals (`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `VERTEX_PROXY_PORT`) — set whichever you want sticky for that sandbox.

## License

[PolyForm Shield License 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) — see [LICENSE.md](LICENSE.md). Use, modify, and redistribute freely for any purpose **except** providing a product that competes with this software. Standard fair-use rights are preserved.
