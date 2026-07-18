const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");

// ---------------------------------------------------------------------------
// Range helpers
// ---------------------------------------------------------------------------

pub const RangeBound = struct { present: bool, inclusive: bool, text: []const u8 };
pub const RangeParts = struct { lower: RangeBound, upper: RangeBound };

/// Parses a Postgres range text value ("[1,10)", "(,5]", "empty", ...).
/// Values are assumed not to contain commas (true for the numeric range
/// types this module supports).
pub fn parseRange(text: []const u8) ?RangeParts {
    if (std.mem.eql(u8, text, "empty")) {
        return .{
            .lower = .{ .present = false, .inclusive = false, .text = "" },
            .upper = .{ .present = false, .inclusive = false, .text = "" },
        };
    }
    if (text.len < 2) return null;
    const lower_incl = text[0] == '[';
    const upper_incl = text[text.len - 1] == ']';
    const inner = text[1 .. text.len - 1];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return null;
    const lower_str = inner[0..comma];
    const upper_str = inner[comma + 1 ..];
    return .{
        .lower = .{ .present = lower_str.len > 0, .inclusive = lower_incl, .text = lower_str },
        .upper = .{ .present = upper_str.len > 0, .inclusive = upper_incl, .text = upper_str },
    };
}

pub fn rangeBoundKind(inclusive: bool) wasmtime.c.wasmtime_component_val_t {
    return .{ .kind = wasmtime.c.WASMTIME_COMPONENT_ENUM, .of = .{ .enumeration = blk: {
        var name: wasmtime.c.wasm_name_t = undefined;
        const s = if (inclusive) "inclusive" else "exclusive";
        wasmtime.c.wasm_name_new(&name, s.len, s.ptr);
        break :blk name;
    } } };
}

pub fn rangeBoundOption(bound: RangeBound, value: wasmtime.c.wasmtime_component_val_t) wasmtime.c.wasmtime_component_val_t {
    if (!bound.present) return wasmtime.Val.option(null);
    return wasmtime.Val.option(wasmtime.Val.tuple2(value, rangeBoundKind(bound.inclusive)));
}

pub fn rangeIntVal(comptime T: type, rng: RangeParts) wasmtime.c.wasmtime_component_val_t {
    const lower_v = std.fmt.parseInt(T, rng.lower.text, 10) catch 0;
    const upper_v = std.fmt.parseInt(T, rng.upper.text, 10) catch 0;
    const lower = if (T == i32) wasmtime.Val.s32Val(lower_v) else wasmtime.Val.s64Val(lower_v);
    const upper = if (T == i32) wasmtime.Val.s32Val(upper_v) else wasmtime.Val.s64Val(upper_v);
    return wasmtime.Val.tuple2(rangeBoundOption(rng.lower, lower), rangeBoundOption(rng.upper, upper));
}

pub fn rangeDecimalVal(rng: RangeParts) wasmtime.c.wasmtime_component_val_t {
    return wasmtime.Val.tuple2(
        rangeBoundOption(rng.lower, wasmtime.Val.string(rng.lower.text)),
        rangeBoundOption(rng.upper, wasmtime.Val.string(rng.upper.text)),
    );
}
