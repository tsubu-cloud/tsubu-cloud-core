const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");

// ---------------------------------------------------------------------------
// bytea / hex helpers
// ---------------------------------------------------------------------------

/// Decodes a Postgres `bytea` hex-format text value ("\xdeadbeef").
pub fn decodeHexBytea(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, text, "\\x")) return gpa.dupe(u8, text);
    const hex = text[2..];
    var out = try gpa.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch 0;
    }
    return out;
}

pub fn bytesVal(gpa: std.mem.Allocator, bytes: []const u8) wasmtime.c.wasmtime_component_val_t {
    var items = gpa.alloc(wasmtime.c.wasmtime_component_val_t, bytes.len) catch return wasmtime.Val.list(&.{});
    for (bytes, 0..) |b, i| items[i] = wasmtime.Val.u8Val(b);
    return wasmtime.Val.list(items);
}
