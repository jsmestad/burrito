const std = @import("std");
const Io = std.Io;

const logger = @import("logger.zig");
const metadata = @import("metadata.zig");
const install = @import("install.zig");
const wrapper = @import("wrapper.zig");

const MetaStruct = metadata.MetaStruct;

pub fn do_maint(io: Io, args: []const []const u8, install_dir: []const u8) !void {
    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 1) {
        logger.warn("No sub-command provided!", .{});
    } else {
        if (std.mem.eql(u8, args[0], "uninstall")) {
            try do_uninstall(io, install_dir);
        }

        if (std.mem.eql(u8, args[0], "directory")) {
            try print_install_dir(stdout, install_dir);
        }

        if (std.mem.eql(u8, args[0], "meta")) {
            try print_metadata(stdout);
        }
    }
}

fn confirm() !bool {
    var stdin_buf: [8]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(std.Options.debug_io, &stdin_buf);
    var stdin = &stdin_reader.interface;

    logger.query("Please confirm this action [y/n]: ", .{});

    if (stdin.takeDelimiterExclusive('\n')) |user_input| {
        if (std.mem.eql(u8, user_input[0..1], "y") or std.mem.eql(u8, user_input[0..1], "Y")) {
            return true;
        }
    } else |err_val| {
        logger.err("Failed to confirm: {t}", .{err_val});
        return err_val;
    }

    return false;
}

fn do_uninstall(io: Io, install_dir: []const u8) !void {
    logger.warn("This will uninstall the application runtime for this Burrito binary!", .{});
    if (try confirm() == false) {
        logger.warn("Uninstall was aborted!", .{});
        logger.info("Quitting.", .{});
        return;
    }

    logger.info("Deleting directory: {s}", .{install_dir});
    try Io.Dir.cwd().deleteTree(io, install_dir);
    logger.info("Uninstall complete!", .{});
    logger.info("Quitting.", .{});
}

fn print_metadata(out: *Io.Writer) !void {
    try out.print("{s}", .{wrapper.RELEASE_METADATA_JSON});
    try out.flush();
}

fn print_install_dir(out: *Io.Writer, install_dir: []const u8) !void {
    try out.print("{s}\n", .{install_dir});
    try out.flush();
}

pub fn do_clean_old_versions(io: Io, install_prefix_path: []const u8, current_install_path: []const u8) !void {
    std.log.debug("Going to clean up older versions of this application...", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prefix_dir = try Io.Dir.openDirAbsolute(io, install_prefix_path, .{ .access_sub_paths = true, .iterate = true });

    const current_install = try install.load_install_from_path(io, allocator, current_install_path);

    var itr = prefix_dir.iterate();
    while (try itr.next(io)) |dir| {
        if (dir.kind == .directory) {
            const possible_app_path = try std.fs.path.join(allocator, &[_][]const u8{ install_prefix_path, dir.name });
            const other_install = try install.load_install_from_path(io, allocator, possible_app_path);

            if (other_install == null) {
                continue;
            }

            if (!std.mem.eql(u8, current_install.?.metadata.app_name, other_install.?.metadata.app_name)) {
                continue;
            }

            if (std.SemanticVersion.order(current_install.?.version, other_install.?.version) == .gt) {
                try Io.Dir.cwd().deleteTree(io, other_install.?.install_dir_path);
                logger.log_stderr("Uninstalled older version (v{s})", .{other_install.?.metadata.app_version});
            }
        }
    }
}
