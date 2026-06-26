const std = @import("std");
const rl = @import("raylib");
const win98 = @import("gui/win98");

/// Palette face for popup — matches Stitch surfaces in example_gui.html.
pub const Surface = enum {
    background,
    surface,
    surface_container,

    pub fn face(self: Surface) rl.Color {
        return switch (self) {
            .background => win98.C.background,
            .surface => win98.C.surface,
            .surface_container => win98.C.surface_container,
        };
    }
};

pub const Kind = enum {
    transcript,
    member,
    tab,
    file,
    edit,
    view,
    tools,
    help,
};

pub const Pick = enum {
    none,
    outside,
    reply,
    copy,
    delete,
    mention,
    part,
    quit,
    clear_input,
    paste_input,
    toggle_members,
    scroll_top,
    refresh_rooms,
    join_channel,
    show_help,
    about,
};

const max_items: usize = 8;
const sep: []const u8 = "---";

fn labelZ(label: []const u8, buf: *[48]u8) [:0]const u8 {
    const n = @min(label.len, buf.len - 1);
    @memcpy(buf[0..n], label[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

pub const State = struct {
    open: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    surface: Surface = .surface_container,
    kind: Kind = .transcript,
    target_idx: usize = 0,
    viewport: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    labels: [max_items][]const u8 = .{""} ** max_items,
    picks: [max_items]Pick = .{.none} ** max_items,
    count: u8 = 0,
    rects: [max_items]rl.Rectangle = [_]rl.Rectangle{.{ .x = 0, .y = 0, .width = 0, .height = 0 }} ** max_items,
    menu_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    layout_w: f32 = 0,
    layout_h: f32 = 0,

    fn push(self: *State, label: []const u8, action: Pick) void {
        if (self.count >= max_items) return;
        self.labels[self.count] = label;
        self.picks[self.count] = action;
        self.count += 1;
    }

    fn loadItems(self: *State, kind: Kind) void {
        self.count = 0;
        switch (kind) {
            .transcript => {
                self.push("Reply", .reply);
                self.push("Copy", .copy);
                self.push(sep, .none);
                self.push("Remove locally", .delete);
            },
            .member => {
                self.push("Mention", .mention);
                self.push("Copy name", .copy);
            },
            .tab => self.push("Part channel", .part),
            .file => self.push("Quit", .quit),
            .edit => {
                self.push("Clear input", .clear_input);
                self.push(sep, .none);
                self.push("Paste", .paste_input);
            },
            .view => {
                self.push("Toggle members", .toggle_members);
                self.push("Scroll to top", .scroll_top);
            },
            .tools => {
                self.push("Refresh rooms", .refresh_rooms);
                self.push(sep, .none);
                self.push("Join channel...", .join_channel);
            },
            .help => {
                self.push("Commands", .show_help);
                self.push(sep, .none);
                self.push("About", .about);
            },
        }
    }

    pub fn openPopup(
        self: *State,
        x: f32,
        y: f32,
        surface: Surface,
        kind: Kind,
        target_idx: usize,
        viewport: rl.Rectangle,
    ) void {
        self.* = .{};
        self.open = true;
        self.x = x;
        self.y = y;
        self.surface = surface;
        self.kind = kind;
        self.target_idx = target_idx;
        self.viewport = viewport;
        self.loadItems(kind);
    }

    pub fn openDropdown(
        self: *State,
        anchor: rl.Rectangle,
        surface: Surface,
        kind: Kind,
        viewport: rl.Rectangle,
    ) void {
        self.openPopup(anchor.x, anchor.y + anchor.height, surface, kind, 0, viewport);
    }

    pub fn openTranscript(self: *State, x: f32, y: f32, line_idx: usize, viewport: rl.Rectangle) void {
        self.openPopup(x, y, .background, .transcript, line_idx, viewport);
    }

    pub fn openMember(self: *State, x: f32, y: f32, member_idx: usize, viewport: rl.Rectangle) void {
        self.openPopup(x, y, .surface, .member, member_idx, viewport);
    }

    pub fn openTab(self: *State, x: f32, y: f32, tab_idx: usize, viewport: rl.Rectangle) void {
        self.openPopup(x, y, .surface_container, .tab, tab_idx, viewport);
    }

    pub fn openMenubar(self: *State, anchor: rl.Rectangle, kind: Kind, viewport: rl.Rectangle) void {
        self.openDropdown(anchor, .surface_container, kind, viewport);
    }

    pub fn toggleMenubar(self: *State, anchor: rl.Rectangle, kind: Kind, viewport: rl.Rectangle) bool {
        if (self.open and self.kind == kind) {
            self.close();
            return false;
        }
        self.openMenubar(anchor, kind, viewport);
        return true;
    }

    pub fn close(self: *State) void {
        self.open = false;
    }

    fn measure(self: *State, font: rl.Font, font_size: f32) struct { w: f32, h: f32 } {
        const pad_x: f32 = 12;
        const row_h: f32 = font_size + 6;
        var w: f32 = 120;
        var z: [48]u8 = [_]u8{0} ** 48;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.labels[i], sep)) continue;
            const tw = rl.measureTextEx(font, labelZ(self.labels[i], &z), font_size, 1).x + pad_x * 2;
            w = @max(w, tw);
        }
        const h = row_h * @as(f32, @floatFromInt(self.count));
        return .{ .w = w, .h = h };
    }

    fn clampOrigin(self: *State, w: f32, h: f32) void {
        const vp = self.viewport;
        if (vp.width <= 0 or vp.height <= 0) return;
        var x = self.x;
        var y = self.y;
        if (x + w > vp.x + vp.width) x = vp.x + vp.width - w;
        if (y + h > vp.y + vp.height) y = vp.y + vp.height - h;
        if (x < vp.x) x = vp.x;
        if (y < vp.y) y = vp.y;
        self.x = x;
        self.y = y;
    }

    fn layout(self: *State, font: rl.Font, font_size: f32) void {
        const row_h: f32 = font_size + 6;
        const m = self.measure(font, font_size);
        self.layout_w = m.w;
        self.layout_h = m.h;
        self.clampOrigin(m.w, m.h);
        self.menu_rect = .{ .x = self.x, .y = self.y, .width = m.w, .height = m.h };
        var y = self.y;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            self.rects[i] = .{ .x = self.x, .y = y, .width = m.w, .height = row_h };
            y += row_h;
        }
    }

    pub fn draw(self: *State, font: rl.Font, font_size: f32, mx: i32, my: i32) void {
        if (!self.open) return;
        self.layout(font, font_size);
        const face = self.surface.face();
        win98.drawOutset(self.menu_rect, face);
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const r = self.rects[i];
            if (std.mem.eql(u8, self.labels[i], sep)) {
                const y = r.y + r.height * 0.5;
                rl.drawLine(@intFromFloat(r.x + 4), @intFromFloat(y), @intFromFloat(r.x + r.width - 4), @intFromFloat(y), win98.C.border_dark);
                continue;
            }
            const hover = rl.checkCollisionPointRec(p, r);
            const disabled = self.picks[i] == .none;
            if (hover and !disabled) {
                rl.drawRectangleRec(r, win98.C.primary);
            }
            var z: [48]u8 = [_]u8{0} ** 48;
            const label = self.labels[i];
            const n = @min(label.len, z.len - 1);
            @memcpy(z[0..n], label[0..n]);
            const col = if (disabled)
                win98.C.text_muted
            else if (hover)
                win98.C.text
            else
                win98.C.text_muted;
            rl.drawTextEx(font, z[0..n :0], .{ .x = r.x + 10, .y = r.y + 3 }, font_size, 1, col);
        }
    }

    pub fn pick(self: *const State, mx: i32, my: i32) Pick {
        if (!self.open) return .none;
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        if (!rl.checkCollisionPointRec(p, self.menu_rect)) return .outside;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.labels[i], sep)) continue;
            if (self.picks[i] == .none) continue;
            if (rl.checkCollisionPointRec(p, self.rects[i])) return self.picks[i];
        }
        return .outside;
    }
};
