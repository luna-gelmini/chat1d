const rl = @import("raylib");

const embedded_font = @embedFile("assets/DejaVuSansMono.ttf");

fn fontCodepoints(out: *[512]i32) []const i32 {
    var n: usize = 0;
    for (32..127) |cp| {
        out[n] = @intCast(cp);
        n += 1;
    }
    // Latin-1 supplement: middle dot, accents, etc.
    for (128..256) |cp| {
        out[n] = @intCast(cp);
        n += 1;
    }
    const extra = [_]i32{ 0x25cf, 0x25cb, 0x2261, 0x2699, 0x25aa };
    for (extra) |cp| {
        out[n] = cp;
        n += 1;
    }
    return out[0..n];
}

pub fn loadGuiFonts(chat_size: i32) struct { chat: rl.Font, ui: rl.Font, owned_chat: bool } {
    const mono = loadMonoFont(chat_size);
    return .{
        .chat = mono.font,
        .ui = rl.getFontDefault() catch unreachable,
        .owned_chat = mono.owned,
    };
}

pub fn loadMonoFont(font_size: i32) struct { font: rl.Font, owned: bool } {
    var cps: [512]i32 = undefined;
    const cp_slice = fontCodepoints(&cps);
    const font = rl.loadFontFromMemory(".ttf", embedded_font, font_size, cp_slice) catch {
        return .{ .font = rl.getFontDefault() catch unreachable, .owned = false };
    };
    if (font.texture.id == 0) {
        return .{ .font = rl.getFontDefault() catch unreachable, .owned = false };
    }
    rl.setTextureFilter(font.texture, .point);
    return .{ .font = font, .owned = true };
}
