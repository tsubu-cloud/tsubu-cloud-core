const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");
const datetime = @import("datetime.zig");

// ---------------------------------------------------------------------------
// Interval helpers
// ---------------------------------------------------------------------------

pub const IntervalParts = struct { months: i32, days: i32, micros: i64 };

/// Parses a Postgres `interval` text value in the default `postgres`
/// `IntervalStyle` (e.g. "1 year 2 mons 3 days 04:05:06.123456", or
/// "-04:05:06" for a bare time component).
pub fn parseInterval(text: []const u8) IntervalParts {
    var months: i64 = 0;
    var days: i64 = 0;
    var micros: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, ':') != null) {
            micros += parseIntervalTime(tok);
            continue;
        }
        const num = std.fmt.parseInt(i64, tok, 10) catch continue;
        const unit = it.next() orelse break;
        if (std.mem.startsWith(u8, unit, "year")) {
            months += num * 12;
        } else if (std.mem.startsWith(u8, unit, "mon")) {
            months += num;
        } else if (std.mem.startsWith(u8, unit, "day")) {
            days += num;
        }
    }
    return .{ .months = @intCast(months), .days = @intCast(days), .micros = micros };
}

fn parseIntervalTime(tok: []const u8) i64 {
    var s = tok;
    var sign: i64 = 1;
    if (std.mem.startsWith(u8, s, "-")) {
        sign = -1;
        s = s[1..];
    } else if (std.mem.startsWith(u8, s, "+")) {
        s = s[1..];
    }
    const t = datetime.parseTime(s) orelse return 0;
    const micros = @as(i64, t.hour) * 3_600_000_000 + @as(i64, t.minute) * 60_000_000 + @as(i64, t.second) * 1_000_000 + @divTrunc(@as(i64, t.nanos), 1000);
    return sign * micros;
}

pub fn intervalVal(iv: IntervalParts) wasmtime.c.wasmtime_component_val_t {
    return wasmtime.Val.record(&.{
        wasmtime.Val.recordEntry("micros", wasmtime.Val.s64Val(iv.micros)),
        wasmtime.Val.recordEntry("days", wasmtime.Val.s32Val(iv.days)),
        wasmtime.Val.recordEntry("months", wasmtime.Val.s32Val(iv.months)),
    });
}
