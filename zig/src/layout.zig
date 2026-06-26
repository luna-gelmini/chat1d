pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.x and col < self.x + self.w and row >= self.y and row < self.y + self.h;
    }
};

pub const Layout = struct {
    title: Rect,
    menu: Rect,
    servers: Rect,
    rooms: Rect,
    transcript: Rect,
    members: Rect,
    input: Rect,
    footer: Rect,
    show_servers: bool,
    show_rooms: bool,
    show_members: bool,
    members_forced: bool,

    pub fn compute(w: u16, h: u16, members_forced: bool) Layout {
        const show_members = members_forced or w >= 100;
        const show_servers = w >= 80;
        const show_rooms = w >= 60;
        const srv_w: u16 = if (show_servers) @min(8, w / 12) else 0;
        const mem_w: u16 = if (show_members) @min(28, w / 4) else 0;
        const room_w: u16 = if (show_rooms) @min(32, @max(18, (w -| srv_w -| mem_w) / 3)) else 0;
        const body_y: u16 = 1;
        const foot_h: u16 = 1;
        const input_h: u16 = 1;
        const body_h = if (h > body_y + foot_h + input_h) h - body_y - foot_h - input_h else 1;
        const main_x = srv_w;
        const main_w = if (w > srv_w + room_w + mem_w) w - srv_w - room_w - mem_w else 1;
        const tx_w = if (main_w > 1) main_w else 1;
        return .{
            .title = .{ .x = 0, .y = 0, .w = w, .h = 1 },
            .menu = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .servers = .{ .x = 0, .y = body_y, .w = srv_w, .h = body_h },
            .rooms = .{ .x = srv_w, .y = body_y, .w = room_w, .h = body_h },
            .transcript = .{ .x = main_x + room_w, .y = body_y, .w = tx_w, .h = body_h },
            .members = .{ .x = w -| mem_w, .y = body_y, .w = mem_w, .h = body_h },
            .input = .{ .x = main_x + room_w, .y = h -| foot_h - input_h, .w = tx_w, .h = input_h },
            .footer = .{ .x = 0, .y = h -| foot_h, .w = w, .h = foot_h },
            .show_servers = show_servers,
            .show_rooms = show_rooms,
            .show_members = show_members,
            .members_forced = members_forced,
        };
    }

    /// Win98-style GUI: title + menu + tabs + status bar.
    pub fn computeGui(w: u16, h: u16, members_forced: bool) Layout {
        const title_h: u16 = 1;
        const menu_h: u16 = 1;
        const status_h: u16 = 1;
        const body_y = title_h + menu_h;
        const body_h = if (h > body_y + status_h) h - body_y - status_h else 1;
        const show_members = members_forced or w >= 90;
        const srv_w: u16 = if (w >= 70) 5 else 0;
        const mem_w: u16 = if (show_members) @min(24, w / 5) else 0;
        const tab_h: u16 = 1;
        const input_h: u16 = 2;
        const main_x = srv_w;
        const main_w = if (w > srv_w + mem_w) w - srv_w - mem_w else 1;
        const tx_y = body_y + tab_h;
        const tx_h = if (body_h > tab_h + input_h) body_h - tab_h - input_h else 1;
        return .{
            .title = .{ .x = 0, .y = 0, .w = w, .h = title_h },
            .menu = .{ .x = 0, .y = title_h, .w = w, .h = menu_h },
            .servers = .{ .x = 0, .y = body_y, .w = srv_w, .h = body_h },
            .rooms = .{ .x = main_x, .y = body_y, .w = main_w, .h = tab_h },
            .transcript = .{ .x = main_x, .y = tx_y, .w = main_w, .h = tx_h },
            .members = .{ .x = w -| mem_w, .y = body_y, .w = mem_w, .h = body_h },
            .input = .{ .x = main_x, .y = tx_y + tx_h, .w = main_w, .h = input_h },
            .footer = .{ .x = 0, .y = h -| status_h, .w = w, .h = status_h },
            .show_servers = srv_w > 0,
            .show_rooms = true,
            .show_members = show_members,
            .members_forced = members_forced,
        };
    }

    pub fn paneAt(self: Layout, col: u16, row: u16) ?Pane {
        if (self.servers.w > 0 and self.servers.contains(col, row)) return .servers;
        if (self.rooms.w > 0 and self.rooms.contains(col, row)) return .rooms;
        if (self.members.w > 0 and self.members.contains(col, row)) return .members;
        if (self.transcript.contains(col, row)) return .transcript;
        if (self.input.contains(col, row)) return .input;
        return null;
    }

    pub fn tabIndexAt(self: Layout, col: u16, channel_count: usize, tab_cols: []const u16) ?usize {
        if (!self.rooms.contains(col, self.rooms.y)) return null;
        const rel = col -| self.rooms.x;
        var acc: u16 = 0;
        for (0..channel_count) |i| {
            const w = if (i < tab_cols.len) tab_cols[i] else 10;
            if (rel < acc + w) return i;
            acc += w;
        }
        return null;
    }
};

pub const Pane = enum { input, servers, rooms, transcript, members };
