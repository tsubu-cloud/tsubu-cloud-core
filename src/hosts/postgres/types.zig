const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");

pub const pq = @cImport({
    @cInclude("libpq-fe.h");
});

pub const QueryContext = struct {
    gpa: std.mem.Allocator,
    /// The pre-configured connection string this `{ALIAS}` import is
    /// bound to (from `tsubu.json`). The guest never supplies credentials.
    database_url: []const u8,
};

// Well-known Postgres type OIDs handled by this module.
pub const OID_BOOL: pq.Oid = 16;
pub const OID_INT2: pq.Oid = 21;
pub const OID_INT4: pq.Oid = 23;
pub const OID_INT8: pq.Oid = 20;
pub const OID_FLOAT4: pq.Oid = 700;
pub const OID_FLOAT8: pq.Oid = 701;
pub const OID_TEXT: pq.Oid = 25;
pub const OID_VARCHAR: pq.Oid = 1043;
pub const OID_BPCHAR: pq.Oid = 1042;
pub const OID_BYTEA: pq.Oid = 17;
pub const OID_DATE: pq.Oid = 1082;
pub const OID_TIME: pq.Oid = 1083;
pub const OID_TIMESTAMP: pq.Oid = 1114;
pub const OID_TIMESTAMPTZ: pq.Oid = 1184;
pub const OID_UUID: pq.Oid = 2950;
pub const OID_JSON: pq.Oid = 114;
pub const OID_JSONB: pq.Oid = 3802;
pub const OID_NUMERIC: pq.Oid = 1700;
pub const OID_INT4RANGE: pq.Oid = 3904;
pub const OID_INT8RANGE: pq.Oid = 3926;
pub const OID_NUMRANGE: pq.Oid = 3906;
pub const OID_INT4ARRAY: pq.Oid = 1007;
pub const OID_INT8ARRAY: pq.Oid = 1016;
pub const OID_NUMERICARRAY: pq.Oid = 1231;
pub const OID_TEXTARRAY: pq.Oid = 1009;
pub const OID_VARCHARARRAY: pq.Oid = 1015;
pub const OID_INTERVAL: pq.Oid = 1186;

/// Maps a subset of well-known Postgres type OIDs to the `db-data-type` /
/// `db-value` variant case name used to represent that column. Anything not
/// in this minimal set falls back to `"other"` / `"unsupported"`.
pub fn pgTypeName(oid: pq.Oid) []const u8 {
    return switch (oid) {
        OID_BOOL => "boolean",
        OID_INT2 => "int16",
        OID_INT4 => "int32",
        OID_INT8 => "int64",
        OID_FLOAT4 => "floating32",
        OID_FLOAT8 => "floating64",
        OID_TEXT, OID_VARCHAR, OID_BPCHAR => "str",
        OID_BYTEA => "binary",
        OID_DATE => "date",
        OID_TIME => "time",
        OID_TIMESTAMP => "datetime",
        OID_TIMESTAMPTZ => "timestamp",
        OID_UUID => "uuid",
        OID_JSON, OID_JSONB => "jsonb",
        OID_NUMERIC => "decimal",
        OID_INT4RANGE => "range-int32",
        OID_INT8RANGE => "range-int64",
        OID_NUMRANGE => "range-decimal",
        OID_INT4ARRAY => "array-int32",
        OID_INT8ARRAY => "array-int64",
        OID_NUMERICARRAY => "array-decimal",
        OID_TEXTARRAY, OID_VARCHARARRAY => "array-str",
        OID_INTERVAL => "interval",
        else => "other",
    };
}

/// Builds a `db-data-type` value for a result column.
pub fn dbDataType(oid: pq.Oid) wasmtime.c.wasmtime_component_val_t {
    const name = pgTypeName(oid);
    if (std.mem.eql(u8, name, "other")) {
        var buf: [32]u8 = undefined;
        const oid_str = std.fmt.bufPrint(&buf, "{d}", .{oid}) catch "other";
        return wasmtime.Val.variant("other", wasmtime.Val.string(oid_str));
    }
    return wasmtime.Val.variant(name, null);
}
