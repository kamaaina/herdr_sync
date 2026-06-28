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

pub fn main(init: std.process.Init) !u8 {
    //const arena: std.mem.Allocator = init.arena.allocator();

    //const args = try init.minimal.args.toSlice(arena);
    //if (args.len != 3) {
    //    std.debug.print("usage: {s} <bird> <beams>\n", .{args[0]});
    //    return 1;
    //}
    //for (args) |arg| {
    //    std.log.debug("arg: {s}", .{arg});
    //}

    const io = init.io;
    const allocator = init.gpa;

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
    std.debug.print("# tabs: {d}\n", .{tabs.len});

    var selected_tab: usize = 0;
    for (tabs, 0..) |tab, i| {
        if (tab.focused) {
            selected_tab = i;
            break;
        }
    }
    std.debug.print("tab index: {d}\n", .{selected_tab});

    // get list of non-focused panes

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
    std.debug.print("# panes: {d}\n", .{panes.len});

    for (panes) |pane| {
        if (pane.focused) {
            // TODO: get the last line of the pane as this is what we need to send to others

            // send "enter" to current selected pane to issue command
            var cmd: std.ArrayList([]const u8) = .empty;
            defer cmd.deinit(allocator);

            try cmd.append(allocator, "herdr");
            try cmd.append(allocator, "pane");
            try cmd.append(allocator, "run");
            try cmd.append(allocator, "\"\"");

            continue;
        }
        if (!std.mem.eql(u8, pane.tab_id, tabs[selected_tab].tab_id)) {
            continue;
        }

        var txt_cmd: std.ArrayList([]const u8) = .empty;
        defer txt_cmd.deinit(allocator);
        std.debug.print("herdr pane send-text {s} {s}\n", .{ pane.pane_id, "ls" });
        try txt_cmd.append(allocator, "herdr");
        try txt_cmd.append(allocator, "pane");
        try txt_cmd.append(allocator, "send-text");
        try txt_cmd.append(allocator, "ls"); // FIXME: testing

        var run_cmd: std.ArrayList([]const u8) = .empty;
        defer run_cmd.deinit(allocator);
        std.debug.print("herdr pane run {s}\n", .{""});
        try run_cmd.append(allocator, "herdr");
        try run_cmd.append(allocator, "pane");
        try run_cmd.append(allocator, "run");
        try run_cmd.append(allocator, "\"\"");
    }

    return 0;
}
