const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");
const pq = @import("types.zig").pq;

// ---------------------------------------------------------------------------
// Structured error reporting
// ---------------------------------------------------------------------------

fn diagField(res: ?*pq.PGresult, field: c_int) ?[]const u8 {
    const ptr = pq.PQresultErrorField(res, field) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Builds a `query-error` value from a failed result, preferring the
/// structured `db-error` shape when Postgres provides SQLSTATE diagnostics
/// (always the case for backend-reported errors), and falling back to the
/// plain error message text otherwise.
pub fn queryErrorVal(arena: std.mem.Allocator, res: ?*pq.PGresult) wasmtime.c.wasmtime_component_val_t {
    const sqlstate = diagField(res, pq.PG_DIAG_SQLSTATE);
    if (sqlstate == null) {
        const err_msg = std.mem.sliceTo(pq.PQresultErrorMessage(res), 0);
        return wasmtime.Val.variant("text", wasmtime.Val.string(err_msg));
    }

    const severity = diagField(res, pq.PG_DIAG_SEVERITY) orelse "";
    const message = diagField(res, pq.PG_DIAG_MESSAGE_PRIMARY) orelse "";
    const detail = diagField(res, pq.PG_DIAG_MESSAGE_DETAIL);
    const as_text = std.mem.sliceTo(pq.PQresultErrorMessage(res), 0);

    const extra_fields = [_]struct { key: []const u8, field: c_int }{
        .{ .key = "hint", .field = pq.PG_DIAG_MESSAGE_HINT },
        .{ .key = "context", .field = pq.PG_DIAG_CONTEXT },
        .{ .key = "schema_name", .field = pq.PG_DIAG_SCHEMA_NAME },
        .{ .key = "table_name", .field = pq.PG_DIAG_TABLE_NAME },
        .{ .key = "column_name", .field = pq.PG_DIAG_COLUMN_NAME },
        .{ .key = "datatype_name", .field = pq.PG_DIAG_DATATYPE_NAME },
        .{ .key = "constraint_name", .field = pq.PG_DIAG_CONSTRAINT_NAME },
    };
    var extras: std.ArrayList(wasmtime.c.wasmtime_component_val_t) = .empty;
    for (extra_fields) |ef| {
        if (diagField(res, ef.field)) |v| {
            extras.append(arena, wasmtime.Val.tuple2(wasmtime.Val.string(ef.key), wasmtime.Val.string(v))) catch break;
        }
    }

    const db_error = wasmtime.Val.record(&.{
        wasmtime.Val.recordEntry("as-text", wasmtime.Val.string(as_text)),
        wasmtime.Val.recordEntry("severity", wasmtime.Val.string(severity)),
        wasmtime.Val.recordEntry("code", wasmtime.Val.string(sqlstate.?)),
        wasmtime.Val.recordEntry("message", wasmtime.Val.string(message)),
        wasmtime.Val.recordEntry("detail", wasmtime.Val.option(if (detail) |d| wasmtime.Val.string(d) else null)),
        wasmtime.Val.recordEntry("extras", wasmtime.Val.list(extras.items)),
    });
    return wasmtime.Val.variant("db-error", db_error);
}
