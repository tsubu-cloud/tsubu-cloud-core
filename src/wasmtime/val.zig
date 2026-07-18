const std = @import("std");
const c = @import("c.zig").c;

/// Helpers for building and reading `wasmtime_component_val_t` values.
///
/// The `_new`-family C functions copy the top-level struct bytes of what's
/// passed in (like `wasm_functype_new` does for valtypes), transferring
/// ownership of any nested heap data (strings, nested lists/records) into the
/// newly created value. Callers should not separately free the arguments
/// passed to these builders.
pub const Val = struct {
    pub fn string(bytes: []const u8) c.wasmtime_component_val_t {
        var name: c.wasm_name_t = undefined;
        c.wasm_name_new(&name, bytes.len, bytes.ptr);
        return .{ .kind = c.WASMTIME_COMPONENT_STRING, .of = .{ .string = name } };
    }

    pub fn u8Val(v: u8) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_U8, .of = .{ .u8 = v } };
    }

    pub fn u16Val(v: u16) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_U16, .of = .{ .u16 = v } };
    }

    pub fn boolVal(v: bool) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_BOOL, .of = .{ .boolean = v } };
    }

    pub fn s8Val(v: i8) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_S8, .of = .{ .s8 = v } };
    }

    pub fn s16Val(v: i16) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_S16, .of = .{ .s16 = v } };
    }

    pub fn s32Val(v: i32) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_S32, .of = .{ .s32 = v } };
    }

    pub fn s64Val(v: i64) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_S64, .of = .{ .s64 = v } };
    }

    pub fn f32Val(v: f32) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_F32, .of = .{ .f32 = v } };
    }

    pub fn f64Val(v: f64) c.wasmtime_component_val_t {
        return .{ .kind = c.WASMTIME_COMPONENT_F64, .of = .{ .f64 = v } };
    }

    /// Builds a variant value with discriminant `name` and optional `payload`.
    /// The payload, if present, is moved onto a wasmtime-owned heap
    /// allocation (see the module doc comment on ownership).
    pub fn variant(name: []const u8, payload: ?c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var disc: c.wasm_name_t = undefined;
        c.wasm_name_new(&disc, name.len, name.ptr);
        var payload_ptr: ?*c.wasmtime_component_val_t = null;
        if (payload) |p| {
            var tmp = p;
            payload_ptr = c.wasmtime_component_val_new(&tmp);
        }
        return .{ .kind = c.WASMTIME_COMPONENT_VARIANT, .of = .{ .variant = .{ .discriminant = disc, .val = payload_ptr } } };
    }

    /// Builds a `result<ok, err>` value. `is_ok` selects which of `val`'s
    /// interpretation applies; `val` is moved onto a wasmtime-owned heap
    /// allocation.
    pub fn result(is_ok: bool, val: c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var tmp = val;
        const ptr = c.wasmtime_component_val_new(&tmp);
        return .{ .kind = c.WASMTIME_COMPONENT_RESULT, .of = .{ .result = .{ .is_ok = is_ok, .val = ptr } } };
    }

    /// Builds an `option<T>` value; `null` maps to `none`.
    pub fn option(val: ?c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var ptr: ?*c.wasmtime_component_val_t = null;
        if (val) |v| {
            var tmp = v;
            ptr = c.wasmtime_component_val_new(&tmp);
        }
        return .{ .kind = c.WASMTIME_COMPONENT_OPTION, .of = .{ .option = ptr } };
    }

    pub fn tuple2(a: c.wasmtime_component_val_t, b: c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var items = [_]c.wasmtime_component_val_t{ a, b };
        var vec: c.wasmtime_component_valtuple_t = undefined;
        c.wasmtime_component_valtuple_new(&vec, items.len, &items);
        return .{ .kind = c.WASMTIME_COMPONENT_TUPLE, .of = .{ .tuple = vec } };
    }

    /// Builds a tuple value of arbitrary arity.
    pub fn tuple(items: []const c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var vec: c.wasmtime_component_valtuple_t = undefined;
        c.wasmtime_component_valtuple_new(&vec, items.len, items.ptr);
        return .{ .kind = c.WASMTIME_COMPONENT_TUPLE, .of = .{ .tuple = vec } };
    }

    pub fn list(items: []const c.wasmtime_component_val_t) c.wasmtime_component_val_t {
        var vec: c.wasmtime_component_vallist_t = undefined;
        c.wasmtime_component_vallist_new(&vec, items.len, items.ptr);
        return .{ .kind = c.WASMTIME_COMPONENT_LIST, .of = .{ .list = vec } };
    }

    pub fn recordEntry(name: []const u8, val: c.wasmtime_component_val_t) c.wasmtime_component_valrecord_entry_t {
        var entry_name: c.wasm_name_t = undefined;
        c.wasm_name_new(&entry_name, name.len, name.ptr);
        return .{ .name = entry_name, .val = val };
    }

    pub fn record(entries: []const c.wasmtime_component_valrecord_entry_t) c.wasmtime_component_val_t {
        var vec: c.wasmtime_component_valrecord_t = undefined;
        c.wasmtime_component_valrecord_new(&vec, entries.len, entries.ptr);
        return .{ .kind = c.WASMTIME_COMPONENT_RECORD, .of = .{ .record = vec } };
    }

    /// Returns the discriminant name of a variant value, or `null` if `v` is
    /// not a variant.
    pub fn variantName(v: c.wasmtime_component_val_t) ?[]const u8 {
        if (v.kind != c.WASMTIME_COMPONENT_VARIANT) return null;
        const disc = v.of.variant.discriminant;
        return disc.data[0..disc.size];
    }

    /// Returns the payload of a variant value, if any.
    pub fn variantPayload(v: c.wasmtime_component_val_t) ?c.wasmtime_component_val_t {
        if (v.kind != c.WASMTIME_COMPONENT_VARIANT) return null;
        const ptr = v.of.variant.val orelse return null;
        return ptr.*;
    }

    /// Looks up a field by name in a record value. Returns null if `rec` is
    /// not a record or has no field named `name`.
    pub fn field(rec: c.wasmtime_component_val_t, name: []const u8) ?c.wasmtime_component_val_t {
        if (rec.kind != c.WASMTIME_COMPONENT_RECORD) return null;
        const entries = rec.of.record.data[0..rec.of.record.size];
        for (entries) |entry| {
            const entry_name = entry.name.data[0..entry.name.size];
            if (std.mem.eql(u8, entry_name, name)) return entry.val;
        }
        return null;
    }

    /// Returns the bytes of a string value, or `null` if `v` is not a string.
    pub fn asString(v: c.wasmtime_component_val_t) ?[]const u8 {
        if (v.kind != c.WASMTIME_COMPONENT_STRING) return null;
        return v.of.string.data[0..v.of.string.size];
    }

    /// Returns the value of a `u16`, or `null` if `v` is not a `u16`.
    pub fn asU16(v: c.wasmtime_component_val_t) ?u16 {
        if (v.kind != c.WASMTIME_COMPONENT_U16) return null;
        return v.of.u16;
    }

    /// Returns the elements of a list value, or `null` if `v` is not a list.
    pub fn asList(v: c.wasmtime_component_val_t) ?[]const c.wasmtime_component_val_t {
        if (v.kind != c.WASMTIME_COMPONENT_LIST) return null;
        return v.of.list.data[0..v.of.list.size];
    }

    /// Returns the elements of a tuple value, or `null` if `v` is not a tuple.
    pub fn asTuple(v: c.wasmtime_component_val_t) ?[]const c.wasmtime_component_val_t {
        if (v.kind != c.WASMTIME_COMPONENT_TUPLE) return null;
        return v.of.tuple.data[0..v.of.tuple.size];
    }

    /// Deallocates any heap memory owned by `v` (nested strings, lists,
    /// records, etc). Does not deallocate `v` itself, since it is normally
    /// stack-allocated by callers.
    pub fn deinit(v: c.wasmtime_component_val_t) void {
        var tmp = v;
        c.wasmtime_component_val_delete(&tmp);
    }
};
