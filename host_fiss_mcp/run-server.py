#!/usr/bin/env python3
"""Host-side launcher for fiss-mcp over HTTP.

fastmcp's `fastmcp run` CLI imports the server module, which skips the
__main__ block in terra_mcp.server.py — so its `--allow-writes` argparse
flag never runs. We reuse the same module-level `mcp` object but set
`ALLOW_WRITES` from env, then drive the HTTP transport directly via
`mcp.run(transport='http', ...)`.

Env vars:
  FISS_MCP_HOST              bind host  (default 127.0.0.1)
  FISS_MCP_PORT              bind port  (default 39000)
  FISS_MCP_PATH              HTTP path  (default /mcp/)
  FISS_MCP_ALLOW_WRITES      "1" enables Terra write tools (default 0)
  FISS_MCP_ALLOW_HOST_WRITES "1" re-enables download_gcs_file (default 0)

Why download_gcs_file is removed by default
-------------------------------------------
This server runs ON THE HOST, as the invoking user, with that user's gcloud
credentials. The container reaches it over a loopback port forward. That is the
whole design: no cloud credential ever enters the sandbox.

`download_gcs_file` breaks it. It takes an agent-supplied `local_path`
("Absolute local destination path"), calls `os.makedirs(parent, exist_ok=True)`
and then `blob.download_to_filename(local_path)` — all host-side, as the user.
An agent in the sandbox can therefore create directories and overwrite files
anywhere the user can write: `~/.bashrc`, `~/.gitconfig`, `~/.ssh/`, the
checkout, another user's directory if permissions allow. That is a filesystem
write primitive OUTSIDE the sandbox, which is a stronger capability than the
bucket writes `FISS_MCP_ALLOW_WRITES` exists to gate.

And `FISS_MCP_ALLOW_WRITES=0` does not stop it. Upstream classes it as a read
tool, so it carries no `_check_write_access` guard — it is the only one of the 21
tools that writes to the host, and the only write-capable tool that is ungated.
Verified by auditing every tool for `download_to_filename` / `os.makedirs` /
`open(..., "w")`.

Removed here rather than by patching the vendored source, because the checkout is
pinned by SHA and `install.sh` verifies it. Set FISS_MCP_ALLOW_HOST_WRITES=1 to
put it back, but understand that this grants the agent host write access.

Agents needing file contents should use `read_gcs_object`, which returns bytes
over MCP and writes nothing.
"""

from __future__ import annotations

import os
import sys

import terra_mcp.server as server

allow_writes = os.environ.get("FISS_MCP_ALLOW_WRITES", "0") == "1"
server.ALLOW_WRITES = allow_writes

allow_host_writes = os.environ.get("FISS_MCP_ALLOW_HOST_WRITES", "0") == "1"

HOST_WRITE_TOOLS = ("download_gcs_file",)

removed: list[str] = []
if not allow_host_writes:
    for tool_name in HOST_WRITE_TOOLS:
        try:
            if hasattr(server.mcp, "remove_tool"):
                server.mcp.remove_tool(tool_name)
            elif hasattr(server.mcp, "local_provider") and hasattr(server.mcp.local_provider, "remove_tool"):
                server.mcp.local_provider.remove_tool(tool_name)
            elif hasattr(server.mcp, "_local_provider") and hasattr(server.mcp._local_provider, "remove_tool"):
                server.mcp._local_provider.remove_tool(tool_name)
            else:
                # Try to remove directly from internal components dict if all else fails
                found = False
                for attr in ("_components", "_tools", "tools"):
                    if hasattr(server.mcp, "local_provider") and hasattr(server.mcp.local_provider, attr):
                        d = getattr(server.mcp.local_provider, attr)
                        if isinstance(d, dict) and f"tool:{tool_name}" in d:
                            del d[f"tool:{tool_name}"]
                            found = True
                        elif isinstance(d, dict) and tool_name in d:
                            del d[tool_name]
                            found = True
                if not found:
                    raise AttributeError(f"Could not find a way to remove '{tool_name}' in this FastMCP version.")

            removed.append(tool_name)
        except Exception as exc:  # noqa: BLE001
            # Loud, and fatal. Silently serving a tool that can write to the
            # host would defeat the isolation this sandbox exists for, so refuse
            # to start rather than start weaker than advertised.
            print(
                f"host_fiss_mcp: FATAL — could not remove host-write tool "
                f"{tool_name!r}: {type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            print(
                "host_fiss_mcp: refusing to start. Set "
                "FISS_MCP_ALLOW_HOST_WRITES=1 only if you intend the agent to "
                "be able to write to the host filesystem.",
                file=sys.stderr,
                flush=True,
            )
            raise SystemExit(1) from exc

host = os.environ.get("FISS_MCP_HOST", "127.0.0.1")
port = int(os.environ.get("FISS_MCP_PORT", "39000"))
path = os.environ.get("FISS_MCP_PATH", "/mcp/")

mode = "WRITE" if allow_writes else "read-only"
print(
    f"host_fiss_mcp: starting on http://{host}:{port}{path} ({mode})",
    file=sys.stderr,
    flush=True,
)
if removed:
    print(
        "host_fiss_mcp: host-write tools removed: " + ", ".join(removed),
        file=sys.stderr,
        flush=True,
    )
else:
    print(
        "host_fiss_mcp: WARNING — FISS_MCP_ALLOW_HOST_WRITES=1; the agent CAN "
        "write files to the host filesystem via download_gcs_file.",
        file=sys.stderr,
        flush=True,
    )

server.mcp.run(transport="http", host=host, port=port, path=path)
