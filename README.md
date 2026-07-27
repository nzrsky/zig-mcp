# zig-mcp

MCP server for Zig that connects AI coding assistants to [ZLS](https://github.com/zigtools/zls) via the Language Server Protocol.

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Cursor, Windsurf, and any MCP-compatible client.

```
AI assistant  <--(MCP stdio)-->  zig-mcp  <--(LSP pipes)-->  ZLS
                                    |
                             zig build / test / check
```

## Requirements

- [Zig](https://ziglang.org/download/) 0.17.0-dev.1415+64dfaa568 or newer
- [ZLS](https://github.com/zigtools/zls/releases) (auto-detected from PATH, or specify with `--zls-path`)

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

### Options

```
--workspace, -w <path>   Project root directory (default: cwd)
--zls-path <path>        Path to ZLS binary (default: auto-detect from PATH)
--help, -h               Show help
--version                Show version
```

## Tools

All of these answer from ZLS's semantic model — the part a shell and a text
search cannot reach.

| Tool | What it knows that grep does not |
|------|-------------|
| `zig_definition` | The one true declaration, followed through imports and aliases. Takes `symbol` or `file`+`line`+`character` |
| `zig_references` | Real usages, scope-aware; skips same-named identifiers, comments and strings. `symbol` mode also searches through re-exports |
| `zig_hover` | The type after comptime evaluation and inference — invisible in the source text |
| `zig_diagnostics` | Errors for one file without building the project, re-synced against disk first |
| `zig_workspace_symbols` | Declarations by name, not every line mentioning it |
| `zig_document_symbols` | A file's outline: declarations, kinds, nesting |
| `zig_completion` | What can legally follow at a position, with types |
| `zig_signature_help` | The real signature, comptime and generic parameters included |
| `zig_rename` | Which files a rename touches, scope-aware |
| `zig_code_action` | Quick fixes ZLS offers for a range |
| `zig_inlay_hints` | Every inferred type in a file at once — nothing of this is in the source text |
| `zig_type_definition` | The declaration of a value's *type*, not of the value |
| `zig_ast_query` | Code by shape: empty `catch {}`, `catch unreachable`, `undefined` initializers, `unreachable`, `@panic`. Matched over the syntax tree, so comments and string literals never match and multi-line forms always do |
| `zig_unused_private` | Private declarations nothing refers to — exact, because a non-`pub` name cannot escape its file |

### What is deliberately absent

There is no `zig_build`, `zig_test`, `zig_format`, `zig_version`, `zig_check`
or `zig_manage`. They used to exist and wrapped `zig build`, `zig test`,
`zig fmt`, `zig version`, `zig ast-check` and `zvm` — and a wrapper loses to
the shell it wraps: no pipes, no redirection, no working
directory of its own. Session transcripts settle it: 526 `zig build`
invocations through the shell, zero calls to the tool. Run those with your
shell.

## How it works

zig-mcp spawns ZLS as a child process and talks to it over stdin/stdout using the LSP protocol (Content-Length framing). On the other side, it speaks MCP (newline-delimited JSON-RPC) to the AI assistant.

Three threads:
- **main** -- reads MCP requests, dispatches tool calls, writes responses
- **reader** -- reads LSP responses from ZLS, correlates by request ID
- **stderr** -- forwards ZLS stderr to the server log

If ZLS crashes, zig-mcp automatically restarts it and re-opens all tracked documents.

Files are opened in ZLS lazily on first access, and re-synced (`didChange`) whenever their contents change on disk -- no need to manage document state manually.

## Development

```bash
# build
zig build

# run tests (162 unit tests, including a fake-ZLS harness)
zig build test

# quality gates: lint, coverage, dead code, mutants
make lint cov deadcode mutants

# run manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | \
  zig-out/bin/zig-mcp --workspace . 2>/dev/null
```

## License

MIT
