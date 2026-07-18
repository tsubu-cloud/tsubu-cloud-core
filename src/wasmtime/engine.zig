const std = @import("std");
const root = @import("c.zig");
const c = root.c;
const Error = root.Error;
const captureMessage = root.captureMessage;

pub const Engine = struct {
    ptr: *c.wasm_engine_t,

    pub fn init() Error!Engine {
        const config = c.wasm_config_new() orelse return error.EngineInit;
        c.wasmtime_config_wasm_component_model_set(config, true);
        // Fuel is consumed roughly per wasm instruction executed; enabling
        // it here lets `Store.init` bound a component's execution so a
        // runaway/infinite loop in untrusted wasm traps instead of hanging
        // the host indefinitely.
        c.wasmtime_config_consume_fuel_set(config, true);
        // Epoch interruption lets a background thread abort a call once a
        // wall-clock deadline passes, catching wasm that's merely blocked
        // (e.g. on a slow host call) rather than burning instructions, which
        // fuel alone wouldn't catch. See `Store.init`'s epoch deadline and
        // `runner.runWasm`'s timeout thread for the other half of this.
        c.wasmtime_config_epoch_interruption_set(config, true);
        return .{ .ptr = c.wasm_engine_new_with_config(config) orelse return error.EngineInit };
    }

    /// Increments this engine's epoch, causing any in-progress call in a
    /// `Store` whose epoch deadline has been exceeded to trap. Safe to call
    /// from any thread.
    pub fn incrementEpoch(self: Engine) void {
        c.wasmtime_engine_increment_epoch(self.ptr);
    }

    pub fn deinit(self: Engine) void {
        c.wasm_engine_delete(self.ptr);
    }
};

pub const Store = struct {
    ptr: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,

    /// Resource limits applied to every instance created within a `Store`.
    /// `memory_bytes` caps linear memory growth; `fuel` caps roughly how
    /// many wasm instructions may execute before a call traps. Table/
    /// instance/memory counts are pinned to the single instance a `Store`
    /// is expected to host (see `runner.runWasm`), since each `Store` here
    /// is created fresh for one `handler` call.
    pub const Limits = struct {
        memory_bytes: u64,
        fuel: u64,
    };

    pub fn init(engine: Engine, limits: Limits) Error!Store {
        const ptr = c.wasmtime_store_new(engine.ptr, null, null) orelse return error.StoreInit;
        const context = c.wasmtime_store_context(ptr).?;

        c.wasmtime_store_limiter(
            ptr,
            @intCast(limits.memory_bytes),
            -1, // table_elements: keep wasmtime's default
            8, // instances: a component may instantiate multiple imported
            //  component-instances alongside its own (e.g. one per imported
            //  interface like `tsubu-cloud:fetcher/fetcher`), so allow some
            //  headroom rather than pinning to 1.
            4, // tables: generous headroom for a single component
            1, // memories: one component instance per Store
        );

        if (c.wasmtime_context_set_fuel(context, limits.fuel)) |err| {
            c.wasmtime_error_delete(err);
            return error.StoreInit;
        }

        // Deadline is 1 tick beyond the engine's current epoch, so a single
        // `Engine.incrementEpoch` call (from the timeout thread in
        // `runner.runWasm`) is enough to trap an in-progress call.
        c.wasmtime_context_set_epoch_deadline(context, 1);

        return .{ .ptr = ptr, .context = context };
    }

    pub fn deinit(self: Store) void {
        c.wasmtime_store_delete(self.ptr);
    }

    pub fn setWasi(self: Store, gpa: std.mem.Allocator, message: *?[]u8) !void {
        const wasi_config = c.wasi_config_new() orelse return error.WasiConfigInit;
        if (c.wasmtime_context_set_wasi(self.context, wasi_config)) |err| {
            try captureMessage(gpa, message, err);
            return error.WasiConfigSet;
        }
    }
};
