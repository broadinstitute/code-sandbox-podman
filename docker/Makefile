VERSION = 0.0.1
TAG1 = claude-sandbox:$(VERSION)
TAG2 = claude-sandbox:latest

# Container engine. Override for rootless podman hosts (Fedora/RHEL family,
# where Docker is not installed and sysbox-runc does not exist):
#     make ENGINE=podman
# or export CLAUDE_SANDBOX_ENGINE=podman before calling make. Base images in
# the Dockerfile are fully qualified (docker.io/library/...) because podman
# runs with short-name-mode="enforcing" on those distros and would otherwise
# block on an interactive registry prompt.
ENGINE ?= $(if $(CLAUDE_SANDBOX_ENGINE),$(CLAUDE_SANDBOX_ENGINE),docker)

# Centralized build flags so `build` and `rebuild` share everything except
# cache behavior.
BUILD_FLAGS = -t $(TAG1) -t $(TAG2)

.PHONY: all build rebuild clean

all: build

# Cache-friendly build. Use this 99% of the time.
build:
	$(ENGINE) build $(BUILD_FLAGS) .

# Forced rebuild: ignore layer cache AND re-pull the base image. Use when:
#   - you need a newer @anthropic-ai/claude-code from npm (Dockerfile:21 is
#     unpinned, so `npm install -g` only re-fetches when the layer is busted)
#   - base image security updates need to land
#   - cache feels stale (mystery breakages, "but it works locally")
rebuild:
	$(ENGINE) build --no-cache --pull $(BUILD_FLAGS) .

# Drop the image tags so the next `build` starts clean. Does NOT prune
# dangling layers — run `docker image prune` separately if you want that.
clean:
	-$(ENGINE) rmi $(TAG1) $(TAG2)
