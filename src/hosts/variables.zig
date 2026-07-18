const std = @import("std");
const wasmtime = @import("../wasmtime/root.zig");

pub const VariableContext = struct {
    /// The static value this `{alias}` import is bound to, taken verbatim
    /// from `tsubu.json`.
    value: []const u8,
};

/// Component import `{alias}: func() -> string`.
///
/// Returns the pre-configured value (from `tsubu.json`) for this alias.
pub fn hostGetVariable(
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
    _ = args;
    _ = nargs;
    _ = nresults;
    const ctx: *VariableContext = @ptrCast(@alignCast(env.?));

    results[0] = wasmtime.Val.string(ctx.value);
    return null;
}
