const std = @import("std");

const TabResponse = struct {
    result: Result,
};

const Result = struct {
    tabs: []Tab,
};

const Tab = struct {
    focused: bool,
    label: []const u8,
    number: u8,
    pane_count: u8,
    tab_id: []const u8,
    workspace_id: []const u8,
};

const PaneResponse = struct {
    result: PaneResult,
};

const PaneResult = struct {
    panes: []Pane,
};

const Pane = struct {
    focused: bool,
    pane_id: []const u8,
    tab_id: []const u8,
};

pub const Config: type = struct {
    terminal_prompt: []const u8,
};

pub fn load_config(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Config {
    const contents = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
        .of(u8),
        0, // sentinel
    );
    defer allocator.free(contents);

    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);

    return try std.zon.parse.fromSliceAlloc(
        Config,
        allocator,
        contents,
        &diagnostics,
        .{ .free_on_error = true },
    );
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.gpa;

    // get the plugin configuration
    var cfg_argv = [_][]const u8{
        "herdr",
        "plugin",
        "config-dir",
        "sync-plugin",
    };

    const cfg_result = try std.process.run(allocator, io, .{
        .argv = &cfg_argv,
    });
    defer allocator.free(cfg_result.stdout);
    defer allocator.free(cfg_result.stderr);
    const trimmed_dir = std.mem.trimEnd(u8, cfg_result.stdout, "\n");
    std.log.debug("config dir: {s}", .{trimmed_dir});
    const cfg_file = try std.mem.concat(allocator, u8, &[_][]const u8{ trimmed_dir, "/herdr_sync.zon" });
    std.log.debug("config file: {s}", .{cfg_file});
    defer allocator.free(cfg_file);
    const config: Config = try load_config(io, allocator, cfg_file);
    defer std.zon.parse.free(allocator, config);
    std.log.debug("config - terminal_prompt: {s}", .{config.terminal_prompt});

    // find the active tab
    var argv = [_][]const u8{
        "herdr",
        "tab",
        "list",
    };

    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.exited != 0) {
        std.debug.print("Command failed with error output:\n{s}\n", .{result.stderr});
        return error.CommandFailed;
    }

    const response = try std.json.parseFromSlice(TabResponse, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer response.deinit();

    const tabs: []Tab = response.value.result.tabs;

    var selected_tab: usize = 0;
    for (tabs, 0..) |tab, i| {
        if (tab.focused) {
            selected_tab = i;
            break;
        }
    }

    // get panes in the tab
    argv = [_][]const u8{
        "herdr",
        "pane",
        "list",
    };

    const pane_result = try std.process.run(allocator, io, .{
        .argv = &argv,
    });
    defer allocator.free(pane_result.stdout);
    defer allocator.free(pane_result.stderr);

    if (pane_result.term.exited != 0) {
        std.debug.print("Command failed with error output:\n{s}\n", .{pane_result.stderr});
        return error.CommandFailed;
    }

    const pane_response = try std.json.parseFromSlice(PaneResponse, allocator, pane_result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer pane_response.deinit();

    const panes: []Pane = pane_response.value.result.panes;

    var txt_to_send: []const u8 = "";
    for (panes) |pane| {
        if (pane.focused) {
            // get the last line of the pane as this is what we need to send to others
            // not sure this is the best way as shells have different propmts and users
            // are able to customize it. also, what happens if the command spans multiple
            // lines?
            var get_txt_cmd: std.ArrayList([]const u8) = .empty;
            defer get_txt_cmd.deinit(allocator);
            try get_txt_cmd.append(allocator, "herdr");
            try get_txt_cmd.append(allocator, "pane");
            try get_txt_cmd.append(allocator, "read");
            try get_txt_cmd.append(allocator, pane.pane_id);
            try get_txt_cmd.append(allocator, "--lines");
            try get_txt_cmd.append(allocator, "1");

            const get_cmd_result = try std.process.run(allocator, io, .{
                .argv = get_txt_cmd.items,
            });
            defer allocator.free(get_cmd_result.stdout);
            defer allocator.free(get_cmd_result.stderr);

            // TODO: make the delimiter a configuration option
            const delimiter = config.terminal_prompt;

            // find the starting index of the delimiter
            std.debug.print("!@read@! '{s}'\n", .{get_cmd_result.stdout});
            var command_start: usize = 0;
            if (std.mem.indexOf(u8, get_cmd_result.stdout, delimiter)) |index| {
                command_start = index + delimiter.len; // starting position of the actual command
                txt_to_send = try allocator.dupe(u8, get_cmd_result.stdout[command_start..]);
                std.debug.print("txt_to_send: {s}\n", .{txt_to_send});
            } else {
                // TODO: use framework to send a notification back
                std.debug.print("delimiter not found.\n", .{});
            }

            // send "enter" to current selected pane to issue command
            var cmd: std.ArrayList([]const u8) = .empty;
            defer cmd.deinit(allocator);

            try cmd.append(allocator, "herdr");
            try cmd.append(allocator, "pane");
            try cmd.append(allocator, "send-text");
            try cmd.append(allocator, pane.pane_id);
            try cmd.append(allocator, "\n");

            const cmd_result = try std.process.run(allocator, io, .{
                .argv = cmd.items,
            });
            defer allocator.free(cmd_result.stdout);
            defer allocator.free(cmd_result.stderr);

            continue;
        }
        if (!std.mem.eql(u8, pane.tab_id, tabs[selected_tab].tab_id)) {
            continue;
        }

        var txt_cmd: std.ArrayList([]const u8) = .empty;
        defer txt_cmd.deinit(allocator);
        try txt_cmd.append(allocator, "herdr");
        try txt_cmd.append(allocator, "pane");
        try txt_cmd.append(allocator, "send-text");
        try txt_cmd.append(allocator, pane.pane_id);
        try txt_cmd.append(allocator, txt_to_send);

        const txt_cmd_result = try std.process.run(allocator, io, .{
            .argv = txt_cmd.items,
        });
        defer allocator.free(txt_cmd_result.stdout);
        defer allocator.free(txt_cmd_result.stderr);

        if (txt_cmd_result.term.exited != 0) {
            std.debug.print("send-text command failed with error output:\n{s}\n", .{txt_cmd_result.stderr});
            return error.CommandFailed;
        }
    }

    return 0;
}
