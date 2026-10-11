//! Zephyr MCP server: read-only AI access to the journal (spec/mcp.md).
//!
//! Layering: mcp depends on core (journal, view, search); core does not know
//! the MCP exists. The CLI dispatches `zephyr mcp` to mcp.server.run.

pub const protocol = @import("mcp/protocol.zig");
pub const tools = @import("mcp/tools.zig");
pub const server = @import("mcp/server.zig");

/// The MCP serverInfo version (kept in sync with cli.Version).
pub const Version = server.Version;
