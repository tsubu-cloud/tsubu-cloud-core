const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");
const datetime = @import("datetime.zig");

// ---------------------------------------------------------------------------
// parameter-value -> text encoding
// ---------------------------------------------------------------------------

fn tupleField(val: wasmtime.c.wasmtime_component_val_t, i: usize) wasmtime.c.wasmtime_component_val_t {
    return val.of.tuple.data[i];
}

fn optionPayload(val: wasmtime.c.wasmtime_component_val_t) ?wasmtime.c.wasmtime_component_val_t {
    const ptr = val.of.option orelse return null;
    return ptr.*;
}

fn rangeBoundKindIsInclusive(val: wasmtime.c.wasmtime_component_val_t) bool {
    const e = val.of.enumeration;
    return std.mem.eql(u8, e.data[0..e.size], "inclusive");
}

fn fmtRangeBound(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bound: ?wasmtime.c.wasmtime_component_val_t, comptime valueFmt: fn (std.mem.Allocator, wasmtime.c.wasmtime_component_val_t) anyerror![]const u8) !bool {
    const pair = bound orelse return false;
    const value = tupleField(pair, 0);
    const kind = tupleField(pair, 1);
    const s = try valueFmt(gpa, value);
    try buf.appendSlice(gpa, s);
    return rangeBoundKindIsInclusive(kind);
}

fn fmtIntValue(gpa: std.mem.Allocator, v: wasmtime.c.wasmtime_component_val_t) ![]const u8 {
    return switch (v.kind) {
        wasmtime.c.WASMTIME_COMPONENT_S32 => std.fmt.allocPrint(gpa, "{d}", .{v.of.s32}),
        wasmtime.c.WASMTIME_COMPONENT_S64 => std.fmt.allocPrint(gpa, "{d}", .{v.of.s64}),
        else => "",
    };
}

fn fmtStringValue(gpa: std.mem.Allocator, v: wasmtime.c.wasmtime_component_val_t) ![]const u8 {
    _ = gpa;
    return v.of.string.data[0..v.of.string.size];
}

fn fmtRange(gpa: std.mem.Allocator, val: wasmtime.c.wasmtime_component_val_t, comptime valueFmt: fn (std.mem.Allocator, wasmtime.c.wasmtime_component_val_t) anyerror![]const u8) ![:0]const u8 {
    const lower_opt = optionPayload(tupleField(val, 0));
    const upper_opt = optionPayload(tupleField(val, 1));

    var buf: std.ArrayList(u8) = .empty;
    if (lower_opt) |pair| {
        const incl = rangeBoundKindIsInclusive(tupleField(pair, 1));
        try buf.append(gpa, if (incl) '[' else '(');
    } else {
        try buf.append(gpa, '(');
    }
    _ = try fmtRangeBound(gpa, &buf, lower_opt, valueFmt);
    try buf.append(gpa, ',');
    if (upper_opt != null) {
        _ = try fmtRangeBound(gpa, &buf, upper_opt, valueFmt);
        const upper_pair = upper_opt.?;
        const incl = rangeBoundKindIsInclusive(tupleField(upper_pair, 1));
        try buf.append(gpa, if (incl) ']' else ')');
    } else {
        try buf.append(gpa, ')');
    }
    return buf.toOwnedSliceSentinel(gpa, 0);
}

fn fmtArray(gpa: std.mem.Allocator, items: []const wasmtime.c.wasmtime_component_val_t, comptime valueFmt: fn (std.mem.Allocator, wasmtime.c.wasmtime_component_val_t) anyerror![]const u8, quote: bool) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(gpa, '{');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(gpa, ',');
        const payload = optionPayload(item);
        if (payload) |p| {
            if (quote) {
                try buf.append(gpa, '"');
                const s = try valueFmt(gpa, p);
                for (s) |ch| {
                    if (ch == '"' or ch == '\\') try buf.append(gpa, '\\');
                    try buf.append(gpa, ch);
                }
                try buf.append(gpa, '"');
            } else {
                try buf.appendSlice(gpa, try valueFmt(gpa, p));
            }
        } else {
            try buf.appendSlice(gpa, "NULL");
        }
    }
    try buf.append(gpa, '}');
    return buf.toOwnedSliceSentinel(gpa, 0);
}

/// Converts a guest-supplied `parameter-value` into a null-terminated text
/// value suitable for `PQexecParams`, or `null` for a SQL `NULL`. Returns
/// `error.UnsupportedParameter` for variant cases not handled by this
/// implementation.
pub fn paramToText(gpa: std.mem.Allocator, val: wasmtime.c.wasmtime_component_val_t) !?[:0]const u8 {
    const case_name = wasmtime.Val.variantName(val) orelse return error.UnsupportedParameter;
    const payload = wasmtime.Val.variantPayload(val);

    if (std.mem.eql(u8, case_name, "db-null")) return null;
    if (std.mem.eql(u8, case_name, "boolean")) {
        return try gpa.dupeZ(u8, if (payload.?.of.boolean) "true" else "false");
    }
    if (std.mem.eql(u8, case_name, "int8")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.s8}, 0);
    if (std.mem.eql(u8, case_name, "int16")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.s16}, 0);
    if (std.mem.eql(u8, case_name, "int32")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.s32}, 0);
    if (std.mem.eql(u8, case_name, "int64")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.s64}, 0);
    if (std.mem.eql(u8, case_name, "floating32")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.f32}, 0);
    if (std.mem.eql(u8, case_name, "floating64")) return try std.fmt.allocPrintSentinel(gpa, "{d}", .{payload.?.of.f64}, 0);
    if (std.mem.eql(u8, case_name, "str")) {
        const s = payload.?.of.string;
        return try gpa.dupeZ(u8, s.data[0..s.size]);
    }
    if (std.mem.eql(u8, case_name, "binary")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        var buf = try gpa.allocSentinel(u8, 2 + items.len * 2, 0);
        buf[0] = '\\';
        buf[1] = 'x';
        const hex_digits = "0123456789abcdef";
        for (items, 0..) |item, i| {
            const b = item.of.u8;
            buf[2 + i * 2] = hex_digits[b >> 4];
            buf[2 + i * 2 + 1] = hex_digits[b & 0xf];
        }
        return buf;
    }
    if (std.mem.eql(u8, case_name, "date")) {
        const t = payload.?;
        return try std.fmt.allocPrintSentinel(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ tupleField(t, 0).of.s32, tupleField(t, 1).of.u8, tupleField(t, 2).of.u8 }, 0);
    }
    if (std.mem.eql(u8, case_name, "time")) {
        const t = payload.?;
        return try std.fmt.allocPrintSentinel(gpa, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ tupleField(t, 0).of.u8, tupleField(t, 1).of.u8, tupleField(t, 2).of.u8, tupleField(t, 3).of.u32 / 1000 }, 0);
    }
    if (std.mem.eql(u8, case_name, "datetime")) {
        const t = payload.?;
        return try std.fmt.allocPrintSentinel(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
            tupleField(t, 0).of.s32, tupleField(t, 1).of.u8,  tupleField(t, 2).of.u8,
            tupleField(t, 3).of.u8,  tupleField(t, 4).of.u8,  tupleField(t, 5).of.u8,
            tupleField(t, 6).of.u32 / 1000,
        }, 0);
    }
    if (std.mem.eql(u8, case_name, "timestamp")) {
        const secs = payload.?.of.s64;
        const days = @divFloor(secs, 86400);
        const rem = secs - days * 86400;
        const civil = datetime.civilFromDays(days);
        return try std.fmt.allocPrintSentinel(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}+00", .{
            civil.y, civil.m, civil.d, @divFloor(rem, 3600), @mod(@divFloor(rem, 60), 60), @mod(rem, 60),
        }, 0);
    }
    if (std.mem.eql(u8, case_name, "uuid")) {
        const s = payload.?.of.string;
        return try gpa.dupeZ(u8, s.data[0..s.size]);
    }
    if (std.mem.eql(u8, case_name, "jsonb")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        var out = try gpa.allocSentinel(u8, items.len, 0);
        for (items, 0..) |item, i| out[i] = item.of.u8;
        return out;
    }
    if (std.mem.eql(u8, case_name, "decimal")) {
        const s = payload.?.of.string;
        return try gpa.dupeZ(u8, s.data[0..s.size]);
    }
    if (std.mem.eql(u8, case_name, "range-int32")) return try fmtRange(gpa, payload.?, fmtIntValue);
    if (std.mem.eql(u8, case_name, "range-int64")) return try fmtRange(gpa, payload.?, fmtIntValue);
    if (std.mem.eql(u8, case_name, "range-decimal")) return try fmtRange(gpa, payload.?, fmtStringValue);
    if (std.mem.eql(u8, case_name, "array-int32")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        return try fmtArray(gpa, items, fmtIntValue, false);
    }
    if (std.mem.eql(u8, case_name, "array-int64")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        return try fmtArray(gpa, items, fmtIntValue, false);
    }
    if (std.mem.eql(u8, case_name, "array-decimal")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        return try fmtArray(gpa, items, fmtStringValue, false);
    }
    if (std.mem.eql(u8, case_name, "array-str")) {
        const items = payload.?.of.list.data[0..payload.?.of.list.size];
        return try fmtArray(gpa, items, fmtStringValue, true);
    }
    if (std.mem.eql(u8, case_name, "interval")) {
        const rec = payload.?;
        const micros = wasmtime.Val.field(rec, "micros").?.of.s64;
        const days = wasmtime.Val.field(rec, "days").?.of.s32;
        const months = wasmtime.Val.field(rec, "months").?.of.s32;
        return try std.fmt.allocPrintSentinel(gpa, "{d} months {d} days {d} microseconds", .{ months, days, micros }, 0);
    }

    return error.UnsupportedParameter;
}
