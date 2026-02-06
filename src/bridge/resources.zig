const std = @import("std");
const mcp_types = @import("../mcp/types.zig");
const Workspace = @import("../state/workspace.zig").Workspace;

/// List available MCP resources.
pub fn listResources(allocator: std.mem.Allocator, workspace: *const Workspace) ![]const mcp_types.Resource {
    _ = workspace;
    var resources: std.ArrayList(mcp_types.Resource) = .empty;
    // Future: add workspace file listing, diagnostics summary, etc.
    return try resources.toOwnedSlice(allocator);
}
