#!/usr/bin/env bash
set -euo pipefail

# The client's working directory is the project being worked on. Capture it
# before cd'ing into the plugin, or the workspace would default to this repo
# and every relative path would resolve against the wrong root.
workspace="$PWD"

cd "$(dirname "$0")"

# Always rebuild: `zig build` is a no-op when nothing changed, whereas a
# build-if-missing check silently keeps serving a stale binary after every
# source update. A failed build falls back to whatever was built last.
if ! zig build -Doptimize=ReleaseFast >&2; then
  echo "[zig-mcp] Build failed; falling back to the existing binary" >&2
fi

if [ ! -x zig-out/bin/zig-mcp ]; then
  echo "[zig-mcp] No binary to run and the build failed" >&2
  exit 1
fi

# User-supplied arguments come last so an explicit --workspace wins.
exec zig-out/bin/zig-mcp --workspace "$workspace" "$@"
