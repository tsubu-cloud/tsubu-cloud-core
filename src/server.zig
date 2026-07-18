const std = @import("std");
const runner = @import("runner.zig");
const tsubu_config = @import("config.zig");

/// Runs the precompiled artifact `cwasm_bytes` (see `runner.compileToCwasm`)
/// with `config` against `req` and relays its `response` record back to
/// `request`. Shared by every app's serve loop, since running a wasm
/// component and translating its result into an HTTP response is identical
/// regardless of how the app was resolved.
///
/// Returns every message the component logged during the call (owned
/// dupes, in call order); the caller takes ownership and must free each
/// message and the slice itself.
pub fn runAndRespond(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwasm_bytes: []const u8,
    config: tsubu_config.Config,
    req: runner.Request,
    request: *std.http.Server.Request,
) ![]const []const u8 {
    const run_outcome = runner.runWasm(gpa, io, cwasm_bytes, config, req) catch |err| {
        std.debug.print("failed to run wasm component: {t}\n", .{err});
        try request.respond("internal server error\n", .{ .status = .internal_server_error });
        return try gpa.alloc([]const u8, 0);
    };

    switch (run_outcome.outcome) {
        .exit_code => |code| {
            std.debug.print("wasm component exited with code {d}\n", .{code});
            try request.respond("internal server error\n", .{ .status = .internal_server_error });
        },
        .response => |response| {
            defer response.deinit(gpa);

            const extra_headers = try gpa.alloc(std.http.Header, response.headers.len);
            defer gpa.free(extra_headers);
            for (response.headers, extra_headers) |h, *eh| {
                eh.* = .{ .name = h[0], .value = h[1] };
            }

            try request.respond(response.body, .{
                .status = @enumFromInt(response.status),
                .extra_headers = extra_headers,
            });
        },
    }

    return run_outcome.log_messages;
}
