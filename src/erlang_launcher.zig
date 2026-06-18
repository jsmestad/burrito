const std = @import("std");

const builtin = @import("builtin");
const Io = std.Io;
const log = std.log;
const metadata = @import("metadata.zig");

const MetaStruct = metadata.MetaStruct;

const MAX_READ_SIZE = 256;

fn get_erl_exe_name() []const u8 {
    if (builtin.os.tag == .windows) {
        return "erl.exe";
    } else {
        return "erlexec";
    }
}

pub fn launch(io: Io, install_dir: []const u8, env_map: *std.process.Environ.Map, meta: *const MetaStruct, self_path: []const u8, args_trimmed: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    // Computer directories we care about
    const release_cookie_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", "COOKIE" });
    const release_lib_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "lib" });
    const install_vm_args_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "vm.args" });
    const config_sys_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "sys.config" });
    const config_sys_path_no_ext = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "sys" });
    const rel_vsn_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version });
    const boot_path = try std.fs.path.join(allocator, &[_][]const u8{ rel_vsn_dir, "start" });

    const erts_version_name = try std.fmt.allocPrint(allocator, "erts-{s}", .{meta.erts_version});
    const erts_bin_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, erts_version_name, "bin" });
    const erl_bin_path = try std.fs.path.join(allocator, &[_][]const u8{ erts_bin_path, get_erl_exe_name() });

    // Read the Erlang COOKIE file for the release
    const release_cookie_file = try Io.Dir.openFileAbsolute(io, release_cookie_path, .{ .mode = .read_write });
    defer release_cookie_file.close(io);
    var read_buf: [1024]u8 = undefined;
    var cookie_reader = release_cookie_file.reader(io, &read_buf);
    var release_cookie_content: []const u8 = try cookie_reader.interface.allocRemaining(allocator, @enumFromInt(MAX_READ_SIZE));

    // Override the cookie if the env variable RELEASE_COOKIE is defined
    if (env_map.get("RELEASE_COOKIE")) |cookie| {
        release_cookie_content = cookie;
    }

    // Code loading mode. We default to interactive (lazy) loading so the BEAM
    // only loads and JIT-compiles modules on first use instead of eagerly at
    // boot. For a large, long-lived editor/CLI release this is a significant
    // startup-time win: most modules (agent/LLM stack, extension tooling, large
    // swaths of the app) are never needed to reach first paint.
    //
    // Set BURRITO_BOOT_MODE=embedded to restore the old eager-loading behavior
    // (e.g. if a missing-module-at-first-use problem surfaces). Interactive mode
    // defers any missing-module errors from boot to first use, which is the main
    // tradeoff to keep in mind.
    const boot_mode_flag = blk: {
        if (env_map.get("BURRITO_BOOT_MODE")) |mode| {
            if (std.mem.eql(u8, mode, "embedded")) break :blk "-mode embedded";
        }
        break :blk "-mode interactive";
    };

    // Set all the required release arguments
    const erlang_cli = &[_][]const u8{
        erl_bin_path[0..],
        "-elixir ansi_enabled true",
        "-noshell",
        "-s elixir start_cli",
        boot_mode_flag,
        "-setcookie",
        release_cookie_content,
        "-boot",
        boot_path,
        "-boot_var",
        "RELEASE_LIB",
        release_lib_path,
        "-args_file",
        install_vm_args_path,
        "-config",
        config_sys_path,
        "-extra",
    };

    if (builtin.os.tag == .windows) {
        // Fix up Windows 10+ consoles having ANSI escape support, but only if we set some flags
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli, args_trimmed });

        try env_map.put("RELEASE_ROOT", install_dir);
        try env_map.put("RELEASE_SYS_CONFIG", config_sys_path_no_ext);
        try env_map.put("__BURRITO", "1");
        try env_map.put("__BURRITO_BIN_PATH", self_path);

        var win_child_proc = std.process.Child.init(final_args, allocator);
        win_child_proc.env_map = env_map;
        win_child_proc.stdout_behavior = .Inherit;
        win_child_proc.stdin_behavior = .Inherit;

        log.debug("CLI List: {any}", .{final_args});

        const win_term = try win_child_proc.spawnAndWait();
        switch (win_term) {
            .Exited => |code| {
                std.process.exit(code);
            },
            else => std.process.exit(1),
        }
    } else {
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli, args_trimmed });

        log.debug("CLI List: {any}", .{final_args});

        try env_map.put("ROOTDIR", install_dir[0..]);
        try env_map.put("BINDIR", erts_bin_path[0..]);
        try env_map.put("RELEASE_ROOT", install_dir);
        try env_map.put("RELEASE_SYS_CONFIG", config_sys_path_no_ext);
        try env_map.put("__BURRITO", "1");
        try env_map.put("__BURRITO_BIN_PATH", self_path);

        // Extend LD_LIBRARY_PATH so NIF .so files can find system shared
        // libraries (e.g. libgcc_s.so.1) when using a custom glibc ERTS
        const system_lib_paths = "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib";
        if (env_map.get("LD_LIBRARY_PATH")) |existing| {
            const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ existing, system_lib_paths });
            try env_map.put("LD_LIBRARY_PATH", combined);
        } else {
            try env_map.put("LD_LIBRARY_PATH", system_lib_paths);
        }

        return std.process.replace(io, .{
            .argv = final_args,
            .environ_map = env_map,
        });
    }
}
