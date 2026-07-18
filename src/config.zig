const std = @import("std");

pub const FetchTarget = struct {
    alias: []const u8,
    target: []const u8,
};

pub const PostgresTarget = struct {
    alias: []const u8,
    database_url: []const u8,
};

pub const VariableTarget = struct {
    alias: []const u8,
    value: []const u8,
};

/// Default cap on a wasm instance's linear memory, in bytes (256 MiB).
pub const default_max_memory_bytes: u64 = 256 * 1024 * 1024;

/// Default fuel budget for a single `handler` invocation. Fuel is consumed
/// roughly per wasm instruction executed, so this bounds runaway/infinite
/// loops in untrusted components rather than corresponding to a fixed wall-
/// clock time.
pub const default_max_fuel: u64 = 5_000_000_000;

/// Default wall-clock budget for a single `handler` invocation, in
/// milliseconds. Unlike `max_fuel` this bounds real elapsed time, so it also
/// catches wasm that's blocked (e.g. on a slow host call) rather than
/// burning instructions.
pub const default_max_wall_time_ms: u64 = 10_000;

pub const Config = struct {
    fetch_targets: []FetchTarget,
    postgres_targets: []PostgresTarget,
    variable_targets: []VariableTarget,
    max_memory_bytes: u64 = default_max_memory_bytes,
    max_fuel: u64 = default_max_fuel,
    max_wall_time_ms: u64 = default_max_wall_time_ms,

    pub fn deinit(self: Config, gpa: std.mem.Allocator) void {
        for (self.fetch_targets) |t| {
            gpa.free(t.alias);
            gpa.free(t.target);
        }
        gpa.free(self.fetch_targets);
        for (self.postgres_targets) |t| {
            gpa.free(t.alias);
            gpa.free(t.database_url);
        }
        gpa.free(self.postgres_targets);
        for (self.variable_targets) |t| {
            gpa.free(t.alias);
            gpa.free(t.value);
        }
        gpa.free(self.variable_targets);
    }
};
