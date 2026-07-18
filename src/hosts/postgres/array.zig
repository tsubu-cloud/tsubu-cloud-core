const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");

// ---------------------------------------------------------------------------
// Array helpers
// ---------------------------------------------------------------------------

/// Splits a Postgres array literal body ("{a,b,NULL,c}") into its top-level
/// elements, unquoting/unescaping quoted elements. Assumes a flat (1-D)
/// array of scalars, which is all this module supports.
pub fn splitArrayElements(gpa: std.mem.Allocator, text: []const u8) ![]?[]const u8 {
    var elems: std.ArrayList(?[]const u8) = .empty;
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return elems.toOwnedSlice(gpa);
    const inner = text[1 .. text.len - 1];
    if (inner.len == 0) return elems.toOwnedSlice(gpa);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var in_quotes = false;
    var i: usize = 0;
    var elem_start_is_quoted = false;
    var saw_any = false;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (in_quotes) {
            if (ch == '\\' and i + 1 < inner.len) {
                i += 1;
                try buf.append(gpa, inner[i]);
            } else if (ch == '"') {
                in_quotes = false;
            } else {
                try buf.append(gpa, ch);
            }
            continue;
        }
        switch (ch) {
            '"' => {
                in_quotes = true;
                elem_start_is_quoted = true;
                saw_any = true;
            },
            ',' => {
                if (!elem_start_is_quoted and std.mem.eql(u8, buf.items, "NULL")) {
                    try elems.append(gpa, null);
                } else {
                    try elems.append(gpa, try gpa.dupe(u8, buf.items));
                }
                buf.clearRetainingCapacity();
                elem_start_is_quoted = false;
                saw_any = false;
            },
            else => {
                try buf.append(gpa, ch);
                saw_any = true;
            },
        }
    }
    if (saw_any or buf.items.len > 0 or elems.items.len == 0) {
        if (!elem_start_is_quoted and std.mem.eql(u8, buf.items, "NULL")) {
            try elems.append(gpa, null);
        } else {
            try elems.append(gpa, try gpa.dupe(u8, buf.items));
        }
    }
    return elems.toOwnedSlice(gpa);
}

pub fn arrayIntVal(gpa: std.mem.Allocator, comptime T: type, text: []const u8) !wasmtime.c.wasmtime_component_val_t {
    const elems = try splitArrayElements(gpa, text);
    var items = try gpa.alloc(wasmtime.c.wasmtime_component_val_t, elems.len);
    for (elems, 0..) |elem, i| {
        if (elem) |s| {
            const v = std.fmt.parseInt(T, s, 10) catch 0;
            items[i] = wasmtime.Val.option(if (T == i32) wasmtime.Val.s32Val(v) else wasmtime.Val.s64Val(v));
        } else {
            items[i] = wasmtime.Val.option(null);
        }
    }
    return wasmtime.Val.list(items);
}

pub fn arrayDecimalVal(gpa: std.mem.Allocator, text: []const u8) !wasmtime.c.wasmtime_component_val_t {
    const elems = try splitArrayElements(gpa, text);
    var items = try gpa.alloc(wasmtime.c.wasmtime_component_val_t, elems.len);
    for (elems, 0..) |elem, i| {
        items[i] = wasmtime.Val.option(if (elem) |s| wasmtime.Val.string(s) else null);
    }
    return wasmtime.Val.list(items);
}

pub fn arrayStrVal(gpa: std.mem.Allocator, text: []const u8) !wasmtime.c.wasmtime_component_val_t {
    const elems = try splitArrayElements(gpa, text);
    var items = try gpa.alloc(wasmtime.c.wasmtime_component_val_t, elems.len);
    for (elems, 0..) |elem, i| {
        items[i] = wasmtime.Val.option(if (elem) |s| wasmtime.Val.string(s) else null);
    }
    return wasmtime.Val.list(items);
}
