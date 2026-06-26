const rl = @import("raylib");
const chrome = @import("gui/chrome");

pub const C = struct {
    pub const background = rl.Color{ .r = 17, .g = 18, .b = 22, .a = 255 };
    pub const surface = rl.Color{ .r = 26, .g = 28, .b = 35, .a = 255 };
    pub const surface_container = rl.Color{ .r = 43, .g = 46, .b = 56, .a = 255 };
    pub const primary = rl.Color{ .r = 92, .g = 133, .b = 214, .a = 255 };
    pub const primary_dark = rl.Color{ .r = 0, .g = 0, .b = 64, .a = 255 };
    pub const primary_mid = rl.Color{ .r = 16, .g = 32, .b = 80, .a = 255 };
    pub const border_light = rl.Color{ .r = 74, .g = 79, .b = 96, .a = 255 };
    pub const border_dark = rl.Color{ .r = 10, .g = 11, .b = 14, .a = 255 };
    pub const text = rl.Color{ .r = 229, .g = 226, .b = 227, .a = 255 };
    pub const text_muted = rl.Color{ .r = 156, .g = 163, .b = 175, .a = 255 };
    pub const green = rl.Color{ .r = 34, .g = 197, .b = 94, .a = 255 };
    pub const sys = rl.Color{ .r = 107, .g = 114, .b = 128, .a = 255 };
};

pub fn fill(r: rl.Rectangle, color: rl.Color) void {
    rl.drawRectangleRec(r, color);
}

pub fn drawOutset(r: rl.Rectangle, face: rl.Color) void {
    fill(r, face);
    rl.drawLineEx(.{ .x = r.x, .y = r.y }, .{ .x = r.x + r.width - 1, .y = r.y }, 2, C.border_light);
    rl.drawLineEx(.{ .x = r.x, .y = r.y }, .{ .x = r.x, .y = r.y + r.height - 1 }, 2, C.border_light);
    rl.drawLineEx(.{ .x = r.x, .y = r.y + r.height - 1 }, .{ .x = r.x + r.width - 1, .y = r.y + r.height - 1 }, 2, C.border_dark);
    rl.drawLineEx(.{ .x = r.x + r.width - 1, .y = r.y }, .{ .x = r.x + r.width - 1, .y = r.y + r.height - 1 }, 2, C.border_dark);
}

pub fn drawInset(r: rl.Rectangle, face: rl.Color) void {
    fill(r, face);
    rl.drawLineEx(.{ .x = r.x, .y = r.y }, .{ .x = r.x + r.width - 1, .y = r.y }, 2, C.border_dark);
    rl.drawLineEx(.{ .x = r.x, .y = r.y }, .{ .x = r.x, .y = r.y + r.height - 1 }, 2, C.border_dark);
    rl.drawLineEx(.{ .x = r.x, .y = r.y + r.height - 1 }, .{ .x = r.x + r.width - 1, .y = r.y + r.height - 1 }, 2, C.border_light);
    rl.drawLineEx(.{ .x = r.x + r.width - 1, .y = r.y }, .{ .x = r.x + r.width - 1, .y = r.y + r.height - 1 }, 2, C.border_light);
}

pub fn drawDeepInset(r: rl.Rectangle) void {
    drawInset(r, C.background);
    const inner = rl.Rectangle{
        .x = r.x + 2,
        .y = r.y + 2,
        .width = if (r.width > 4) r.width - 4 else r.width,
        .height = if (r.height > 4) r.height - 4 else r.height,
    };
    fill(inner, C.background);
    rl.drawLine(@intFromFloat(inner.x), @intFromFloat(inner.y), @intFromFloat(inner.x + inner.width - 1), @intFromFloat(inner.y), C.border_dark);
    rl.drawLine(@intFromFloat(inner.x), @intFromFloat(inner.y), @intFromFloat(inner.x), @intFromFloat(inner.y + inner.height - 1), C.border_dark);
}

pub fn drawTitleBar(r: rl.Rectangle, title: [:0]const u8, font: rl.Font, font_size: f32, zones: ?*chrome.Zones) void {
    rl.drawRectangleGradientH(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), @intFromFloat(r.height), C.primary_dark, C.primary_mid);
    rl.drawTextEx(font, title, .{ .x = r.x + 6, .y = r.y + 3 }, font_size, 1, C.text);

    const btn: f32 = 16;
    const gap: f32 = 2;
    var bx = r.x + r.width - 6 - (btn * 3 + gap * 2);
    const by = r.y + 3;
    const rects = [_]?*rl.Rectangle{ if (zones) |z| &z.min else null, if (zones) |z| &z.max else null, if (zones) |z| &z.close else null };
    const glyphs = [_][:0]const u8{ "_", "[]", "x" };
    for (rects, glyphs) |opt, glyph| {
        const br = rl.Rectangle{ .x = bx, .y = by, .width = btn, .height = btn };
        if (opt) |slot| slot.* = br;
        drawOutset(br, C.surface_container);
        const m = rl.measureTextEx(font, glyph, font_size * 0.85, 1);
        rl.drawTextEx(font, glyph, .{
            .x = br.x + (btn - m.x) * 0.5,
            .y = br.y + (btn - m.y) * 0.5 - 1,
        }, font_size * 0.85, 1, C.text);
        bx += btn + gap;
    }
}

pub fn drawWinButton(r: rl.Rectangle, label: [:0]const u8, font: rl.Font, font_size: f32, active: bool) void {
    drawOutset(r, if (active) C.primary else C.surface_container);
    const m = rl.measureTextEx(font, label, font_size, 1);
    rl.drawTextEx(font, label, .{
        .x = r.x + (r.width - m.x) * 0.5,
        .y = r.y + (r.height - m.y) * 0.5,
    }, font_size, 1, if (active) C.text else C.text_muted);
}

pub fn nickColor(nick: []const u8) rl.Color {
    var h: u32 = 0;
    for (nick) |c| h = h *% 31 +% c;
    return if (h % 3 == 0) C.green else C.primary;
}
