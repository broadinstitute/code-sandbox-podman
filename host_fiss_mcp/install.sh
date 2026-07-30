#!/usr/bin/env bash
# Idempotent installer for the host-side fiss-mcp server.
#
# Why host-side: keeping fiss-mcp out of the container removes gcloud, gsutil,
# google-cloud-* libs, and ~/.config/gcloud from the agent's reach. The only
# path to Terra/GCP from inside the sandbox is the MCP tools exposed by this
# server, which is read-only by default.
#
# Installs alongside this script (the host_fiss_mcp/ directory in the repo
# checkout). Re-run any time; skips work that is already done.
set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC_DIR="${INSTALL_ROOT}/fiss-mcp"
VENV_DIR="${INSTALL_ROOT}/venv"
REPO_URL="https://github.com/broadinstitute/fiss-mcp.git"

# Pinned release. Bump together with anything that depends on new fiss-mcp
# features. The marker file below keys off this string, so any change here
# triggers a full reinstall on the next setup_host.sh run.
FISS_MCP_REF="1.0.5"
FISS_MCP_REF_COMMIT="ce8097b2126c17166eab565eea5fad8ca9cb5295"

# Interpreter version for the venv.
#
# fiss-mcp declares requires-python >=3.10, but its dependency `firecloud`
# (0.16.x) is a legacy setup.py package and terra-mcp's own classifiers stop
# at 3.12. Hosts whose system python has moved ahead of that — Fedora 44 /
# Nobara 44 ship 3.14 — cannot build the dependency tree. Pin the venv to a
# known-good interpreter instead of inheriting whatever `python3` happens to
# be, and let uv fetch it if the host does not have it.
#
# Override with FISS_MCP_PYTHON=3.11 etc. if a specific version is needed.
FISS_MCP_PYTHON="${FISS_MCP_PYTHON:-3.12}"

# uv is preferred: it resolves and can download the pinned interpreter, so the
# install does not depend on the host having python3.12 preinstalled or on the
# python3-venv package being present. Falls back to `python3 -m venv` when uv
# is absent, which keeps the original Debian/Ubuntu path working unchanged.
UV_BIN="$(command -v uv 2>/dev/null || true)"
PY="${PYTHON:-python3}"

if [[ -z "$UV_BIN" ]]; then
  if ! command -v "$PY" >/dev/null 2>&1; then
    echo "host_fiss_mcp/install.sh: neither uv nor python3 found on PATH" >&2
    exit 1
  fi
  PY_VER=$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  PY_MAJ=${PY_VER%%.*}; PY_MIN=${PY_VER##*.}
  if [[ "$PY_MAJ" -lt 3 ]] || { [[ "$PY_MAJ" -eq 3 ]] && [[ "$PY_MIN" -lt 10 ]]; }; then
    echo "host_fiss_mcp/install.sh: python ${PY_VER} too old; fiss-mcp needs >=3.10" >&2
    exit 1
  fi
  if [[ "$PY_MAJ" -eq 3 ]] && [[ "$PY_MIN" -gt 12 ]]; then
    echo "host_fiss_mcp/install.sh: WARNING — python ${PY_VER} is newer than" >&2
    echo "              fiss-mcp's tested range (<=3.12) and the firecloud" >&2
    echo "              dependency may fail to build. Install uv to get a" >&2
    echo "              pinned ${FISS_MCP_PYTHON} venv instead." >&2
  fi
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "host_fiss_mcp: cloning fiss-mcp into ${SRC_DIR} (ref=${FISS_MCP_REF})"
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

# Pin to the expected release. Fetch the tag if missing (e.g. older clone),
# checkout, then verify the resolved commit matches the recorded SHA. Mismatch
# means the upstream tag was moved — abort rather than silently building a
# different version.
git -C "${SRC_DIR}" fetch --tags --quiet origin
git -C "${SRC_DIR}" checkout --quiet "${FISS_MCP_REF}"
RESOLVED="$(git -C "${SRC_DIR}" rev-parse HEAD)"
if [[ "${RESOLVED}" != "${FISS_MCP_REF_COMMIT}" ]]; then
  echo "host_fiss_mcp: tag ${FISS_MCP_REF} resolved to ${RESOLVED}," >&2
  echo "              expected ${FISS_MCP_REF_COMMIT}. Refusing to build a" >&2
  echo "              non-pinned revision. Re-confirm the upstream tag and" >&2
  echo "              update FISS_MCP_REF_COMMIT in this script." >&2
  exit 1
fi

# A venv is "good" only if both pyvenv.cfg AND bin/pip are present. An
# earlier `python3 -m venv` invocation on a host missing the python3-venv
# package writes pyvenv.cfg before bailing on ensurepip, leaving bin/pip
# absent — a guard that only checked pyvenv.cfg silently skipped recreation
# and the very next line (pip install) failed with "No such file or
# directory". Wipe any partial venv so the create step is forced.
#
# On the uv path the completeness test is bin/python, not bin/pip: `uv venv`
# deliberately does not seed pip into the venv (uv installs packages into it
# from outside). Checking bin/pip there would wipe and recreate a perfectly
# good venv on every run.
if [[ -n "$UV_BIN" ]]; then
  VENV_PROBE="${VENV_DIR}/bin/python"
else
  VENV_PROBE="${VENV_DIR}/bin/pip"
fi

if [[ ! -x "${VENV_PROBE}" ]]; then
  if [[ -e "${VENV_DIR}" ]]; then
    echo "host_fiss_mcp: removing incomplete venv at ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
  fi
  if [[ -n "$UV_BIN" ]]; then
    echo "host_fiss_mcp: creating venv at ${VENV_DIR} (uv, python ${FISS_MCP_PYTHON})"
    "$UV_BIN" venv --python "${FISS_MCP_PYTHON}" "${VENV_DIR}"
  else
    echo "host_fiss_mcp: creating venv at ${VENV_DIR}"
    "$PY" -m venv "${VENV_DIR}"
  fi
fi

# Marker file lets us skip the heavy pip step on repeat runs. The marker
# encodes the pinned ref + resolved commit, so any pin bump forces a
# reinstall on the next setup_host.sh run.
MARKER="${VENV_DIR}/.installed.marker"
EXPECTED_MARKER="fiss-mcp@${FISS_MCP_REF}+${FISS_MCP_REF_COMMIT}"
if [[ ! -f "${MARKER}" ]] || ! grep -q -x -F "${EXPECTED_MARKER}" "${MARKER}"; then
  echo "host_fiss_mcp: installing fiss-mcp + fastmcp into venv"
  if [[ -n "$UV_BIN" ]]; then
    # setuptools<80 first: firecloud builds via legacy setup.py and breaks on
    # setuptools 80+. --no-build-isolation then makes the editable build of
    # fiss-mcp reuse that pinned setuptools instead of pulling a fresh one.
    "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" --quiet "setuptools<80"
    "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" --quiet \
      --no-build-isolation -e "${SRC_DIR}"
  else
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip "setuptools<80"
    "${VENV_DIR}/bin/pip" install --quiet --no-build-isolation -e "${SRC_DIR}"
  fi
  echo "${EXPECTED_MARKER}" > "${MARKER}"
fi

# Import check. The launcher only tests that venv/bin/python exists, so a venv
# that built but cannot import terra_mcp would fail later, inside the 30-second
# server-readiness wait, with a much less obvious error.
if ! "${VENV_DIR}/bin/python" -c 'import terra_mcp.server' 2>/dev/null; then
  echo "host_fiss_mcp: venv built but 'import terra_mcp.server' failed." >&2
  "${VENV_DIR}/bin/python" -c 'import terra_mcp.server' || true
  exit 1
fi

echo "host_fiss_mcp: ready at ${INSTALL_ROOT}"
