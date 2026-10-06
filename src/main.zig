const std = @import("std");
const cli = @import("cli/cli.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    cli.run(init, args) catch |err| switch (err) {
        // cli.run already printed the details.
        error.Usage => std.process.exit(2),
        error.VerifyFailed, error.JournalNotFound => std.process.exit(1),
        else => {
            std.debug.print("zephyr: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}
