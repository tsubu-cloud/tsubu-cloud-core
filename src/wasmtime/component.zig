const std = @import("std");
const root = @import("c.zig");
const c = root.c;
const Error = root.Error;
const captureMessage = root.captureMessage;
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const Store = engine_mod.Store;

pub const Component = struct {
    ptr: ?*c.wasmtime_component_t,

    pub fn init(engine: Engine, wasm_bytes: []const u8, gpa: std.mem.Allocator, message: *?[]u8) !Component {
        var ptr: ?*c.wasmtime_component_t = null;
        if (c.wasmtime_component_new(engine.ptr, wasm_bytes.ptr, wasm_bytes.len, &ptr)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentCompile;
        }
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Component) void {
        c.wasmtime_component_delete(self.ptr);
    }

    /// Builds a component from a precompiled artifact previously produced by
    /// `serialize` (i.e. a "cwasm"), skipping the compilation step. The
    /// artifact must have been produced by an `Engine` with the same
    /// configuration as `engine`, and is not safe to load from untrusted
    /// input (per wasmtime's own caveat on `wasmtime_component_deserialize`).
    pub fn deserialize(engine: Engine, bytes: []const u8, gpa: std.mem.Allocator, message: *?[]u8) !Component {
        var ptr: ?*c.wasmtime_component_t = null;
        if (c.wasmtime_component_deserialize(engine.ptr, bytes.ptr, bytes.len, &ptr)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentDeserialize;
        }
        return .{ .ptr = ptr };
    }

    /// Serializes this (already-compiled) component into a precompiled
    /// artifact ("cwasm") that can later be loaded via `deserialize` without
    /// recompiling, as long as it's loaded by an `Engine` with the same
    /// configuration as the one that compiled it.
    pub fn serialize(self: Component, gpa: std.mem.Allocator, message: *?[]u8) ![]u8 {
        var buf: c.wasm_byte_vec_t = undefined;
        if (c.wasmtime_component_serialize(self.ptr, &buf)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentSerialize;
        }
        defer c.wasm_byte_vec_delete(&buf);
        return gpa.dupe(u8, buf.data[0..buf.size]);
    }
};

pub const ComponentFunc = struct {
    raw: c.wasmtime_component_func_t,

    pub const CallOutcome = union(enum) {
        ok,
        exit_code: u8,
    };

    pub fn call(
        self: ComponentFunc,
        context: *c.wasmtime_context_t,
        args: []const c.wasmtime_component_val_t,
        results: []c.wasmtime_component_val_t,
        gpa: std.mem.Allocator,
        message: *?[]u8,
    ) !CallOutcome {
        if (c.wasmtime_component_func_call(&self.raw, context, args.ptr, args.len, results.ptr, results.len)) |err| {
            var status: c_int = 0;
            if (c.wasmtime_error_exit_status(err, &status)) {
                c.wasmtime_error_delete(err);
                return .{ .exit_code = @intCast(status) };
            }
            try captureMessage(gpa, message, err);
            return error.ComponentFuncCall;
        }
        return .ok;
    }
};

pub const ComponentInstance = struct {
    raw: c.wasmtime_component_instance_t,

    pub fn getFunc(self: ComponentInstance, context: *c.wasmtime_context_t, name: []const u8) ?ComponentFunc {
        const export_index = c.wasmtime_component_instance_get_export_index(&self.raw, context, null, name.ptr, name.len) orelse return null;
        defer c.wasmtime_component_export_index_delete(export_index);

        var func: c.wasmtime_component_func_t = undefined;
        if (!c.wasmtime_component_instance_get_func(&self.raw, context, export_index, &func)) {
            return null;
        }
        return .{ .raw = func };
    }
};

/// The root namespace of a `ComponentLinker`, used to define host functions
/// that the component can import. Must be deinitialized before the linker
/// it was created from is used again.
pub const ComponentLinkerInstance = struct {
    ptr: *c.wasmtime_component_linker_instance_t,

    pub fn deinit(self: ComponentLinkerInstance) void {
        c.wasmtime_component_linker_instance_delete(self.ptr);
    }

    /// Defines a dynamically-typed host function named `name` so the
    /// component can import it. The number and kind of `wasmtime_component_val_t`
    /// values in `args`/`results` passed to `callback` are determined by the
    /// component's own type signature for this import.
    pub fn defineFunc(
        self: ComponentLinkerInstance,
        name: []const u8,
        callback: c.wasmtime_component_func_callback_t,
        data: ?*anyopaque,
        finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
        gpa: std.mem.Allocator,
        message: *?[]u8,
    ) !void {
        if (c.wasmtime_component_linker_instance_add_func(self.ptr, name.ptr, name.len, callback, data, finalizer)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentDefineFunc;
        }
    }

    /// Defines a nested instance named `name` within this instance, e.g. to
    /// satisfy a component import of a named WIT interface such as
    /// `tsubu-cloud:fetcher/fetcher`. The returned instance must be
    /// deinitialized before `self` is used again.
    pub fn addInstance(
        self: ComponentLinkerInstance,
        name: []const u8,
        gpa: std.mem.Allocator,
        message: *?[]u8,
    ) !ComponentLinkerInstance {
        var out: ?*c.wasmtime_component_linker_instance_t = null;
        if (c.wasmtime_component_linker_instance_add_instance(self.ptr, name.ptr, name.len, &out)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentDefineFunc;
        }
        return .{ .ptr = out.? };
    }
};

pub const ComponentLinker = struct {
    ptr: *c.wasmtime_component_linker_t,

    pub fn init(engine: Engine) Error!ComponentLinker {
        return .{ .ptr = c.wasmtime_component_linker_new(engine.ptr) orelse return error.LinkerInit };
    }

    pub fn deinit(self: ComponentLinker) void {
        c.wasmtime_component_linker_delete(self.ptr);
    }

    pub fn root(self: ComponentLinker) ComponentLinkerInstance {
        return .{ .ptr = c.wasmtime_component_linker_root(self.ptr).? };
    }

    pub fn addWasip2(self: ComponentLinker, gpa: std.mem.Allocator, message: *?[]u8) !void {
        if (c.wasmtime_component_linker_add_wasip2(self.ptr)) |err| {
            try captureMessage(gpa, message, err);
            return error.WasiLink;
        }
    }

    pub fn instantiate(self: ComponentLinker, store: Store, component: Component, gpa: std.mem.Allocator, message: *?[]u8) !ComponentInstance {
        var instance: c.wasmtime_component_instance_t = undefined;
        if (c.wasmtime_component_linker_instantiate(self.ptr, store.context, component.ptr, &instance)) |err| {
            try captureMessage(gpa, message, err);
            return error.ComponentInstantiate;
        }
        return .{ .raw = instance };
    }
};
