const std = @import("std");
const rl = @import("raylib");
const layout = @import("layout");
const sidebar = @import("sidebar");
const members = @import("members");
const focus = @import("focus");
const transcript_mod = @import("transcript");
const tui = @import("tui");
const win98 = @import("gui/win98");
const chrome = @import("gui/chrome");
const util = @import("util");
const context_menu = @import("gui/context_menu");
const transcript_layout = @import("gui/transcript_layout");
const gui_input = @import("gui/input");

pub const ToolbarSel = enum { server, logs, settings };

fn clipCols(text: []const u8, max_cols: usize) []const u8 {
    if (text.len <= max_cols) return text;
    var end = max_cols;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

pub const LineSelection = struct { from: usize, to: usize };

pub const Painter = struct {
    font: rl.Font,
    ui_font: rl.Font,
    font_size: f32,
    ui_font_size: f32,
    cell_w: i32,
    cell_h: i32,
    tab_cols: [32]u16 = [_]u16{0} ** 32,
    tab_rects: [32]rl.Rectangle = [_]rl.Rectangle{.{ .x = 0, .y = 0, .width = 0, .height = 0 }} ** 32,
    tab_count: u8 = 0,
    tab_bar_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    servers_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    members_panel_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    input_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    transcript_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    members_list_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    members_visible: bool = false,
    scroll_track_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scroll_thumb_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scroll_max_skip: usize = 0,
    scroll_active: bool = false,
    chrome: chrome.Zones = .{},

    pub fn init(chat_font: rl.Font, ui_font: rl.Font, font_size: i32) Painter {
        const fs: f32 = @floatFromInt(font_size);
        const m = rl.measureTextEx(chat_font, "M", fs, 1);
        return .{
            .font = chat_font,
            .ui_font = ui_font,
            .font_size = fs,
            .ui_font_size = fs,
            .cell_w = @max(1, @as(i32, @intFromFloat(@ceil(m.x)))),
            .cell_h = @max(1, @as(i32, @intFromFloat(@ceil(m.y))) + 2),
        };
    }

    pub fn colsRows(self: Painter, win_w: i32, win_h: i32) struct { cols: u16, rows: u16 } {
        const cw = @max(1, @divFloor(win_w, self.cell_w));
        const ch = @max(1, @divFloor(win_h, self.cell_h));
        return .{ .cols = @intCast(cw), .rows = @intCast(ch) };
    }

    fn px(self: Painter, col: u16, row: u16) rl.Vector2 {
        return .{
            .x = @floatFromInt(@as(i32, col) * self.cell_w),
            .y = @floatFromInt(@as(i32, row) * self.cell_h),
        };
    }

    fn panelRect(self: Painter, r: layout.Rect) rl.Rectangle {
        const p = self.px(r.x, r.y);
        return .{
            .x = p.x,
            .y = p.y,
            .width = self.pxW(r.w),
            .height = self.pxH(r.h),
        };
    }

    fn pxW(self: Painter, cols: u16) f32 {
        return @as(f32, @floatFromInt(@as(i32, cols) * self.cell_w));
    }

    fn pxH(self: Painter, rows: u16) f32 {
        return @as(f32, @floatFromInt(@as(i32, rows) * self.cell_h));
    }

    fn pxWCols(self: Painter, cols: usize) f32 {
        return @as(f32, @floatFromInt(@as(i32, @intCast(cols)) * self.cell_w));
    }

    fn pxHi(self: Painter, rows: i32) f32 {
        return @as(f32, @floatFromInt(rows * self.cell_h));
    }

    fn innerCols(panel: layout.Rect) usize {
        return if (panel.w > 2) panel.w - 2 else 0;
    }

    fn inputLineRows(buf: []const u8) i32 {
        var n: i32 = 1;
        for (buf) |c| {
            if (c == '\n') n += 1;
        }
        return @min(n, 4);
    }

    fn drawMenuLabel(self: Painter, x: f32, y: f32, label: [:0]const u8, hot: u8, active: bool, hover: bool) void {
        const hi = active or hover;
        if (label.len == 0) return;
        const hot_l = std.ascii.toLower(hot);
        if (std.ascii.toLower(label[0]) == hot_l) {
            const ch: [2]u8 = .{ label[0], 0 };
            const tw = rl.measureTextEx(self.ui_font, ch[0..1 :0], self.ui_font_size, 1).x;
            self.drawUiTextSlice(x, y, label[0..1], if (hi) win98.C.text else win98.C.primary);
            self.drawUiTextSlice(x + tw, y, label[1..], if (hi) win98.C.text else win98.C.text_muted);
        } else {
            self.drawUiTextPx(x, y, label, if (hi) win98.C.text else win98.C.text_muted);
        }
    }

    fn drawUiTextSlice(self: Painter, x: f32, y: f32, text: []const u8, color: rl.Color) void {
        if (text.len == 0) return;
        var zbuf: [2048]u8 = [_]u8{0} ** 2048;
        const n = @min(text.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], text[0..n]);
        rl.drawTextEx(self.ui_font, zbuf[0..n :0], .{ .x = x, .y = y }, self.ui_font_size, 1, color);
    }

    fn drawUiTextPx(self: Painter, x: f32, y: f32, text: [:0]const u8, color: rl.Color) void {
        self.drawUiTextSlice(x, y, text, color);
    }

    fn fmtTime(ts: i64, buf: *[6]u8) []const u8 {
        if (ts <= 0) return "";
        const s = @mod(ts, 86_400);
        const h: u32 = @intCast(@divFloor(s, 3600));
        const m: u32 = @intCast(@divFloor(@mod(s, 3600), 60));
        const written = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ h, m }) catch return "";
        return written;
    }

    pub fn begin(_: Painter) void {
        rl.clearBackground(win98.C.background);
    }

    fn drawTextAt(self: Painter, col: u16, row: u16, text: []const u8, max_cols: usize, color: rl.Color) void {
        const clipped = clipCols(text, max_cols);
        var zbuf: [2048]u8 = [_]u8{0} ** 2048;
        const n = @min(clipped.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], clipped[0..n]);
        const p = self.px(col, row);
        rl.drawTextEx(self.font, zbuf[0..n :0], p, self.font_size, 1, color);
    }

    fn drawTextPx(self: Painter, x: f32, y: f32, text: [:0]const u8, color: rl.Color) void {
        self.drawTextSlice(x, y, text, color);
    }

    fn drawTextSlice(self: Painter, x: f32, y: f32, text: []const u8, color: rl.Color) void {
        if (text.len == 0) return;
        var zbuf: [2048]u8 = [_]u8{0} ** 2048;
        const n = @min(text.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], text[0..n]);
        rl.drawTextEx(self.font, zbuf[0..n :0], .{ .x = x, .y = y }, self.font_size, 1, color);
    }

    fn beginPanelClip(self: Painter, panel: layout.Rect) void {
        const pr = self.panelRect(panel);
        rl.beginScissorMode(@intFromFloat(pr.x), @intFromFloat(pr.y), @intFromFloat(pr.width), @intFromFloat(pr.height));
    }

    pub fn drawHarness(
        self: *Painter,
        lay: layout.Layout,
        ui_focus: focus.Focus,
        host: []const u8,
        port: u16,
        display_nick: []const u8,
        current_room: ?[]const u8,
        connected: bool,
        sidebar_st: *const sidebar.RoomSidebarState,
        member_list: *const std.ArrayList(members.Member),
        channel_sel: usize,
        member_sel: usize,
        transcript: *const std.ArrayList(transcript_mod.TranscriptLine),
        transcript_skip: usize,
        input_buf: []const u8,
        cmd_mode: bool,
        attach_tex: *const std.ArrayList(?rl.Texture2D),
        frame: u32,
        toolbar_sel: ToolbarSel,
        menu_open: ?context_menu.Kind,
        member_hover: ?usize,
        tab_hover: ?usize,
        mouse_x: i32,
        mouse_y: i32,
        selection: ?LineSelection,
        input_cursor: usize,
    ) void {
        self.tab_count = 0;
        self.scroll_active = false;
        self.scroll_max_skip = 0;
        @memset(&self.tab_rects, .{ .x = 0, .y = 0, .width = 0, .height = 0 });
        self.chrome = .{};
        const room_disp = current_room orelse "-";
        const win_r = self.panelRect(.{ .x = 0, .y = 0, .w = lay.title.w, .h = lay.footer.y + lay.footer.h });
        win98.drawOutset(win_r, win98.C.surface_container);

        var title_buf: [96]u8 = undefined;
        const title_txt = blk: {
            const t = std.fmt.bufPrint(title_buf[0..], "chat1d Native Client - {s}", .{display_nick}) catch break :blk "chat1d Native Client";
            title_buf[t.len] = 0;
            break :blk title_buf[0..t.len :0];
        };
        win98.drawTitleBar(self.panelRect(lay.title), title_txt, self.ui_font, self.ui_font_size, &self.chrome);

        if (lay.menu.h > 0) {
            const menu_r = self.panelRect(lay.menu);
            win98.fill(menu_r, win98.C.surface_container);
            const items = [_]struct { label: [:0]const u8, hot: u8, zone: *rl.Rectangle, kind: context_menu.Kind }{
                .{ .label = "File", .hot = 'f', .zone = &self.chrome.menu_file, .kind = .file },
                .{ .label = "Edit", .hot = 'e', .zone = &self.chrome.menu_edit, .kind = .edit },
                .{ .label = "View", .hot = 'v', .zone = &self.chrome.menu_view, .kind = .view },
                .{ .label = "Tools", .hot = 't', .zone = &self.chrome.menu_tools, .kind = .tools },
                .{ .label = "Help", .hot = 'h', .zone = &self.chrome.menu_help, .kind = .help },
            };
            var mx: f32 = menu_r.x + 8;
            const mp = rl.Vector2{ .x = @floatFromInt(mouse_x), .y = @floatFromInt(mouse_y) };
            for (items) |item| {
                const tw = rl.measureTextEx(self.ui_font, item.label, self.ui_font_size, 1).x + 10;
                item.zone.* = .{ .x = mx, .y = menu_r.y, .width = tw, .height = menu_r.height };
                const active = menu_open == item.kind;
                const hover = !active and rl.checkCollisionPointRec(mp, item.zone.*);
                if (active or hover) {
                    rl.drawRectangleRec(item.zone.*, win98.C.primary);
                }
                self.drawMenuLabel(mx + 2, menu_r.y + 2, item.label, item.hot, active, hover);
                mx += tw + 6;
            }
            rl.drawLine(@intFromFloat(menu_r.x), @intFromFloat(menu_r.y + menu_r.height - 1), @intFromFloat(menu_r.x + menu_r.width), @intFromFloat(menu_r.y + menu_r.height - 1), win98.C.border_dark);
        }

        const body_r = self.panelRect(.{
            .x = 0,
            .y = lay.menu.y + lay.menu.h,
            .w = lay.title.w,
            .h = lay.footer.y - (lay.menu.y + lay.menu.h),
        });
        const pad: f32 = 4;
        const work = rl.Rectangle{
            .x = body_r.x + pad,
            .y = body_r.y + pad,
            .width = if (body_r.width > pad * 2) body_r.width - pad * 2 else body_r.width,
            .height = if (body_r.height > pad * 2) body_r.height - pad * 2 else body_r.height,
        };
        win98.drawOutset(work, win98.C.surface_container);

        if (lay.show_servers) {
            const sr = rl.Rectangle{
                .x = work.x + 4,
                .y = work.y + 4,
                .width = self.pxW(lay.servers.w) - 4,
                .height = work.height - 8,
            };
            win98.drawInset(sr, win98.C.surface_container);
            self.servers_rect = sr;
            const icon: f32 = @as(f32, @floatFromInt(self.cell_w * 2));
            const tools = [_]struct { label: [:0]const u8, sel: ToolbarSel, zone: *rl.Rectangle }{
                .{ .label = "\u{25cf}", .sel = .server, .zone = &self.chrome.tool_server },
                .{ .label = "\u{2261}", .sel = .logs, .zone = &self.chrome.tool_logs },
                .{ .label = "\u{2699}", .sel = .settings, .zone = &self.chrome.tool_settings },
            };
            var ty = sr.y + 8;
            for (tools) |tool| {
                const ir = rl.Rectangle{ .x = sr.x + (sr.width - icon) * 0.5, .y = ty, .width = icon, .height = icon };
                tool.zone.* = ir;
                const active = toolbar_sel == tool.sel;
                win98.drawOutset(ir, if (active) win98.C.primary else win98.C.surface);
                self.drawTextPx(ir.x + (icon - rl.measureTextEx(self.font, tool.label, self.font_size, 1).x) * 0.5, ir.y + 2, tool.label, if (active) win98.C.text else win98.C.primary);
                ty += icon + 8;
            }
        }

        if (lay.show_rooms) {
            const tab_y_base = work.y + 4;
            var tab_x = work.x + self.pxW(lay.servers.w);
            var tab_bar_w: f32 = 0;
            @memset(&self.tab_cols, 0);
            for (sidebar_st.channels.items, 0..) |ch, i| {
                if (i >= self.tab_cols.len) break;
                var lb: [48]u8 = undefined;
                const label = blk: {
                    const t = std.fmt.bufPrint(lb[0..], "#{s}", .{ch.name}) catch continue;
                    lb[t.len] = 0;
                    break :blk lb[0..t.len :0];
                };
                const tw = rl.measureTextEx(self.ui_font, label, self.ui_font_size, 1).x + 16;
                const selected = if (current_room) |cr| sidebar.RoomSidebarState.namesEqual(cr, ch.name) else i == channel_sel;
                const inactive = !selected;
                const tab_h: f32 = if (selected) self.pxHi(1) - 2 else self.pxHi(1) - 6;
                const ty = if (selected) tab_y_base else tab_y_base + 4;
                const tr = rl.Rectangle{ .x = tab_x, .y = ty, .width = tw, .height = tab_h };
                self.tab_rects[i] = tr;
                self.tab_count = @intCast(i + 1);
                const hover = tab_hover == i;
                win98.drawOutset(tr, win98.C.surface_container);
                if (hover and inactive) {
                    rl.drawRectangleRec(tr, win98.C.surface);
                }
                if (selected) {
                    rl.drawRectangle(@intFromFloat(tr.x + 2), @intFromFloat(tr.y + tr.height - 2), @intFromFloat(tr.width - 4), 2, win98.C.surface_container);
                }
                self.drawUiTextSlice(tr.x + 8, tr.y + 2, label, if (selected or hover) win98.C.primary else win98.C.text_muted);
                self.tab_cols[i] = @intFromFloat(@ceil(tw / @as(f32, @floatFromInt(@max(1, self.cell_w)))));
                tab_x += tw + 2;
                tab_bar_w += tw + 2;
            }
            self.tab_bar_rect = .{ .x = work.x + self.pxW(lay.servers.w), .y = tab_y_base, .width = tab_bar_w, .height = self.pxHi(1) };
        }

        const main_x = work.x + self.pxW(lay.servers.w) + 4;
        const main_w = work.width - self.pxW(lay.servers.w) - self.pxW(lay.members.w) - 12;
        const main_top = work.y + self.pxHi(1) + 2;
        const main_h = work.height - self.pxHi(1) - 10;
        const main_r = rl.Rectangle{ .x = main_x, .y = main_top, .width = main_w, .height = main_h };
        win98.drawOutset(main_r, win98.C.surface_container);

        const input_rows = inputLineRows(input_buf);
        const input_h_px = self.pxHi(@max(2, input_rows));
        const tx_r = rl.Rectangle{
            .x = main_r.x + 4,
            .y = main_r.y + 4,
            .width = if (main_r.width > 8) main_r.width - 8 else main_r.width,
            .height = if (main_r.height > input_h_px + 12) main_r.height - input_h_px - 12 else main_r.height,
        };
        win98.drawDeepInset(tx_r);
        self.transcript_rect = tx_r;

        self.beginPanelClip(lay.transcript);
        const inner_h = tui.transcriptInnerRows(lay);
        const tx_cols = innerCols(lay.transcript);
        const max_w_px = self.pxWCols(tx_cols) - 8;
        const visible_total = transcript_layout.visibleTotal(transcript.items, current_room, attach_tex.items, self.cell_h, max_w_px, tx_cols);
        const skip = @min(transcript_skip, transcript_layout.maxSkip(visible_total, inner_h));
        var passed: usize = 0;
        var dr: u16 = 0;
        const tx_pad_col: u16 = lay.transcript.x + 1;
        const tx_pad_row: u16 = lay.transcript.y + 1;
        for (transcript.items, 0..) |e, idx| {
            if (!tui.visibleTranscriptLine(e, current_room)) continue;
            const tex: ?rl.Texture2D = if (idx < attach_tex.items.len) attach_tex.items[idx] else null;
            const rows = transcript_layout.guiLineRows(e, tex, self.cell_h, max_w_px, tx_cols);
            if (passed + rows <= skip) {
                passed += rows;
                continue;
            }
            switch (e) {
                .global => |g| {
                    if (selection) |sel| {
                        if (idx >= sel.from and idx <= sel.to) {
                            const ip = self.px(tx_pad_col, tx_pad_row + dr);
                            const hr = rl.Rectangle{ .x = ip.x, .y = ip.y, .width = max_w_px, .height = self.pxHi(1) };
                            rl.drawRectangleRec(hr, win98.C.primary);
                        }
                    }
                    dr += self.drawWrappedRows(tx_pad_col, tx_pad_row + dr, g.text, tx_cols, win98.C.sys);
                },
                .room => |m| {
                    if (selection) |sel| {
                        if (idx >= sel.from and idx <= sel.to) {
                            const ip = self.px(tx_pad_col, tx_pad_row + dr);
                            const line_rows = transcript_layout.guiLineRows(e, tex, self.cell_h, max_w_px, tx_cols);
                            const hr = rl.Rectangle{ .x = ip.x, .y = ip.y, .width = max_w_px, .height = self.pxHi(@intCast(line_rows)) };
                            rl.drawRectangleRec(hr, win98.C.primary);
                        }
                    }
                    dr += self.drawRoomMessage(tx_pad_col, tx_pad_row + dr, m.nick, m.body, m.ts, tx_cols);
                },
                .attach => |a| {
                    if (selection) |sel| {
                        if (idx >= sel.from and idx <= sel.to) {
                            const ip = self.px(tx_pad_col, tx_pad_row + dr);
                            const line_rows = transcript_layout.guiLineRows(e, tex, self.cell_h, max_w_px, tx_cols);
                            const hr = rl.Rectangle{ .x = ip.x, .y = ip.y, .width = max_w_px, .height = self.pxHi(@intCast(line_rows)) };
                            rl.drawRectangleRec(hr, win98.C.primary);
                        }
                    }
                    var cap: [160]u8 = undefined;
                    const line = std.fmt.bufPrint(cap[0..], "[img] {s}", .{a.caption}) catch a.caption;
                    dr += self.drawWrappedRows(tx_pad_col, tx_pad_row + dr, line, tx_cols, win98.C.text_muted);
                    if (tex) |t| {
                        const scale = @min(1.0, max_w_px / @as(f32, @floatFromInt(t.width)));
                        const ip = self.px(tx_pad_col, tx_pad_row + dr);
                        const tw: f32 = @as(f32, @floatFromInt(t.width)) * scale;
                        const th_px: f32 = @as(f32, @floatFromInt(t.height)) * scale;
                        const img_r = rl.Rectangle{ .x = ip.x + 4, .y = ip.y, .width = tw, .height = th_px };
                        win98.drawInset(img_r, win98.C.surface);
                        rl.drawTextureEx(t, .{ .x = ip.x + 6, .y = ip.y + 2 }, 0, scale, rl.Color.white);
                        dr += transcript_layout.attachImageRows(t, self.cell_h, max_w_px);
                    }
                },
            }
            passed += rows;
            if (dr >= inner_h) break;
        }
        rl.endScissorMode();

        const max_skip = transcript_layout.maxSkip(visible_total, inner_h);
        if (max_skip > 0 and tx_r.height > 20) {
            const sb_w: f32 = 12;
            const sb_r = rl.Rectangle{
                .x = tx_r.x + tx_r.width - sb_w - 2,
                .y = tx_r.y + 2,
                .width = sb_w,
                .height = tx_r.height - 4,
            };
            win98.drawInset(sb_r, win98.C.surface_container);
            const track_h = sb_r.height - 4;
            const vis_f: f32 = @floatFromInt(inner_h);
            const total_f: f32 = @floatFromInt(visible_total);
            const thumb_h = @max(16, track_h * (vis_f / total_f));
            const skip_f: f32 = @floatFromInt(skip);
            const max_f: f32 = @floatFromInt(max_skip);
            const thumb_y = sb_r.y + 2 + (track_h - thumb_h) * (skip_f / max_f);
            const thumb_r = rl.Rectangle{ .x = sb_r.x + 2, .y = thumb_y, .width = sb_w - 4, .height = thumb_h };
            win98.drawOutset(thumb_r, win98.C.surface);
            self.scroll_track_rect = sb_r;
            self.scroll_thumb_rect = thumb_r;
            self.scroll_max_skip = max_skip;
            self.scroll_active = true;
        } else {
            self.scroll_track_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            self.scroll_thumb_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }

        const in_r = rl.Rectangle{
            .x = main_r.x + 4,
            .y = main_r.y + main_r.height - input_h_px - 4,
            .width = if (main_r.width > 8) main_r.width - 8 else main_r.width,
            .height = input_h_px,
        };
        self.input_rect = in_r;
        win98.drawDeepInset(in_r);
        rl.beginScissorMode(@intFromFloat(in_r.x + 2), @intFromFloat(in_r.y + 2), @intFromFloat(in_r.width - 4), @intFromFloat(in_r.height - 4));
        var prompt: [80]u8 = undefined;
        const pfx = blk: {
            if (cmd_mode) {
                const t = std.fmt.bufPrint(prompt[0..], ">:", .{}) catch break :blk ">";
                prompt[t.len] = 0;
                break :blk prompt[0..t.len :0];
            }
            if (current_room) |room| {
                const t = std.fmt.bufPrint(prompt[0..], "> #{s} ", .{room}) catch break :blk "> ";
                prompt[t.len] = 0;
                break :blk prompt[0..t.len :0];
            }
            const t = std.fmt.bufPrint(prompt[0..], "> ", .{}) catch break :blk ">";
            prompt[t.len] = 0;
            break :blk prompt[0..t.len :0];
        };
        const text_y = in_r.y + 5;
        var text_x = in_r.x + 8;
        self.drawTextSlice(text_x, text_y, pfx, win98.C.primary);
        text_x += rl.measureTextEx(self.font, pfx, self.font_size, 1).x;
        var line_y = text_y;
        var line_start: usize = 0;
        for (input_buf, 0..) |c, i| {
            if (c == '\n' or i + 1 == input_buf.len) {
                const end = if (c == '\n') i else i + 1;
                if (end > line_start) {
                    self.drawTextSlice(text_x, line_y, input_buf[line_start..end], win98.C.text);
                }
                if (c == '\n') {
                    line_y += self.pxHi(1);
                    line_start = i + 1;
                }
            }
        }
        if (ui_focus == .input and (frame / 30) % 2 == 0) {
            const caret = self.inputCaretPx(text_x, text_y, input_buf, input_cursor);
            rl.drawLineEx(.{ .x = caret.x, .y = caret.y }, .{ .x = caret.x, .y = caret.y + self.font_size }, 2, win98.C.primary);
        }
        rl.endScissorMode();

        self.members_visible = lay.show_members;
        if (lay.show_members) {
            const mr = rl.Rectangle{
                .x = work.x + work.width - self.pxW(lay.members.w) + 4,
                .y = work.y + 4,
                .width = self.pxW(lay.members.w) - 8,
                .height = work.height - 8,
            };
            const head_h: f32 = self.pxHi(1);
            const head = rl.Rectangle{ .x = mr.x, .y = mr.y, .width = mr.width, .height = head_h };
            rl.drawRectangleRec(head, win98.C.primary_dark);
            self.drawUiTextPx(head.x + 4, head.y + 2, "MEMBERS", win98.C.text);
            const list_r = rl.Rectangle{ .x = mr.x, .y = mr.y + head_h, .width = mr.width, .height = mr.height - head_h };
            self.members_panel_rect = mr;
            self.members_list_rect = list_r;
            win98.drawInset(list_r, win98.C.surface);
            var my: f32 = list_r.y + 6;
            for (member_list.items, 0..) |m, i| {
                var lb: [64]u8 = undefined;
                const short = util.nickShort(m.name);
                const label = std.fmt.bufPrint(lb[0..], " {s}", .{short}) catch continue;
                const hi = (i == member_sel) and ui_focus == .members;
                const hover = member_hover == i;
                if (hover and !hi) {
                    const hr = rl.Rectangle{ .x = list_r.x + 2, .y = my - 2, .width = list_r.width - 4, .height = self.pxHi(1) };
                    rl.drawRectangleRec(hr, win98.C.primary);
                }
                const dot_c = if (m.online) win98.C.green else win98.C.text_muted;
                rl.drawCircle(@intFromFloat(list_r.x + 10), @intFromFloat(my + self.font_size * 0.5), 3, dot_c);
                self.drawUiTextSlice(list_r.x + 18, my, label, if (hi or hover) win98.C.text else win98.C.text);
                my += self.pxHi(1);
            }
        } else {
            self.members_panel_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }

        const status_r = self.panelRect(lay.footer);
        win98.fill(status_r, win98.C.surface_container);
        rl.drawLine(@intFromFloat(status_r.x), @intFromFloat(status_r.y), @intFromFloat(status_r.x + status_r.width), @intFromFloat(status_r.y), win98.C.border_light);
        var stat_buf: [16]u8 = undefined;
        const stat = blk: {
            const s = if (connected) "Connected" else "Offline";
            @memcpy(stat_buf[0..s.len], s);
            stat_buf[s.len] = 0;
            break :blk stat_buf[0..s.len :0];
        };
        var host_buf: [48]u8 = undefined;
        const hostline = blk: {
            const t = std.fmt.bufPrint(host_buf[0..], "{s}:{d}", .{ host, port }) catch break :blk "?";
            host_buf[t.len] = 0;
            break :blk host_buf[0..t.len :0];
        };
        const chip_h = status_r.height - 4;
        const chip_y = status_r.y + 2;
        var chip_x = status_r.x + 4;
        const conn_tw = rl.measureTextEx(self.ui_font, stat, self.ui_font_size, 1).x + 16;
        const conn_r = rl.Rectangle{ .x = chip_x, .y = chip_y, .width = @max(100, conn_tw), .height = chip_h };
        win98.drawInset(conn_r, win98.C.surface);
        self.drawUiTextPx(conn_r.x + 6, conn_r.y + 2, stat, if (connected) win98.C.primary else win98.C.text_muted);
        chip_x += conn_r.width + 4;
        const host_tw = rl.measureTextEx(self.ui_font, hostline, self.ui_font_size, 1).x + 16;
        const host_r = rl.Rectangle{ .x = chip_x, .y = chip_y, .width = @max(90, host_tw), .height = chip_h };
        win98.drawInset(host_r, win98.C.surface);
        self.drawUiTextPx(host_r.x + 6, host_r.y + 2, hostline, win98.C.primary);
        _ = room_disp;
        self.drawUiTextSlice(status_r.x + status_r.width - 300, status_r.y + 2, "right-click · scroll · Ctrl+V · Esc", win98.C.text_muted);
    }

    pub fn menuAnchor(self: *const Painter, act: chrome.Action) ?rl.Rectangle {
        return switch (act) {
            .menu_file => self.chrome.menu_file,
            .menu_edit => self.chrome.menu_edit,
            .menu_view => self.chrome.menu_view,
            .menu_tools => self.chrome.menu_tools,
            .menu_help => self.chrome.menu_help,
            else => null,
        };
    }

    pub fn viewport(self: Painter) rl.Rectangle {
        const cr = self.colsRows(rl.getScreenWidth(), rl.getScreenHeight());
        return .{
            .x = 0,
            .y = 0,
            .width = self.pxW(cr.cols),
            .height = self.pxH(cr.rows),
        };
    }

    pub fn drawContextMenu(self: Painter, menu: *context_menu.State, mx: i32, my: i32) void {
        menu.draw(self.font, self.font_size, mx, my);
    }

    fn drawWrappedRows(self: Painter, col: u16, row: u16, text: []const u8, max_cols: usize, color: rl.Color) u16 {
        if (max_cols == 0 or text.len == 0) {
            if (text.len > 0) self.drawTextAt(col, row, text, max_cols, color);
            return 1;
        }
        var used: u16 = 0;
        var i: usize = 0;
        while (i < text.len) : (used += 1) {
            if (text[i] == '\n') {
                i += 1;
                continue;
            }
            var end = i;
            var count: usize = 0;
            while (end < text.len and text[end] != '\n' and count < max_cols) : (end += 1) {
                count += 1;
            }
            self.drawTextAt(col, row + used, text[i..end], max_cols, color);
            i = if (end < text.len and text[end] == '\n') end + 1 else end;
        }
        return @as(u16, @intCast(transcript_layout.wrapRows(text, max_cols)));
    }

    fn drawRoomMessage(self: Painter, col: u16, row: u16, nick: []const u8, body: []const u8, ts: i64, max_cols: usize) u16 {
        if (max_cols == 0) return 1;
        var time_buf: [6]u8 = undefined;
        const time_s = fmtTime(ts, &time_buf);
        var head: [96]u8 = undefined;
        const prefix = if (time_s.len > 0)
            std.fmt.bufPrint(head[0..], "[{s}] <{s}> ", .{ time_s, nick }) catch return self.drawWrappedRows(col, row, body, max_cols, win98.C.text)
        else
            std.fmt.bufPrint(head[0..], "<{s}> ", .{nick}) catch return self.drawWrappedRows(col, row, body, max_cols, win98.C.text);
        if (prefix.len >= max_cols) {
            _ = self.drawWrappedRows(col, row, prefix, max_cols, win98.nickColor(nick));
            return @as(u16, @intCast(transcript_layout.wrapRows(prefix, max_cols))) + self.drawWrappedRows(col, row + @as(u16, @intCast(transcript_layout.wrapRows(prefix, max_cols))), body, max_cols, win98.C.text);
        }
        self.drawTextAt(col, row, prefix, max_cols, win98.nickColor(nick));
        const first_cols = max_cols - prefix.len;
        var used: u16 = 1;
        var i: usize = 0;
        while (i < body.len) {
            var end = i;
            var count: usize = 0;
            const line_cols = if (used == 1) first_cols else max_cols;
            while (end < body.len and body[end] != '\n' and count < line_cols) : (end += 1) {
                count += 1;
            }
            const line_col = if (used == 1) col + @as(u16, @intCast(prefix.len)) else col;
            self.drawTextAt(line_col, row + used - 1, body[i..end], line_cols, win98.C.text);
            i = if (end < body.len and body[end] == '\n') end + 1 else end;
            if (i < body.len or end > i) used += 1;
            if (end >= body.len) break;
        }
        return @as(u16, @intCast(transcript_layout.roomLineRows(nick, body, max_cols)));
    }

    pub fn transcriptCols(_: Painter, lay: layout.Layout) usize {
        return innerCols(lay.transcript);
    }

    pub fn transcriptMaxW(self: Painter, lay: layout.Layout) f32 {
        const tx_cols = innerCols(lay.transcript);
        return self.pxWCols(tx_cols) - 8;
    }

    pub fn hitTranscriptLine(
        self: *const Painter,
        mx: i32,
        my: i32,
        transcript: []const transcript_mod.TranscriptLine,
        attach_tex: []const ?rl.Texture,
        current_room: ?[]const u8,
        transcript_skip: usize,
        lay: layout.Layout,
    ) ?usize {
        if (self.transcript_rect.width <= 0) return null;
        const inner = rl.Rectangle{
            .x = self.transcript_rect.x + 4,
            .y = self.transcript_rect.y + 4,
            .width = if (self.transcript_rect.width > 8) self.transcript_rect.width - 8 else 0,
            .height = if (self.transcript_rect.height > 8) self.transcript_rect.height - 8 else 0,
        };
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        if (!rl.checkCollisionPointRec(p, inner)) return null;

        const inner_h = tui.transcriptInnerRows(lay);
        const max_w_px = self.transcriptMaxW(lay);
        const want_dr: usize = @intCast(@max(0, @divFloor(my - @as(i32, @intFromFloat(inner.y)), self.cell_h)));
        return transcript_layout.lineIndexAtRow(
            transcript,
            current_room,
            attach_tex,
            self.cell_h,
            max_w_px,
            self.transcriptCols(lay),
            inner_h,
            transcript_skip,
            want_dr,
        );
    }

    pub fn hitMember(self: *const Painter, mx: i32, my: i32, count: usize) ?usize {
        if (!self.members_visible or self.members_list_rect.width <= 0) return null;
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        if (!rl.checkCollisionPointRec(p, self.members_list_rect)) return null;
        const rel = @as(f32, @floatFromInt(my)) - self.members_list_rect.y - 6;
        if (rel < 0) return null;
        const idx: usize = @intCast(@divFloor(@as(i32, @intFromFloat(rel)), self.cell_h));
        if (idx < count) return idx;
        return null;
    }

    fn drawInner(self: Painter, panel: layout.Rect, inner_row: u16, text: []const u8, color: rl.Color) void {
        self.drawTextAt(panel.x + 1, panel.y + 1 + inner_row, text, innerCols(panel), color);
    }

    pub fn hitChrome(self: *const Painter, mx: i32, my: i32) chrome.Action {
        return self.chrome.pick(mx, my);
    }

    fn inputCaretPx(self: Painter, text_x: f32, text_y: f32, buf: []const u8, cursor: usize) rl.Vector2 {
        var ly = text_y;
        var line_start: usize = 0;
        const at = @min(cursor, buf.len);
        for (buf, 0..) |c, i| {
            if (c == '\n' or i + 1 == buf.len) {
                const end = if (c == '\n') i else i + 1;
                if (at >= line_start and at <= end) {
                    var z: [512]u8 = [_]u8{0} ** 512;
                    const n = @min(at - line_start, z.len - 1);
                    if (n > 0) @memcpy(z[0..n], buf[line_start..][0..n]);
                    const cx = text_x + rl.measureTextEx(self.font, z[0..n :0], self.font_size, 1).x + 1;
                    return .{ .x = cx, .y = ly };
                }
                if (c == '\n') {
                    ly += self.pxHi(1);
                    line_start = i + 1;
                }
            }
        }
        return .{ .x = text_x, .y = text_y };
    }

    pub fn inputCursorAt(self: Painter, mx: i32, my: i32, input_buf: []const u8, pfx: []const u8) usize {
        if (self.input_rect.width <= 0) return input_buf.len;
        var z: [80]u8 = [_]u8{0} ** 80;
        const pn = @min(pfx.len, z.len - 1);
        @memcpy(z[0..pn], pfx[0..pn]);
        const text_x = self.input_rect.x + 8 + rl.measureTextEx(self.font, z[0..pn :0], self.font_size, 1).x;
        const text_y = self.input_rect.y + 5;
        return gui_input.cursorFromClick(self.font, self.font_size, text_x, text_y, self.pxHi(1), input_buf, mx, my);
    }

    pub fn hitScrollThumb(self: *const Painter, mx: i32, my: i32) bool {
        if (!self.scroll_active) return false;
        return rl.checkCollisionPointRec(.{ .x = @floatFromInt(mx), .y = @floatFromInt(my) }, self.scroll_thumb_rect);
    }

    pub fn hitScrollTrack(self: *const Painter, mx: i32, my: i32) bool {
        if (!self.scroll_active) return false;
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        return rl.checkCollisionPointRec(p, self.scroll_track_rect) and !rl.checkCollisionPointRec(p, self.scroll_thumb_rect);
    }

    pub fn scrollSkipFromY(self: *const Painter, my: i32, thumb_grab_dy: f32) usize {
        if (!self.scroll_active or self.scroll_max_skip == 0) return 0;
        const track = self.scroll_track_rect;
        const thumb_h = self.scroll_thumb_rect.height;
        const usable = track.height - 4 - thumb_h;
        if (usable <= 0) return 0;
        var rel = @as(f32, @floatFromInt(my)) - track.y - 2 - thumb_grab_dy;
        rel = std.math.clamp(rel, 0, usable);
        const t = rel / usable;
        return @intFromFloat(t * @as(f32, @floatFromInt(self.scroll_max_skip)));
    }

    pub fn hitInput(self: *const Painter, mx: i32, my: i32) bool {
        if (self.input_rect.width <= 0) return false;
        return rl.checkCollisionPointRec(.{ .x = @floatFromInt(mx), .y = @floatFromInt(my) }, self.input_rect);
    }

    pub fn hitPane(self: *const Painter, lay: layout.Layout, mx: i32, my: i32) ?focus.Focus {
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        if (self.hitInput(mx, my)) return .input;
        if (lay.show_members and self.members_panel_rect.width > 0 and rl.checkCollisionPointRec(p, self.members_panel_rect)) {
            return .members;
        }
        if (lay.show_rooms) {
            const n = @min(self.tab_count, self.tab_rects.len);
            for (0..n) |i| {
                if (rl.checkCollisionPointRec(p, self.tab_rects[i])) return .rooms;
            }
            if (self.tab_bar_rect.width > 0 and rl.checkCollisionPointRec(p, self.tab_bar_rect)) {
                return .rooms;
            }
        }
        if (lay.show_servers and self.servers_rect.width > 0 and rl.checkCollisionPointRec(p, self.servers_rect)) {
            return .servers;
        }
        if (self.transcript_rect.width > 0 and rl.checkCollisionPointRec(p, self.transcript_rect)) {
            return .transcript;
        }
        return null;
    }

    pub fn hitTab(self: *const Painter, mx: i32, my: i32, channel_count: usize) ?usize {
        const p = rl.Vector2{ .x = @floatFromInt(mx), .y = @floatFromInt(my) };
        const n = @min(@min(channel_count, self.tab_count), self.tab_rects.len);
        for (0..n) |i| {
            if (rl.checkCollisionPointRec(p, self.tab_rects[i])) return i;
        }
        return null;
    }
};
