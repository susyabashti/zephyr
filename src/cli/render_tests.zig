//! Test root for the CLI layer (the `test` step in build.zig): the test
//! runner discovers test blocks across a module's whole graph, and a module
//! may only import files under its root directory — so the styled renderer
//! tests, whose files import siblings across the `commands/` boundary, are
//! pulled in here instead of rooting the module at a command file.

const views = @import("commands/views.zig");
const search = @import("commands/search.zig");
const table = @import("table.zig");
const pager = @import("pager.zig");
const editor = @import("editor.zig");
const log_cmd = @import("commands/log.zig");
const edit_cmd = @import("commands/edit.zig");

test "cli render modules instantiate" {
    _ = views;
    _ = search;
    _ = table;
    _ = pager;
    _ = editor;
    _ = log_cmd;
    _ = edit_cmd;
}
