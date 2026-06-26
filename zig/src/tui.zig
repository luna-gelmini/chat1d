const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const vaxis = @import("vaxis");
const events = @import("events");
const transcript_mod = @import("transcript");
const sidebar = @import("sidebar");
const layout = @import("layout");
const focus = @import("focus");
const members = @import("members");

/// Non-blocking socket line reader for the main loop (avoids Io mutex contention with vaxis tty).
pub const NetPump = struct {
    stream: Io.net.Stream,
    carry: std.ArrayList(u8) = .empty,
    closed: bool = false,

    pub fn deinit(self: *NetPump, gpa: std.mem.Allocator) void {
        self.carry.deinit(gpa);
    }

    fn takeLine(self: *NetPump, gpa: std.mem.Allocator) !?[]u8 {
        if (std.mem.indexOfScalar(u8, self.carry.items, '\n')) |nl| {
            const raw = std.mem.trim(u8, self.carry.items[0..nl], "\r");
            const line = try gpa.dupe(u8, raw);
            try self.carry.replaceRange(gpa, 0, nl + 1, &.{});
            if (line.len == 0) return try self.takeLine(gpa);
            return line;
        }
        return null;
    }

    /// Returns one complete line per call, or null if none ready.
    pub fn pollLine(self: *NetPump, gpa: std.mem.Allocator) !?[]u8 {
        if (self.closed) return null;
        if (try self.takeLine(gpa)) |ln| return ln;

        var fds = [_]posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if ((posix.poll(fds[0..], 0) catch 0) == 0) return null;

        var buf: [4096]u8 = undefined;
        const n = posix.read(self.stream.socket.handle, &buf) catch {
            self.closed = true;
            return null;
        };
        if (n == 0) {
            self.closed = true;
            return null;
        }
        try self.carry.appendSlice(gpa, buf[0..n]);
        return try self.takeLine(gpa);
    }
};

pub fn visibleTranscriptLine(line: transcript_mod.TranscriptLine, current_room: ?[]const u8) bool {
    return switch (line) {
        .global => true,
        .room => |m| if (current_room) |cr| sidebar.RoomSidebarState.namesEqual(m.room, cr) else false,
        .attach => |a| if (current_room) |cr| sidebar.RoomSidebarState.namesEqual(a.room, cr) else false,
    };
}

pub fn visibleTranscriptRows(tr: *const std.ArrayList(transcript_mod.TranscriptLine), current_room: ?[]const u8) usize {
    var n: usize = 0;
    for (tr.items) |e| {
        if (visibleTranscriptLine(e, current_room)) n += transcript_mod.transcriptDisplayRows(e);
    }
    return n;
}

pub fn stickTranscriptSkip(tr: *const std.ArrayList(transcript_mod.TranscriptLine), current_room: ?[]const u8, inner_h: usize) usize {
    const total = visibleTranscriptRows(tr, current_room);
    return if (total > inner_h) total - inner_h else 0;
}

fn border(active: bool) vaxis.Cell.Style {
    return .{ .fg = if (active) .{ .index = 15 } else .{ .index = 8 } };
}

fn printRow(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Cell.Style) void {
    const seg = [_]vaxis.Segment{.{ .text = text, .style = style }};
    _ = win.print(&seg, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
}

pub fn redrawHarness(
    vx: *vaxis.Vaxis,
    transcript: *const std.ArrayList(transcript_mod.TranscriptLine),
    sidebar_st: *const sidebar.RoomSidebarState,
    member_list: *const std.ArrayList(members.Member),
    channel_sel: usize,
    member_sel: usize,
    ui_focus: focus.Focus,
    lay: layout.Layout,
    text_input: *vaxis.widgets.TextInput,
    host: []const u8,
    port: u16,
    display_nick: []const u8,
    current_room: ?[]const u8,
    transcript_skip: usize,
    connected: bool,
    cmd_mode: bool,
) void {
    const win = vx.window();
    win.clear();
    const room_disp = current_room orelse "-";
    var title: [128]u8 = undefined;
    const conn = if (connected) "●" else "○";
    const t = std.fmt.bufPrint(title[0..], "chat1d · {s} · #{s} · {s} connected", .{ display_nick, room_disp, conn }) catch "?";
    _ = win.print(&.{.{ .text = t, .style = .{ .fg = .{ .index = 6 } } } }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    if (lay.show_servers) {
        const sw = win.child(.{ .x_off = lay.servers.x, .y_off = lay.servers.y, .width = lay.servers.w, .height = lay.servers.h, .border = .{ .where = .all, .style = border(ui_focus == .servers), .glyphs = .single_rounded } });
        printRow(sw, 0, "SRV", .{ .fg = .{ .index = 8 } });
        var hb: [32]u8 = undefined;
        const hline = std.fmt.bufPrint(hb[0..], "{s}:{d}", .{ host, port }) catch "?";
        printRow(sw, 1, hline, .{ .fg = .{ .index = 7 } });
    }

    if (lay.show_rooms) {
        const rw = win.child(.{ .x_off = lay.rooms.x, .y_off = lay.rooms.y, .width = lay.rooms.w, .height = lay.rooms.h, .border = .{ .where = .all, .style = border(ui_focus == .rooms), .glyphs = .single_rounded } });
        printRow(rw, 0, "ROOMS", .{ .fg = .{ .index = 8 } });
        var row: u16 = 1;
        for (sidebar_st.channels.items, 0..) |ch, i| {
            if (row + 1 >= rw.height) break;
            var lb: [96]u8 = undefined;
            const mark: []const u8 = if (current_room) |cr| if (sidebar.RoomSidebarState.namesEqual(cr, ch.name)) ">" else " " else " ";
            const label = std.fmt.bufPrint(lb[0..], "{s}{s}{s}", .{ mark, if (ch.subscribed) "#" else "·", ch.name }) catch continue;
            const hi = (i == channel_sel) and ui_focus == .rooms;
            printRow(rw, row, label, .{ .fg = if (hi) .{ .index = 11 } else .{ .index = 7 } });
            row += 1;
        }
    }

    if (lay.show_members) {
        const mw = win.child(.{ .x_off = lay.members.x, .y_off = lay.members.y, .width = lay.members.w, .height = lay.members.h, .border = .{ .where = .all, .style = border(ui_focus == .members), .glyphs = .single_rounded } });
        printRow(mw, 0, "MEMBERS", .{ .fg = .{ .index = 8 } });
        var row: u16 = 1;
        for (member_list.items, 0..) |m, i| {
            if (row >= mw.height) break;
            var lb: [64]u8 = undefined;
            const dot: []const u8 = if (m.online) "●" else "○";
            const label = std.fmt.bufPrint(lb[0..], "{s} {s}", .{ dot, m.name }) catch continue;
            const hi = (i == member_sel) and ui_focus == .members;
            printRow(mw, row, label, .{ .fg = if (hi) .{ .index = 11 } else .{ .index = 7 } });
            row += 1;
        }
    }

    const tw = win.child(.{ .x_off = lay.transcript.x, .y_off = lay.transcript.y, .width = lay.transcript.w, .height = lay.transcript.h, .border = .{ .where = .all, .style = border(ui_focus == .transcript), .glyphs = .single_rounded } });
    const inner_h = if (tw.height > 1) tw.height - 1 else 1;
    var visible_total: usize = 0;
    for (transcript.items) |e| {
        if (visibleTranscriptLine(e, current_room)) visible_total += transcript_mod.transcriptDisplayRows(e);
    }
    const skip = @min(transcript_skip, if (visible_total > inner_h) visible_total - inner_h else 0);
    var passed: usize = 0;
    var dr: u16 = 0;
    var line_buf: [4096]u8 = undefined;
    for (transcript.items) |*e| {
        if (!visibleTranscriptLine(e.*, current_room)) continue;
        const rows = transcript_mod.transcriptDisplayRows(e.*);
        if (passed + rows <= skip) {
            passed += rows;
            continue;
        }
        const txt: []const u8 = switch (e.*) {
            .global => |g| g.text,
            .room => |m| std.fmt.bufPrint(line_buf[0..], "<{s}> {s}", .{ m.nick, m.body }) catch "?",
            .attach => |a| a.caption,
        };
        _ = tw.print(&.{.{ .text = txt }}, .{ .row_offset = dr, .col_offset = 1, .wrap = .none });
        dr +|= 1;
        if (e.* == .attach) {
            if (transcript_mod.attachPreviewImage(e.attach.preview_id, e.attach.preview_w, e.attach.preview_h)) |img| {
                const img_h: u16 = if (e.attach.preview_rows > 0) e.attach.preview_rows else 8;
                if (dr + img_h <= inner_h) {
                    const iwin = tw.child(.{ .x_off = 1, .y_off = dr, .width = if (tw.width > 2) tw.width - 2 else 1, .height = img_h });
                    img.draw(iwin, .{ .scale = .contain }) catch {};
                    dr +|= img_h;
                }
            }
        }
        passed += rows;
        if (dr >= inner_h) break;
    }

    const iw = win.child(.{ .x_off = lay.input.x, .y_off = lay.input.y, .width = lay.input.w, .height = lay.input.h });
    drawInputLine(iw, text_input, cmd_mode, room_disp);

    const leg = "Ctrl+w panes · j/k · Ctrl+v · :cmd · ^C quit";
    _ = win.print(&.{.{ .text = leg, .style = .{ .fg = .{ .index = 8 } } } }, .{ .row_offset = lay.footer.y, .col_offset = 0, .wrap = .none });
}

pub fn transcriptInnerRows(lay: layout.Layout) usize {
    const h = lay.transcript.h;
    return if (h > 2) @as(usize, h - 2) else 1;
}

fn drawInputLine(
    iw: vaxis.Window,
    text_input: *vaxis.widgets.TextInput,
    cmd_mode: bool,
    room_disp: []const u8,
) void {
    var prompt: [80]u8 = undefined;
    const pfx = std.fmt.bufPrint(prompt[0..], ">{s} #{s} ", .{ if (cmd_mode) ":" else " ", room_disp }) catch ">";
    printRow(iw, 0, pfx, .{ .fg = .{ .index = 8 } });
    const off: u16 = @intCast(@min(pfx.len, iw.width -| 2));
    const tin = iw.child(.{
        .x_off = off,
        .y_off = 0,
        .width = if (iw.width > off) iw.width - off else 1,
        .height = 1,
    });
    text_input.drawWithStyle(tin, .{ .fg = .{ .index = 15 } });
}

fn isSafeText(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| {
        if (c == 0x1b) return false;
        if (c < 32 and c != '\t') return false;
    }
    return true;
}

pub fn keyHasPrintableChar(key: vaxis.Key) bool {
    if (key.text) |t| return isSafeText(t);
    if (key.isModifier() or key.mods.ctrl) return false;
    const cp = key.codepoint;
    return cp >= 32 and cp <= 126;
}

/// TextInput ignores keys without `text`; VS Code/legacy send codepoint-only presses.
pub fn applyTextInputKey(text_input: *vaxis.widgets.TextInput, key: vaxis.Key) !void {
    if (key.text) |t| {
        if (!isSafeText(t)) return;
        try text_input.update(.{ .key_press = key });
        return;
    }
    if (key.isModifier()) return;
    if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{}) or
        key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.right, .{}) or
        key.matches(vaxis.Key.home, .{}) or key.matches(vaxis.Key.end, .{}) or
        key.mods.ctrl or key.mods.alt)
    {
        try text_input.update(.{ .key_press = key });
        return;
    }
    const cp = key.codepoint;
    if (cp < 32 or cp > 126) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    try text_input.insertSliceAtCursor(buf[0..len]);
}
