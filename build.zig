const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wasmtime ships no pkg-config file, so its include/lib directories are
    // supplied explicitly (e.g. from the Nix package's `dev`/`lib` outputs).
    const wasmtime_include_dir = nonEmpty(b.option([]const u8, "wasmtime-include", "Path to wasmtime's include directory"));
    const wasmtime_lib_dir = nonEmpty(b.option([]const u8, "wasmtime-lib", "Path to wasmtime's lib directory"));

    // libpq is used by `src/hosts/postgres/*` (the wasm guest's runtime host
    // import for connecting to user-supplied Postgres databases).
    //
    // Static libpq.a doesn't bundle its own transitive dependencies (unlike
    // the shared build), so its lib dir (containing pgcommon/pgport
    // alongside it, which ship no pkg-config file of their own) must be
    // supplied explicitly.
    const pq_lib_dir = nonEmpty(b.option([]const u8, "pq-lib", "Path to libpq's lib directory"));

    // libunwind pulls in liblzma (xz) transitively via its pkg-config
    // `Requires.private`; needs its own explicit lib dir for the same
    // reason as pq-lib above.
    const lzma_lib_dir = nonEmpty(b.option([]const u8, "lzma-lib", "Path to liblzma's lib directory"));

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkWasmtime(core_mod, wasmtime_include_dir, wasmtime_lib_dir, lzma_lib_dir);
    linkLibpq(core_mod, pq_lib_dir);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
}

// `b.dependency()` callers forward unset string options as `""` rather than
// omitting them, since `anytype` struct literals can't conditionally include
// fields; normalize that back to `null` here.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    if (s) |v| return if (v.len == 0) null else v;
    return null;
}

fn linkWasmtime(
    mod: *std.Build.Module,
    include_dir: ?[]const u8,
    lib_dir: ?[]const u8,
    lzma_lib_dir: ?[]const u8,
) void {
    if (include_dir) |dir| mod.addIncludePath(.{ .cwd_relative = dir });
    if (lib_dir) |dir| mod.addLibraryPath(.{ .cwd_relative = dir });
    // Bytecode Alliance's prebuilt wasmtime ships only a static
    // `libwasmtime.a`; force static linking so zig's `paths_first` strategy
    // doesn't fall back to "no shared lib found → undefined symbol" rather
    // than picking the .a up via -L.
    mod.linkSystemLibrary("wasmtime", .{
        .use_pkg_config = .no,
        .preferred_link_mode = .static,
    });
    mod.link_libc = true;
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("m", .{});
    mod.linkSystemLibrary("unwind", .{ .preferred_link_mode = .static });
    if (lzma_lib_dir) |dir| mod.addLibraryPath(.{ .cwd_relative = dir });
    mod.linkSystemLibrary("lzma", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
}

fn linkLibpq(mod: *std.Build.Module, lib_dir: ?[]const u8) void {
    mod.linkSystemLibrary("pq", .{
        .use_pkg_config = .yes,
        .preferred_link_mode = .static,
    });
    mod.link_libc = true;

    if (lib_dir) |dir| mod.addLibraryPath(.{ .cwd_relative = dir });
    mod.linkSystemLibrary("pgcommon", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
    mod.linkSystemLibrary("pgport", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
    mod.linkSystemLibrary("ssl", .{ .use_pkg_config = .yes, .preferred_link_mode = .static });
    mod.linkSystemLibrary("crypto", .{ .use_pkg_config = .yes, .preferred_link_mode = .static });
}
