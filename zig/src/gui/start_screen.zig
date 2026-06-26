const std = @import("std");
const rl = @import("raylib");
const input = @import("gui/input");
const win98 = @import("gui/win98");

/// Name entry screen. Returns owned nick or null if user quit.
pub fn run(gpa: std.mem.Allocator, font: rl.Font, font_size: f32, seed: []const u8) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (seed.len > 0) try buf.appendSlice(gpa, seed);

    const title_fs: f32 = font_size * 1.75;
    const body_fs: f32 = font_size;
    var tick: u32 = 0;

    while (!rl.windowShouldClose()) {
        tick +%= 1;
        rl.beginDrawing();
        rl.clearBackground(win98.C.background);

        const ww: f32 = @floatFromInt(rl.getScreenWidth());
        const wh: f32 = @floatFromInt(rl.getScreenHeight());
        const pad: f32 = 24;
        const win = rl.Rectangle{ .x = pad, .y = pad, .width = ww - pad * 2, .height = wh - pad * 2 };
        win98.drawOutset(win, win98.C.surface_container);

        var title_buf: [32]u8 = undefined;
        const tb = blk: {
            const t = std.fmt.bufPrint(title_buf[0..], "chat1", .{}) catch break :blk "chat1";
            title_buf[t.len] = 0;
            break :blk title_buf[0..t.len :0];
        };
        const title_r = rl.Rectangle{ .x = win.x + 2, .y = win.y + 2, .width = win.width - 4, .height = 22 };
        win98.drawTitleBar(title_r, tb, font, body_fs, null);

        const work = rl.Rectangle{
            .x = win.x + 6,
            .y = title_r.y + title_r.height + 6,
            .width = win.width - 12,
            .height = win.height - title_r.height - 14,
        };
        win98.drawOutset(work, win98.C.surface_container);

        const anim_w = work.width * 0.42;
        const anim_rect = rl.Rectangle{ .x = work.x + 4, .y = work.y + 4, .width = anim_w - 8, .height = work.height - 8 };
        win98.drawDeepInset(anim_rect);
        const hint = "GLB animation";
        const hw = rl.measureTextEx(font, hint, body_fs * 0.9, 1).x;
        input.drawText(font, body_fs * 0.9, anim_rect.x + (anim_rect.width - hw) * 0.5, anim_rect.y + anim_rect.height * 0.5 - body_fs, hint, win98.C.text_muted);

        const form_x = anim_rect.x + anim_rect.width + 16;
        const form_w = work.x + work.width - form_x - 8;
        input.drawText(font, body_fs * 0.85, form_x, work.y + 24, "SECURE CHAT . PROTOCOL 1", win98.C.primary);
        const prompt = "What is your name?";
        const pw = rl.measureTextEx(font, prompt, title_fs, 1).x;
        input.drawText(font, title_fs, form_x + (form_w - pw) * 0.5, work.y + work.height * 0.38, prompt, win98.C.text);

        const field_y = work.y + work.height * 0.38 + title_fs + 20;
        const field = rl.Rectangle{ .x = form_x, .y = field_y, .width = form_w, .height = body_fs + 16 };
        win98.drawDeepInset(field);

        const text_x = field.x + 10;
        const text_y = field.y + 6;
        input.drawText(font, body_fs, text_x, text_y, "> ", win98.C.primary);
        const prompt_w = rl.measureTextEx(font, "> ", body_fs, 1).x;
        input.drawText(font, body_fs, text_x + prompt_w, text_y, buf.items, win98.C.text);

        if ((tick / 30) % 2 == 0) {
            var z: [64]u8 = [_]u8{0} ** 64;
            const zn = @min(buf.items.len, z.len - 1);
            @memcpy(z[0..zn], buf.items[0..zn]);
            const cx = text_x + prompt_w + rl.measureTextEx(font, z[0..zn :0], body_fs, 1).x + 1;
            rl.drawLineEx(.{ .x = cx, .y = text_y }, .{ .x = cx, .y = text_y + body_fs }, 1, win98.C.text);
        }

        const leg = "Enter join · Esc quit";
        input.drawText(font, body_fs * 0.85, form_x, work.y + work.height - body_fs - 8, leg, win98.C.text_muted);

        rl.endDrawing();

        switch (try input.pollAsciiLine(gpa, &buf, 32)) {
            .cont => {},
            .quit => return null,
            .submit => {
                const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
                return try gpa.dupe(u8, trimmed);
            },
        }
    }
    return null;
}
