const rl = @import("raylib");

pub const Action = enum {
    none,
    win_minimize,
    win_maximize,
    win_close,
    tool_server,
    tool_logs,
    tool_settings,
    menu_file,
    menu_edit,
    menu_view,
    menu_tools,
    menu_help,
};

pub const Zones = struct {
    close: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    min: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    max: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tool_server: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tool_logs: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tool_settings: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_file: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_edit: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_view: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_tools: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_help: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    fn hitRect(p: rl.Vector2, r: rl.Rectangle) bool {
        return r.width > 0 and rl.checkCollisionPointRec(p, r);
    }

    pub fn pick(self: *const Zones, mx: i32, my: i32) Action {
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        if (hitRect(p, self.close)) return .win_close;
        if (hitRect(p, self.min)) return .win_minimize;
        if (hitRect(p, self.max)) return .win_maximize;
        if (hitRect(p, self.tool_server)) return .tool_server;
        if (hitRect(p, self.tool_logs)) return .tool_logs;
        if (hitRect(p, self.tool_settings)) return .tool_settings;
        if (hitRect(p, self.menu_file)) return .menu_file;
        if (hitRect(p, self.menu_edit)) return .menu_edit;
        if (hitRect(p, self.menu_view)) return .menu_view;
        if (hitRect(p, self.menu_tools)) return .menu_tools;
        if (hitRect(p, self.menu_help)) return .menu_help;
        return .none;
    }
};
