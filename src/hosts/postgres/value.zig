const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");
const types = @import("types.zig");
const pq = types.pq;
const datetime = @import("datetime.zig");
const interval = @import("interval.zig");
const range = @import("range.zig");
const array = @import("array.zig");
const bytea = @import("bytea.zig");

/// Builds a `db-value` value for a single result cell.
pub fn dbValue(gpa: std.mem.Allocator, oid: pq.Oid, is_null: bool, text: []const u8) wasmtime.c.wasmtime_component_val_t {
    if (is_null) return wasmtime.Val.variant("db-null", null);

    const name = types.pgTypeName(oid);
    if (std.mem.eql(u8, name, "boolean")) {
        return wasmtime.Val.variant("boolean", wasmtime.Val.boolVal(text.len > 0 and text[0] == 't'));
    }
    if (std.mem.eql(u8, name, "int16")) {
        const v = std.fmt.parseInt(i16, text, 10) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("int16", wasmtime.Val.s16Val(v));
    }
    if (std.mem.eql(u8, name, "int32")) {
        const v = std.fmt.parseInt(i32, text, 10) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("int32", wasmtime.Val.s32Val(v));
    }
    if (std.mem.eql(u8, name, "int64")) {
        const v = std.fmt.parseInt(i64, text, 10) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("int64", wasmtime.Val.s64Val(v));
    }
    if (std.mem.eql(u8, name, "floating32")) {
        const v = std.fmt.parseFloat(f32, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("floating32", wasmtime.Val.f32Val(v));
    }
    if (std.mem.eql(u8, name, "floating64")) {
        const v = std.fmt.parseFloat(f64, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("floating64", wasmtime.Val.f64Val(v));
    }
    if (std.mem.eql(u8, name, "str")) {
        return wasmtime.Val.variant("str", wasmtime.Val.string(text));
    }
    if (std.mem.eql(u8, name, "binary")) {
        const bytes = bytea.decodeHexBytea(gpa, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("binary", bytea.bytesVal(gpa, bytes));
    }
    if (std.mem.eql(u8, name, "date")) {
        const d = datetime.parseDate(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("date", datetime.dateVal(d));
    }
    if (std.mem.eql(u8, name, "time")) {
        const t = datetime.parseTime(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("time", datetime.timeVal(t));
    }
    if (std.mem.eql(u8, name, "datetime")) {
        const parsed = datetime.parseTimestampNoTz(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("datetime", datetime.datetimeVal(parsed.date, parsed.time));
    }
    if (std.mem.eql(u8, name, "timestamp")) {
        const secs = datetime.parseTimestampTzToUnix(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("timestamp", wasmtime.Val.s64Val(secs));
    }
    if (std.mem.eql(u8, name, "uuid")) {
        return wasmtime.Val.variant("uuid", wasmtime.Val.string(text));
    }
    if (std.mem.eql(u8, name, "jsonb")) {
        return wasmtime.Val.variant("jsonb", bytea.bytesVal(gpa, text));
    }
    if (std.mem.eql(u8, name, "decimal")) {
        return wasmtime.Val.variant("decimal", wasmtime.Val.string(text));
    }
    if (std.mem.eql(u8, name, "range-int32")) {
        const rng = range.parseRange(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("range-int32", range.rangeIntVal(i32, rng));
    }
    if (std.mem.eql(u8, name, "range-int64")) {
        const rng = range.parseRange(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("range-int64", range.rangeIntVal(i64, rng));
    }
    if (std.mem.eql(u8, name, "range-decimal")) {
        const rng = range.parseRange(text) orelse return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("range-decimal", range.rangeDecimalVal(rng));
    }
    if (std.mem.eql(u8, name, "array-int32")) {
        const v = array.arrayIntVal(gpa, i32, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("array-int32", v);
    }
    if (std.mem.eql(u8, name, "array-int64")) {
        const v = array.arrayIntVal(gpa, i64, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("array-int64", v);
    }
    if (std.mem.eql(u8, name, "array-decimal")) {
        const v = array.arrayDecimalVal(gpa, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("array-decimal", v);
    }
    if (std.mem.eql(u8, name, "array-str")) {
        const v = array.arrayStrVal(gpa, text) catch return wasmtime.Val.variant("str", wasmtime.Val.string(text));
        return wasmtime.Val.variant("array-str", v);
    }
    if (std.mem.eql(u8, name, "interval")) {
        return wasmtime.Val.variant("interval", interval.intervalVal(interval.parseInterval(text)));
    }

    var bytes: std.ArrayList(wasmtime.c.wasmtime_component_val_t) = .empty;
    defer bytes.deinit(std.heap.page_allocator);
    for (text) |byte| bytes.append(std.heap.page_allocator, wasmtime.Val.u8Val(byte)) catch break;
    return wasmtime.Val.variant("unsupported", wasmtime.Val.list(bytes.items));
}
