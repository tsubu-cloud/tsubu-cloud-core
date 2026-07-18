const std = @import("std");

pub const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
});

pub const Error = error{
    EngineInit,
    StoreInit,
    WasiConfigInit,
    LinkerInit,
    WasiConfigSet,
    WasiLink,
    ComponentCompile,
    ComponentSerialize,
    ComponentDeserialize,
    ComponentInstantiate,
    ComponentGetFunc,
    ComponentFuncCall,
    ComponentDefineFunc,
};

/// Captures a wasmtime error message into a gpa-owned slice, freeing the
/// C-side buffer. `message.*` is left untouched (null) if `err` is null.
pub fn captureMessage(gpa: std.mem.Allocator, message: *?[]u8, err: ?*c.wasmtime_error_t) !void {
    const e = err orelse return;
    var buf: c.wasm_name_t = undefined;
    c.wasmtime_error_message(e, &buf);
    c.wasmtime_error_delete(e);
    defer c.wasm_byte_vec_delete(&buf);
    message.* = try gpa.dupe(u8, buf.data[0..buf.size]);
}
