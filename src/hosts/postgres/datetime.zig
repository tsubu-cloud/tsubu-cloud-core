const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");

// ---------------------------------------------------------------------------
// Date/time helpers
//
// Days-since-epoch <-> (year, month, day) conversions, using the standard
// proleptic-Gregorian algorithm (Howard Hinnant's `days_from_civil` /
// `civil_from_days`). Works for the full range of years Postgres supports.
// ---------------------------------------------------------------------------

pub fn daysFromCivil(y_: i64, m_: i64, d_: i64) i64 {
    const y = y_ - @as(i64, if (m_ <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divFloor(153 * (m_ + (if (m_ > 2) @as(i64, -3) else 9)) + 2, 5) + d_ - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: i64, d: i64 };

pub fn civilFromDays(z_: i64) Civil {
    const z = z_ + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = mp + (if (mp < 10) @as(i64, 3) else -9); // [1, 12]
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

pub const DateParts = struct { year: i32, month: u8, day: u8 };
pub const TimeParts = struct { hour: u8, minute: u8, second: u8, nanos: u32 };

/// Parses a Postgres `date` text value ("YYYY-MM-DD", optionally suffixed
/// with " BC").
pub fn parseDate(text: []const u8) ?DateParts {
    var s = text;
    var negate = false;
    if (std.mem.endsWith(u8, s, " BC")) {
        negate = true;
        s = s[0 .. s.len - 3];
    }
    var it = std.mem.splitScalar(u8, s, '-');
    const year_str = it.next() orelse return null;
    const month_str = it.next() orelse return null;
    const day_str = it.next() orelse return null;
    var year = std.fmt.parseInt(i32, year_str, 10) catch return null;
    if (negate) year = -(year - 1);
    const month = std.fmt.parseInt(u8, month_str, 10) catch return null;
    const day = std.fmt.parseInt(u8, day_str, 10) catch return null;
    return .{ .year = year, .month = month, .day = day };
}

/// Parses a Postgres `time` text value ("HH:MM:SS[.ffffff]").
pub fn parseTime(text: []const u8) ?TimeParts {
    var it = std.mem.splitScalar(u8, text, ':');
    const hour_str = it.next() orelse return null;
    const minute_str = it.next() orelse return null;
    const sec_str = it.next() orelse return null;
    const hour = std.fmt.parseInt(u8, hour_str, 10) catch return null;
    const minute = std.fmt.parseInt(u8, minute_str, 10) catch return null;
    var frac_it = std.mem.splitScalar(u8, sec_str, '.');
    const second_str = frac_it.next() orelse return null;
    const second = std.fmt.parseInt(u8, second_str, 10) catch return null;
    var nanos: u32 = 0;
    if (frac_it.next()) |frac_str| {
        var buf = [_]u8{'0'} ** 9;
        const n = @min(frac_str.len, 9);
        @memcpy(buf[0..n], frac_str[0..n]);
        nanos = std.fmt.parseInt(u32, &buf, 10) catch 0;
    }
    return .{ .hour = hour, .minute = minute, .second = second, .nanos = nanos };
}

/// Parses a Postgres `timestamp` (without time zone) text value
/// ("YYYY-MM-DD HH:MM:SS[.ffffff]").
pub fn parseTimestampNoTz(text: []const u8) ?struct { date: DateParts, time: TimeParts } {
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    const date = parseDate(text[0..space]) orelse return null;
    const time = parseTime(text[space + 1 ..]) orelse return null;
    return .{ .date = date, .time = time };
}

/// Parses a Postgres `timestamptz` text value into Unix seconds. Handles an
/// optional trailing zone offset ("+HH[:MM]" / "-HH[:MM]"); assumes UTC if
/// none is present.
pub fn parseTimestampTzToUnix(text: []const u8) ?i64 {
    var body = text;
    var offset_secs: i64 = 0;
    // The zone offset sign can only appear in the time-of-day portion (the
    // date portion contains '-' separators of its own), so search from the
    // space that separates date and time.
    const search_from = (std.mem.indexOfScalar(u8, body, ' ') orelse 0) + 1;
    if (std.mem.indexOfAnyPos(u8, body, search_from, "+-")) |idx| {
        const zone = body[idx..];
        body = body[0..idx];
        const sign: i64 = if (zone[0] == '-') -1 else 1;
        var zit = std.mem.splitScalar(u8, zone[1..], ':');
        const zh = std.fmt.parseInt(i64, zit.next() orelse "0", 10) catch 0;
        const zm = std.fmt.parseInt(i64, zit.next() orelse "0", 10) catch 0;
        offset_secs = sign * (zh * 3600 + zm * 60);
    }
    const parsed = parseTimestampNoTz(body) orelse return null;
    const days = daysFromCivil(parsed.date.year, parsed.date.month, parsed.date.day);
    const secs_in_day: i64 = @as(i64, parsed.time.hour) * 3600 + @as(i64, parsed.time.minute) * 60 + @as(i64, parsed.time.second);
    return days * 86400 + secs_in_day - offset_secs;
}

pub fn dateVal(d: DateParts) wasmtime.c.wasmtime_component_val_t {
    return wasmtime.Val.tuple(&.{
        wasmtime.Val.s32Val(d.year),
        wasmtime.Val.u8Val(d.month),
        wasmtime.Val.u8Val(d.day),
    });
}

pub fn timeVal(t: TimeParts) wasmtime.c.wasmtime_component_val_t {
    return wasmtime.Val.tuple(&.{
        wasmtime.Val.u8Val(t.hour),
        wasmtime.Val.u8Val(t.minute),
        wasmtime.Val.u8Val(t.second),
        .{ .kind = wasmtime.c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = t.nanos } },
    });
}

pub fn datetimeVal(d: DateParts, t: TimeParts) wasmtime.c.wasmtime_component_val_t {
    return wasmtime.Val.tuple(&.{
        wasmtime.Val.s32Val(d.year),
        wasmtime.Val.u8Val(d.month),
        wasmtime.Val.u8Val(d.day),
        wasmtime.Val.u8Val(t.hour),
        wasmtime.Val.u8Val(t.minute),
        wasmtime.Val.u8Val(t.second),
        .{ .kind = wasmtime.c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = t.nanos } },
    });
}
