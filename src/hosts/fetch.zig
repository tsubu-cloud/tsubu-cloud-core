const std = @import("std");
const wasmtime = @import("../wasmtime/root.zig");

pub const FetchContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The whitelisted target URL this `fetch-{id}` import is bound to.
    /// The guest supplies method/headers/body but never the destination URL.
    target: []const u8,
};

/// Component import `fetch-{id}: func(request: request) -> response`, where
/// `request` is `{ method: string, headers: list<tuple<string, string>>,
/// body: string }` and `response` is `{ status: u16, headers:
/// list<tuple<string, string>>, body: string }`.
///
/// Performs a real HTTP request against the pre-configured `target` (from
/// `tsubu.json`), using the method/headers/body supplied by the guest.
/// Response headers are not populated (left empty) since the convenience
/// `std.http.Client.fetch` API used here doesn't expose them.
pub fn hostFetch(
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
    const ctx: *FetchContext = @ptrCast(@alignCast(env.?));

    const request = args[0];
    const method_val = wasmtime.Val.field(request, "method").?;
    const headers_val = wasmtime.Val.field(request, "headers").?;
    const body_val = wasmtime.Val.field(request, "body").?;

    const method_str = method_val.of.string;
    const method = std.meta.stringToEnum(std.http.Method, method_str.data[0..method_str.size]) orelse .GET;

    const body_str = body_val.of.string;
    const body = body_str.data[0..body_str.size];

    const header_items = headers_val.of.list.data[0..headers_val.of.list.size];
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(ctx.gpa);
    for (header_items) |item| {
        const name_val = item.of.tuple.data[0];
        const value_val = item.of.tuple.data[1];
        extra_headers.append(ctx.gpa, .{
            .name = name_val.of.string.data[0..name_val.of.string.size],
            .value = value_val.of.string.data[0..value_val.of.string.size],
        }) catch return wasmtime.c.wasmtime_error_new("out of memory");
    }

    var response: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer response.deinit();

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    const fetch_start_ts = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const status: u16 = blk: {
        const result = client.fetch(.{
            .location = .{ .url = ctx.target },
            .method = method,
            .payload = if (body.len > 0) body else null,
            .extra_headers = extra_headers.items,
            .response_writer = &response.writer,
        }) catch |err| {
            std.debug.print("fetch to {s} failed: {t}\n", .{ ctx.target, err });
            break :blk 0;
        };
        break :blk @intFromEnum(result.status);
    };
    const fetch_ms = @as(f64, @floatFromInt(fetch_start_ts.untilNow(ctx.io).raw.nanoseconds)) / std.time.ns_per_ms;
    std.debug.print("fetch to {s} status={d} took={d:.1}ms\n", .{ ctx.target, status, fetch_ms });

    results[0] = wasmtime.Val.record(&.{
        wasmtime.Val.recordEntry("status", wasmtime.Val.u16Val(status)),
        wasmtime.Val.recordEntry("headers", wasmtime.Val.list(&.{})),
        wasmtime.Val.recordEntry("body", wasmtime.Val.string(response.writer.buffered())),
    });
    return null;
}
