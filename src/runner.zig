const std = @import("std");
const wasmtime = @import("wasmtime/root.zig");
const tsubu_config = @import("config.zig");
const hosts = @import("hosts/root.zig");
const Val = wasmtime.Val;

fn durationMs(since: std.Io.Clock.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(since.untilNow(io).raw.nanoseconds)) / std.time.ns_per_ms;
}

fn printFailure(comptime msg: []const u8, message: ?[]u8) void {
    if (message) |m| {
        std.debug.print(msg ++ ": {s}\n", .{m});
    } else {
        std.debug.print(msg ++ "\n", .{});
    }
}

/// The HTTP request handed to the wasm component's `handler` export.
pub const Request = struct {
    url: []const u8,
    method: []const u8,
    headers: []const [2][]const u8 = &.{},
    body: []const u8 = "",
};

/// The HTTP response produced by the wasm component's `handler` export.
/// Owns `headers` (and each name/value) and `body`; free with `deinit`.
pub const Response = struct {
    status: u16,
    headers: [][2][]const u8,
    body: []u8,

    pub fn deinit(self: Response, gpa: std.mem.Allocator) void {
        for (self.headers) |h| {
            gpa.free(h[0]);
            gpa.free(h[1]);
        }
        gpa.free(self.headers);
        gpa.free(self.body);
    }
};

pub const Outcome = union(enum) {
    response: Response,
    exit_code: u8,
};

/// `runWasm`'s result: the response/exit outcome, plus every message the
/// component logged via `tsubu-cloud:logger/logger` during the call (owned
/// dupes, in call order). Free with `deinit`.
pub const RunOutcome = struct {
    outcome: Outcome,
    log_messages: []const []const u8,

    pub fn deinit(self: RunOutcome, gpa: std.mem.Allocator) void {
        for (self.log_messages) |m| gpa.free(m);
        gpa.free(self.log_messages);
    }
};

/// Compiles `wasm_bytes` (a wasm component) into a precompiled artifact
/// ("cwasm", see `wasmtime.Component.serialize`), suitable for loading later
/// via `runWasm` without recompiling. Every caller of `runWasm` is expected
/// to go through this first, whether or not the result is persisted, so that
/// `runWasm` itself only ever has to deserialize.
pub fn compileToCwasm(gpa: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var message: ?[]u8 = null;
    defer if (message) |m| gpa.free(m);

    const engine = try wasmtime.Engine.init();
    defer engine.deinit();

    const component = wasmtime.Component.init(engine, wasm_bytes, gpa, &message) catch |err| {
        printFailure("failed to compile component", message);
        return err;
    };
    defer component.deinit();

    return component.serialize(gpa, &message) catch |err| {
        printFailure("failed to serialize component", message);
        return err;
    };
}

/// Deserializes and instantiates the precompiled artifact `cwasm_bytes` (see
/// `compileToCwasm`), then invokes its `handler` export once with `request`.
/// Every part of the wasm runtime (engine, component, linker, store) is set
/// up fresh for this single call. `config` supplies the fetch/postgres/
/// variables/log host imports to wire up; it is not owned by this function.
pub fn runWasm(gpa: std.mem.Allocator, io: std.Io, cwasm_bytes: []const u8, config: tsubu_config.Config, request: Request) !RunOutcome {
    var message: ?[]u8 = null;
    defer if (message) |m| gpa.free(m);

    var log_context: hosts.LogContext = .{ .gpa = gpa };
    errdefer {
        for (log_context.messages.items) |m| gpa.free(m);
        log_context.messages.deinit(gpa);
    }

    const start_ts = std.Io.Clock.Timestamp.now(io, .awake);
    defer std.debug.print("runWasm total={d:.1}ms\n", .{durationMs(start_ts, io)});

    const engine = try wasmtime.Engine.init();
    defer engine.deinit();

    const store = try wasmtime.Store.init(engine, .{
        .memory_bytes = config.max_memory_bytes,
        .fuel = config.max_fuel,
    });
    defer store.deinit();

    store.setWasi(gpa, &message) catch |err| {
        printFailure("failed to set wasi config", message);
        return err;
    };

    const component = wasmtime.Component.deserialize(engine, cwasm_bytes, gpa, &message) catch |err| {
        printFailure("failed to deserialize component", message);
        return err;
    };
    defer component.deinit();

    const linker = try wasmtime.ComponentLinker.init(engine);
    defer linker.deinit();

    linker.addWasip2(gpa, &message) catch |err| {
        printFailure("failed to link wasip2", message);
        return err;
    };

    const fetch_targets = config.fetch_targets;
    const fetch_contexts = try gpa.alloc(hosts.FetchContext, fetch_targets.len);
    defer gpa.free(fetch_contexts);
    for (fetch_targets, fetch_contexts) |t, *fc| {
        fc.* = .{ .gpa = gpa, .io = io, .target = t.target };
    }

    const fetch_names = try gpa.alloc([]u8, fetch_targets.len);
    defer {
        for (fetch_names) |n| gpa.free(n);
        gpa.free(fetch_names);
    }

    const postgres_targets = config.postgres_targets;
    const query_contexts = try gpa.alloc(hosts.QueryContext, postgres_targets.len);
    defer gpa.free(query_contexts);
    for (postgres_targets, query_contexts) |t, *qc| {
        qc.* = .{ .gpa = gpa, .database_url = t.database_url };
    }

    const query_names = try gpa.alloc([]u8, postgres_targets.len);
    defer {
        for (query_names) |n| gpa.free(n);
        gpa.free(query_names);
    }

    const variable_targets = config.variable_targets;
    const variable_contexts = try gpa.alloc(hosts.VariableContext, variable_targets.len);
    defer gpa.free(variable_contexts);
    for (variable_targets, variable_contexts) |t, *vc| {
        vc.* = .{ .value = t.value };
    }

    const variable_names = try gpa.alloc([]u8, variable_targets.len);
    defer {
        for (variable_names) |n| gpa.free(n);
        gpa.free(variable_names);
    }

    {
        const root = linker.root();
        defer root.deinit();

        {
            const package_instance = root.addInstance("tsubu-cloud:logger/logger", gpa, &message) catch |err| {
                printFailure("failed to define host instance", message);
                return err;
            };
            defer package_instance.deinit();

            package_instance.defineFunc("log", hosts.hostLog, &log_context, null, gpa, &message) catch |err| {
                printFailure("failed to define host function", message);
                return err;
            };
        }

        for (fetch_targets, fetch_contexts, fetch_names) |t, *fc, *name| {
            name.* = try gpa.dupe(u8, t.alias);

            const package_instance = root.addInstance("tsubu-cloud:fetcher/fetcher", gpa, &message) catch |err| {
                printFailure("failed to define host instance", message);
                return err;
            };
            defer package_instance.deinit();

            package_instance.defineFunc(name.*, hosts.hostFetch, fc, null, gpa, &message) catch |err| {
                printFailure("failed to define host function", message);
                return err;
            };
        }

        for (postgres_targets, query_contexts, query_names) |t, *qc, *name| {
            name.* = try gpa.dupe(u8, t.alias);

            const package_instance = root.addInstance("tsubu-cloud:postgres/postgres", gpa, &message) catch |err| {
                printFailure("failed to define host instance", message);
                return err;
            };
            defer package_instance.deinit();

            package_instance.defineFunc(name.*, hosts.hostQueryExample, qc, null, gpa, &message) catch |err| {
                printFailure("failed to define host function", message);
                return err;
            };
        }

        for (variable_targets, variable_contexts, variable_names) |t, *vc, *name| {
            name.* = try gpa.dupe(u8, t.alias);

            const package_instance = root.addInstance("tsubu-cloud:variables/variables", gpa, &message) catch |err| {
                printFailure("failed to define host instance", message);
                return err;
            };
            defer package_instance.deinit();

            package_instance.defineFunc(name.*, hosts.hostGetVariable, vc, null, gpa, &message) catch |err| {
                printFailure("failed to define host function", message);
                return err;
            };
        }
    }

    const setup_ms = durationMs(start_ts, io);

    const instantiate_start_ts = std.Io.Clock.Timestamp.now(io, .awake);
    const instance = linker.instantiate(store, component, gpa, &message) catch |err| {
        printFailure("failed to instantiate component", message);
        return err;
    };

    std.debug.print("runWasm setup={d:.1}ms instantiate={d:.1}ms\n", .{ setup_ms, durationMs(instantiate_start_ts, io) });

    const func = instance.getFunc(store.context, "handler") orelse {
        printFailure("failed to find 'handler' export", null);
        return error.ComponentGetFunc;
    };

    // Bounds wall-clock time on the upcoming `func.call` below: if
    // `call_done` isn't set within `config.max_wall_time_ms`, `timeoutPoll`
    // increments the engine epoch, which traps the in-progress call (see
    // the epoch deadline set in `Store.init`). If the call finishes first,
    // `call_done.store(true, ...)` lets the thread notice and exit without
    // incrementing the epoch.
    var call_done = std.atomic.Value(bool).init(false);
    const timeout_thread = try std.Thread.spawn(.{}, timeoutPoll, .{
        engine, &call_done, config.max_wall_time_ms * std.time.ns_per_ms,
    });
    defer {
        call_done.store(true, .release);
        timeout_thread.join();
    }

    const header_vals = try gpa.alloc(wasmtime.c.wasmtime_component_val_t, request.headers.len);
    defer gpa.free(header_vals);
    for (request.headers, header_vals) |h, *v| {
        v.* = Val.tuple2(Val.string(h[0]), Val.string(h[1]));
    }

    // `handler` takes a single `request` record and returns a `response`
    // record.
    var args_buf = [_]wasmtime.c.wasmtime_component_val_t{Val.record(&.{
        Val.recordEntry("url", Val.string(request.url)),
        Val.recordEntry("method", Val.string(request.method)),
        Val.recordEntry("headers", Val.list(header_vals)),
        Val.recordEntry("body", Val.string(request.body)),
    })};
    const args: []const wasmtime.c.wasmtime_component_val_t = &args_buf;
    defer Val.deinit(args_buf[0]);

    // Zero-initialized (not `undefined`): `wasmtime_component_func_call`
    // reads the existing contents of `results` to know how to drop any
    // previous value before writing the new one, so leaving this as
    // `undefined` garbage can crash inside libwasmtime.
    var results_buf: [1]wasmtime.c.wasmtime_component_val_t = @splat(std.mem.zeroes(wasmtime.c.wasmtime_component_val_t));
    const results: []wasmtime.c.wasmtime_component_val_t = &results_buf;

    const call_outcome = func.call(store.context, args, results, gpa, &message) catch |err| {
        printFailure("failed to call function", message);
        return err;
    };
    defer Val.deinit(results_buf[0]);

    switch (call_outcome) {
        .exit_code => |code| return .{
            .outcome = .{ .exit_code = code },
            .log_messages = try log_context.messages.toOwnedSlice(gpa),
        },
        .ok => {},
    }

    const response = try decodeResponse(gpa, results_buf[0]);
    return .{
        .outcome = .{ .response = response },
        .log_messages = try log_context.messages.toOwnedSlice(gpa),
    };
}

/// Polls `done` in short increments until either it's set or `timeout_ns`
/// total has elapsed, whichever comes first. On timeout, increments
/// `engine`'s epoch so that the call `done` is guarding traps (see the call
/// sites in `runWasm`).
fn timeoutPoll(engine: wasmtime.Engine, done: *std.atomic.Value(bool), timeout_ns: u64) void {
    const poll_interval_ns: u64 = 10 * std.time.ns_per_ms;
    var elapsed_ns: u64 = 0;
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(poll_interval_ns) };
    while (elapsed_ns < timeout_ns) {
        if (done.load(.acquire)) return;
        _ = std.c.nanosleep(&ts, null);
        elapsed_ns += poll_interval_ns;
    }
    if (!done.load(.acquire)) engine.incrementEpoch();
}

fn decodeResponse(gpa: std.mem.Allocator, val: wasmtime.c.wasmtime_component_val_t) !Response {
    const status_val = Val.field(val, "status") orelse return error.ComponentFuncCall;
    const status = Val.asU16(status_val) orelse return error.ComponentFuncCall;

    const headers_val = Val.field(val, "headers") orelse return error.ComponentFuncCall;
    const header_items = Val.asList(headers_val) orelse return error.ComponentFuncCall;

    const headers = try gpa.alloc([2][]const u8, header_items.len);
    errdefer gpa.free(headers);
    var filled: usize = 0;
    errdefer for (headers[0..filled]) |h| {
        gpa.free(h[0]);
        gpa.free(h[1]);
    };
    for (header_items, 0..) |item, i| {
        const pair = Val.asTuple(item) orelse return error.ComponentFuncCall;
        if (pair.len != 2) return error.ComponentFuncCall;
        const name = Val.asString(pair[0]) orelse return error.ComponentFuncCall;
        const value = Val.asString(pair[1]) orelse return error.ComponentFuncCall;
        headers[i] = .{ try gpa.dupe(u8, name), try gpa.dupe(u8, value) };
        filled = i + 1;
    }

    const body_val = Val.field(val, "body") orelse return error.ComponentFuncCall;
    const body_str = Val.asString(body_val) orelse return error.ComponentFuncCall;
    const body = try gpa.dupe(u8, body_str);
    errdefer gpa.free(body);

    return .{ .status = status, .headers = headers, .body = body };
}
