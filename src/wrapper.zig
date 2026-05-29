const builtin = @import("builtin");
const launcher = @import("erlang_launcher.zig");
const build_options = @import("build_options");
const std = @import("std");
const json = std.json;
const log = std.log;
const Io = std.Io;

const Sha1 = std.crypto.hash.Sha1;
const Base64 = std.base64.url_safe_no_pad.Encoder;

const foilz = @import("archiver.zig");

const logger = @import("logger.zig");
const maint = @import("maintenance.zig");

const install_suffix = ".burrito";

const plugin = @import("burrito_plugin");

const metadata = @import("metadata.zig");
const MetaStruct = metadata.MetaStruct;

const IS_LINUX = builtin.os.tag == .linux;

pub const FOILZ_PAYLOAD = @embedFile("payload.foilz.xz");
pub const RELEASE_METADATA_JSON = @embedFile("_metadata.json");

const windows = std.os.windows;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const args_trimmed = args[1..];

    const environ = init.minimal.environ;

    try maybe_install_musl_runtime(io, arena);

    const self_path = try std.process.executablePathAlloc(io, arena);

    const wants_clean_install = !build_options.IS_PROD;

    const meta = metadata.parse(arena, RELEASE_METADATA_JSON).?;
    const install_dir = try get_install_dir(io, environ, arena, &meta);
    const metadata_path = try std.fs.path.join(arena, &.{ install_dir, "_metadata.json" });

    if (args_trimmed.len > 0 and std.mem.eql(u8, args_trimmed[0], "maintenance")) {
        try maint.do_maint(io, args_trimmed[1..], install_dir);
        return;
    }

    log.debug("Size of embedded payload is: {}", .{FOILZ_PAYLOAD.len});
    log.debug("Install Directory: {s}", .{install_dir});
    log.debug("Metadata path: {s}", .{metadata_path});

    try Io.Dir.cwd().createDirPath(io, install_dir);

    var needs_install: bool = false;
    Io.Dir.cwd().access(io, metadata_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            needs_install = true;
        } else {
            log.err("We failed to open the destination directory with an unexpected error: {t}", .{err});
            return;
        }
    };

    log.debug("Passing args string: {any}", .{args_trimmed});

    plugin.burrito_plugin_entry(install_dir, RELEASE_METADATA_JSON);

    if (needs_install or wants_clean_install) {
        if (wants_clean_install and !needs_install) {
            try Io.Dir.cwd().deleteTree(io, install_dir);
            try Io.Dir.cwd().createDirPath(io, install_dir);
        }

        try do_payload_install(io, arena, install_dir, metadata_path);
    } else {
        log.debug("Skipping archive unpacking, this machine already has the app installed!", .{});
    }

    const base_install_path = try get_base_install_dir(io, environ, arena);
    try maint.do_clean_old_versions(io, base_install_path, install_dir);

    var env_map = try std.process.Environ.createMap(init.minimal.environ, arena);

    if (try Io.File.stdout().isTty(io)) {
        try env_map.put("_IS_TTY", "1");
    } else {
        try env_map.put("_IS_TTY", "0");
    }

    log.debug("Launching erlang...", .{});

    try launcher.launch(io, install_dir, &env_map, &meta, self_path, args_trimmed);
}

fn do_payload_install(io: Io, arena: std.mem.Allocator, install_dir: []const u8, metadata_path: []const u8) !void {
    try foilz.unpack_files(io, arena, FOILZ_PAYLOAD, install_dir, build_options.UNCOMPRESSED_SIZE);

    const file = try Io.Dir.cwd().createFile(io, metadata_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, RELEASE_METADATA_JSON, 0);
}

fn get_base_install_dir(_: Io, environ: std.process.Environ, arena: std.mem.Allocator) ![]const u8 {
    const upper_name = try std.ascii.allocUpperString(arena, build_options.RELEASE_NAME);
    const env_install_dir_name = try std.fmt.allocPrint(arena, "{s}_INSTALL_DIR", .{upper_name});

    var env_map = try std.process.Environ.createMap(environ, arena);
    defer env_map.deinit();

    if (env_map.get(env_install_dir_name)) |new_path| {
        logger.info("Install path is being overridden using `{s}`", .{env_install_dir_name});
        logger.info("New install path is: {s}", .{new_path});
        return try std.fs.path.join(arena, &[_][]const u8{ new_path, install_suffix });
    }

    const app_dir = get_app_data_dir(arena, install_suffix) catch {
        install_dir_error(arena);
        return "";
    };

    return app_dir;
}

fn get_app_data_dir(arena: std.mem.Allocator, appname: []const u8) ![]const u8 {
    const getenv = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const val = std.c.getenv(name) orelse return null;
            return std.mem.sliceTo(val, 0);
        }
    }.get;

    if (builtin.os.tag == .windows) {
        const appdata = getenv("APPDATA") orelse return error.AppDataDirUnavailable;
        return std.fs.path.join(arena, &.{ appdata, appname });
    } else if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        const home = getenv("HOME") orelse return error.AppDataDirUnavailable;
        return std.fs.path.join(arena, &.{ home, "Library", "Application Support", appname });
    } else {
        if (getenv("XDG_DATA_HOME")) |xdg| {
            return std.fs.path.join(arena, &.{ xdg, appname });
        }
        const home = getenv("HOME") orelse return error.AppDataDirUnavailable;
        return std.fs.path.join(arena, &.{ home, ".local", "share", appname });
    }
}

fn get_install_dir(io: Io, environ: std.process.Environ, arena: std.mem.Allocator, meta: *const MetaStruct) ![]u8 {
    const base_install_path = try get_base_install_dir(io, environ, arena);

    const dir_name = try std.fmt.allocPrint(
        arena,
        "{s}_erts-{s}_{s}",
        .{ build_options.RELEASE_NAME, meta.erts_version, meta.app_version },
    );

    Io.Dir.cwd().createDirPath(io, base_install_path) catch {
        install_dir_error(arena);
        return "";
    };

    const name = std.fs.path.join(arena, &.{ base_install_path, dir_name }) catch {
        install_dir_error(arena);
        return "";
    };

    return name;
}

fn install_dir_error(arena: std.mem.Allocator) void {
    const upper_name = std.ascii.allocUpperString(arena, build_options.RELEASE_NAME) catch {
        return;
    };
    const env_install_dir_name = std.fmt.allocPrint(arena, "{s}_INSTALL_DIR", .{upper_name}) catch {
        return;
    };

    logger.err("We could not install this application to the default directory.", .{});
    logger.err("This may be due to a permission error.", .{});
    logger.err("Please override the default {s} install directory using the `{s}` environment variable.", .{ build_options.RELEASE_NAME, env_install_dir_name });
    logger.err("On Linux or MacOS you can run the command: `export {s}=/some/other/path`", .{env_install_dir_name});
    logger.err("On Windows you can use: `SET {s}=D:\\some\\other\\path`", .{env_install_dir_name});
    std.process.exit(1);
}

fn maybe_install_musl_runtime(io: Io, arena: std.mem.Allocator) !void {
    if (comptime IS_LINUX and !std.mem.eql(u8, build_options.MUSL_RUNTIME_PATH, "")) {
        const cStr = try arena.dupeZ(u8, build_options.MUSL_RUNTIME_PATH);
        var statBuffer: std.c.Stat = undefined;
        const statResult = std.c.stat(cStr, &statBuffer);

        if (statResult == 0) {
            log.debug("The musl runtime file is already preset. Continuing.", .{});
            return;
        }

        const file = Io.Dir.cwd().createFile(io, build_options.MUSL_RUNTIME_PATH, .{ .read = true }) catch |e| {
            log.debug("Failed to extract burrito musl runtime: {}", .{e});
            return;
        };
        defer file.close(io);

        const exec_permissions = Io.File.Permissions.unixNew(0o754);
        try file.setPermissions(io, exec_permissions);

        const MUSL_RUNTIME_BYTES = @embedFile("musl-runtime.so");
        try file.writePositionalAll(io, MUSL_RUNTIME_BYTES, 0);

        log.debug("Wrote musl runtime file: {s}", .{build_options.MUSL_RUNTIME_PATH});
    }
}
