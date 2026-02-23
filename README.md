# zig-mcp

MCP server for Zig that connects AI coding assistants to [ZLS](https://github.com/zigtools/zls) via the Language Server Protocol.

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Cursor, Windsurf, and any MCP-compatible client.

```
AI assistant  <--(MCP stdio)-->  zig-mcp  <--(LSP pipes)-->  ZLS
                                    |
                             zig build / test / check
```

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2+
- [ZLS](https://github.com/zigtools/zls/releases) (auto-detected from trusted fixed locations, or specify with `--zls-path`)

When you set `--zig-path`, point it to a Zig binary from a full Zig distribution directory (with sibling `lib/`), not a standalone copied binary.

## Install

### Claude Code plugin (recommended)

Install directly from the Claude Code interface — no manual build needed:

```bash
# 1. Add the marketplace
/plugin marketplace add nzrsky/zig-mcp

# 2. Install the plugin
/plugin install zig-mcp@zig
```

Or as a one-liner from the terminal:

```bash
claude plugin marketplace add nzrsky/zig-mcp && claude plugin install zig-mcp@zig
```

The binary is built automatically on first use. Just make sure `zig` and `zls` are in your PATH.

### Manual build

```bash
git clone https://github.com/nzrsky/zig-mcp.git
cd zig-mcp
zig build -Doptimize=ReleaseFast
```

Binary is at `zig-out/bin/zig-mcp`.

## Setup (manual install only)

If you installed via the plugin system, skip this section — everything is configured automatically.

### Claude Code

```bash
# add globally
claude mcp add zig-mcp -- /absolute/path/to/zig-mcp --workspace /path/to/your/zig/project

# add for current project only
claude mcp add --scope project zig-mcp -- /absolute/path/to/zig-mcp --workspace /path/to/your/zig/project
```

Or edit `~/.claude/mcp_servers.json`:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "command": "/absolute/path/to/zig-mcp",
      "args": ["--workspace", "/path/to/your/zig/project"]
    }
  }
}
```

> If you omit `--workspace`, zig-mcp uses the current working directory.

### Cursor

Add to `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "command": "/absolute/path/to/zig-mcp",
      "args": ["--workspace", "/path/to/your/zig/project"]
    }
  }
}
```

### Windsurf

Add to `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "command": "/absolute/path/to/zig-mcp",
      "args": ["--workspace", "/path/to/your/zig/project"]
    }
  }
}
```

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.zig-mcp]
command = "/absolute/path/to/zig-mcp"
args = [
  "--workspace", "/path/to/your/zig/project",
  "--allow-command-tools",
  "--zig-path", "/usr/bin/zig",
]
```

### Options

```
--workspace, -w <path>   Project root directory (default: cwd)
--zls-path <path>        Path to ZLS binary (default: trusted fixed locations)
--zig-path <path>        Path to zig binary (required with --allow-command-tools)
--zvm-path <path>        Path to zvm binary (optional, enables zig_manage)
--allow-command-tools    Enable command execution tools (disabled by default)
--allow-untrusted-binaries
                        Allow binaries outside trusted dirs (/usr/bin, /usr/local/bin, /opt/homebrew/bin, $HOME/bin)
--help, -h               Show help
--version                Show version
```

## Tools

### Code intelligence (via ZLS)

| Tool | What it does |
|------|-------------|
| `zig_hover` | Type info and docs for a symbol |
| `zig_definition` | Go to definition |
| `zig_references` | Find all references |
| `zig_completion` | Completion suggestions |
| `zig_diagnostics` | Errors and warnings for a file |
| `zig_format` | Format a file |
| `zig_rename` | Rename a symbol across the workspace |
| `zig_document_symbols` | List all symbols in a file |
| `zig_workspace_symbols` | Search symbols across the project |
| `zig_code_action` | Quick fixes and refactors for a range |
| `zig_signature_help` | Function signature at cursor |

### Build & run

Command execution tools are disabled by default. Start zig-mcp with `--allow-command-tools` to enable them.
`--allow-command-tools` requires `--zig-path`.
`zig_manage` requires `--zvm-path`.

| Tool | What it does |
|------|-------------|
| `zig_build` | Run `zig build` with optional args |
| `zig_test` | Run tests (whole project or single file, with optional filter) |
| `zig_check` | Run `zig ast-check` on a file |
| `zig_version` | Show Zig and ZLS versions |
| `zig_manage` | Manage Zig versions via [zvm](https://github.com/marler/zvm) |

## Trusted binary paths

By default, configured binaries are allowed only from trusted directories:

- `/usr/bin`
- `/usr/local/bin`
- `/opt/homebrew/bin`
- `$HOME/bin`

Notes:

- Paths are validated using canonical paths. Symlink targets are checked.
- If your binary lives outside trusted dirs, either move/copy the full installation into a trusted dir, or use `--allow-untrusted-binaries`.

## How it works

zig-mcp spawns ZLS as a child process and talks to it over stdin/stdout using the LSP protocol (Content-Length framing). On the other side, it speaks MCP (newline-delimited JSON-RPC) to the AI assistant.

Three threads:
- **main** -- reads MCP requests, dispatches tool calls, writes responses
- **reader** -- reads LSP responses from ZLS, correlates by request ID
- **stderr** -- forwards ZLS stderr to the server log

If ZLS crashes, zig-mcp automatically restarts it and re-opens all tracked documents.

Files are opened in ZLS lazily on first access -- no need to manage document state manually.

## Development

```bash
# build
zig build

# run tests (~75 unit tests)
zig build test

# run manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | \
  zig-out/bin/zig-mcp --workspace . 2>/dev/null
```

## License

MIT
