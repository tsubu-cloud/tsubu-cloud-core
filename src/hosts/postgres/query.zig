const std = @import("std");
const wasmtime = @import("../../wasmtime/root.zig");
const types = @import("types.zig");
const pq = types.pq;
const QueryContext = types.QueryContext;
const value = @import("value.zig");
const param = @import("param.zig");
const errors = @import("errors.zig");

/// Component import `{ALIAS}: func(statement: string, params:
/// list<parameter-value>) -> result<row-set, error>`, where `{ALIAS}` is the
/// `ALIAS` configured for this connection in `tsubu.json`.
///
/// Opens a fresh connection to the pre-configured `database_url` for each
/// call, runs the statement via `PQexecParams`, and converts the result into
/// the WIT `row-set` shape.
pub fn hostQueryExample(
    env: ?*anyopaque,
    context: ?*wasmtime.c.wasmtime_context_t,
    ty: ?*const wasmtime.c.wasmtime_component_func_type_t,
    args: [*c]wasmtime.c.wasmtime_component_val_t,
    nargs: usize,
    results: [*c]wasmtime.c.wasmtime_component_val_t,
    nresults: usize,
) callconv(.c) ?*wasmtime.c.wasmtime_error_t {
    _ = context;
    _ = ty;
    _ = nargs;
    _ = nresults;
    const ctx: *QueryContext = @ptrCast(@alignCast(env.?));
    const gpa = ctx.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const statement_val = args[0].of.string;
    const statement = arena.dupeZ(u8, statement_val.data[0..statement_val.size]) catch
        return wasmtime.c.wasmtime_error_new("out of memory");

    const params_val = args[1];
    const param_items = params_val.of.list.data[0..params_val.of.list.size];

    var param_values = arena.alloc(?[*:0]const u8, param_items.len) catch
        return wasmtime.c.wasmtime_error_new("out of memory");
    for (param_items, 0..) |item, i| {
        const text = param.paramToText(arena, item) catch {
            results[0] = wasmtime.Val.result(false, wasmtime.Val.variant("bad-parameter", wasmtime.Val.string("unsupported parameter type")));
            return null;
        };
        param_values[i] = if (text) |t| t.ptr else null;
    }

    const database_url = arena.dupeZ(u8, ctx.database_url) catch
        return wasmtime.c.wasmtime_error_new("out of memory");

    const conn = pq.PQconnectdb(database_url.ptr) orelse
        return wasmtime.c.wasmtime_error_new("out of memory");
    defer pq.PQfinish(conn);

    if (pq.PQstatus(conn) != pq.CONNECTION_OK) {
        const err_msg = std.mem.sliceTo(pq.PQerrorMessage(conn), 0);
        results[0] = wasmtime.Val.result(false, wasmtime.Val.variant("connection-failed", wasmtime.Val.string(err_msg)));
        return null;
    }

    const res = pq.PQexecParams(conn, statement.ptr, @intCast(param_items.len), null, param_values.ptr, null, null, 0);
    defer pq.PQclear(res);

    const status = pq.PQresultStatus(res);
    if (status != pq.PGRES_TUPLES_OK and status != pq.PGRES_COMMAND_OK) {
        results[0] = wasmtime.Val.result(false, wasmtime.Val.variant("query-failed", errors.queryErrorVal(arena, res)));
        return null;
    }

    const nfields: usize = @intCast(pq.PQnfields(res));
    const ntuples: usize = @intCast(pq.PQntuples(res));

    var col_types = arena.alloc(pq.Oid, nfields) catch
        return wasmtime.c.wasmtime_error_new("out of memory");
    for (0..nfields) |f| col_types[f] = pq.PQftype(res, @intCast(f));

    var rows = arena.alloc(wasmtime.c.wasmtime_component_val_t, ntuples) catch
        return wasmtime.c.wasmtime_error_new("out of memory");
    for (0..ntuples) |r| {
        var cells = arena.alloc(wasmtime.c.wasmtime_component_val_t, nfields) catch
            return wasmtime.c.wasmtime_error_new("out of memory");
        for (0..nfields) |f| {
            const oid = col_types[f];
            const is_null = pq.PQgetisnull(res, @intCast(r), @intCast(f)) != 0;
            const text = if (is_null) "" else std.mem.sliceTo(pq.PQgetvalue(res, @intCast(r), @intCast(f)), 0);
            cells[f] = value.dbValue(arena, oid, is_null, text);
        }
        rows[r] = wasmtime.Val.list(cells);
    }

    var column_entries = arena.alloc(wasmtime.c.wasmtime_component_val_t, nfields) catch
        return wasmtime.c.wasmtime_error_new("out of memory");
    for (0..nfields) |f| {
        const oid = col_types[f];
        const fname = std.mem.sliceTo(pq.PQfname(res, @intCast(f)), 0);
        column_entries[f] = wasmtime.Val.record(&.{
            wasmtime.Val.recordEntry("name", wasmtime.Val.string(fname)),
            wasmtime.Val.recordEntry("data-type", types.dbDataType(oid)),
        });
    }

    const row_set = wasmtime.Val.record(&.{
        wasmtime.Val.recordEntry("columns", wasmtime.Val.list(column_entries)),
        wasmtime.Val.recordEntry("rows", wasmtime.Val.list(rows)),
    });
    results[0] = wasmtime.Val.result(true, row_set);
    return null;
}
