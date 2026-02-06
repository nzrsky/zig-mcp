#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Build on first run (or after clean)
if [ ! -f zig-out/bin/zig-mcp ]; then
  echo "[zig-mcp] Building from source..." >&2
  zig build -Doptimize=ReleaseFast >&2
  echo "[zig-mcp] Build complete" >&2
fi

exec zig-out/bin/zig-mcp "$@"
