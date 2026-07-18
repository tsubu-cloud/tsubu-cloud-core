const std = @import("std");
const wasmtime = @import("../wasmtime/root.zig");

/// Accumulates the messages logged by a single `runWasm` call, so the
/// caller can persist them (e.g. against the request's `sessions` row)
/// once the run has finished. Owned dupes; the caller takes ownership of
/// `messages.toOwnedSlice`.
pub const LogContext = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList([]const u8) = .empty,
};

/// Component import `tsubu-cloud:logger/logger` interface's
/// `log: func(message: string)`.
pub fn hostLog(
    env: ?*anyopaque,
    context: ?*wasmtime.c.wasmtime_context_t,
    ty: ?*const wasmtime.c.wasmtime_component_func_type_t,
    args: [*c]wasmtime.c.wasmtime_component_val_t,
    nargs: usize,
    results: [*c]wasmtime.c.wasmtime_component_val_t,
    nresults: usize,
) callconv(.c) ?*wasmtime.c.wasmtime_error_t {
    _ = context;
    _ = ty;
    _ = nargs;
    _ = results;
    _ = nresults;
    const ctx: *LogContext = @ptrCast(@alignCast(env.?));

    const message_str = args[0].of.string;
    const message = message_str.data[0..message_str.size];
    std.debug.print("{s}\n", .{message});

    const owned = ctx.gpa.dupe(u8, message) catch return wasmtime.c.wasmtime_error_new("out of memory");
    ctx.messages.append(ctx.gpa, owned) catch return wasmtime.c.wasmtime_error_new("out of memory");
    return null;
}
