const std = @import("std");
const rl = @import("raylib");

pub const Poll = enum { cont, submit, quit };

pub fn pollAsciiLine(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max_len: usize) !Poll {
    if (rl.isKeyPressed(rl.KeyboardKey.escape)) return .quit;

    if (rl.isKeyPressed(rl.KeyboardKey.enter) or rl.isKeyPressed(rl.KeyboardKey.kp_enter)) {
        if (std.mem.trim(u8, buf.items, " \t\r\n").len > 0) return .submit;
        return .cont;
    }

    if (rl.isKeyPressed(rl.KeyboardKey.backspace)) {
        if (buf.items.len > 0) _ = buf.pop();
    }

    var key = rl.getCharPressed();
    while (key > 0) {
        const c: u8 = @intCast(key);
        if (c >= 32 and c < 127 and buf.items.len < max_len) {
            try buf.append(gpa, c);
        }
        key = rl.getCharPressed();
    }

    return .cont;
}

pub fn drawText(font: rl.Font, font_size: f32, x: f32, y: f32, text: []const u8, color: rl.Color) void {
    var zbuf: [256]u8 = [_]u8{0} ** 256;
    const n = @min(text.len, zbuf.len - 1);
    @memcpy(zbuf[0..n], text[0..n]);
    rl.drawTextEx(font, zbuf[0..n :0], .{ .x = x, .y = y }, font_size, 1, color);
}

fn insertAt(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), cursor: *usize, c: u8, max_len: usize) !void {
    if (buf.items.len >= max_len) return;
    const at = @min(cursor.*, buf.items.len);
    try buf.insert(gpa, at, c);
    cursor.* = at + 1;
}

fn deleteBefore(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), cursor: *usize) void {
    if (cursor.* == 0 or buf.items.len == 0) return;
    cursor.* -= 1;
    _ = buf.orderedRemove(cursor.*);
    _ = gpa;
}

fn moveCursor(buf: []const u8, cursor: *usize, delta: isize) void {
    const next: isize = @as(isize, @intCast(cursor.*)) + delta;
    if (next < 0) {
        cursor.* = 0;
        return;
    }
    const max: isize = @intCast(buf.len);
    cursor.* = @intCast(@min(next, max));
}

/// Append printable keys at cursor; arrow keys move cursor.
pub fn pumpKeys(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max_len: usize, cursor: *usize) !void {
    if (cursor.* > buf.items.len) cursor.* = buf.items.len;

    if (rl.isKeyPressed(rl.KeyboardKey.backspace)) {
        deleteBefore(gpa, buf, cursor);
    }
    if (rl.isKeyPressed(rl.KeyboardKey.delete)) {
        if (cursor.* < buf.items.len) _ = buf.orderedRemove(cursor.*);
    }
    if (rl.isKeyPressed(rl.KeyboardKey.left)) moveCursor(buf.items, cursor, -1);
    if (rl.isKeyPressed(rl.KeyboardKey.right)) moveCursor(buf.items, cursor, 1);
    if (rl.isKeyPressed(rl.KeyboardKey.home)) cursor.* = 0;
    if (rl.isKeyPressed(rl.KeyboardKey.end)) cursor.* = buf.items.len;

    var had_char = false;
    var cp = rl.getCharPressed();
    while (cp > 0) {
        had_char = true;
        if (cp < 127) try insertAt(gpa, buf, cursor, @intCast(cp), max_len);
        cp = rl.getCharPressed();
    }
    if (had_char) return;

    const shift = rl.isKeyDown(rl.KeyboardKey.left_shift) or rl.isKeyDown(rl.KeyboardKey.right_shift);
    var key = rl.getKeyPressed();
    while (key != .null) {
        if (asciiFromKey(key, shift)) |c| try insertAt(gpa, buf, cursor, c, max_len);
        key = rl.getKeyPressed();
    }
}

pub fn cursorFromClick(
    font: rl.Font,
    font_size: f32,
    text_x: f32,
    text_y: f32,
    line_h: f32,
    buf: []const u8,
    mx: i32,
    my: i32,
) usize {
    if (buf.len == 0) return 0;
    const rel_y = @as(f32, @floatFromInt(my)) - text_y;
    var target_line: usize = 0;
    if (line_h > 0 and rel_y > 0) target_line = @intCast(@divFloor(@as(i32, @intFromFloat(rel_y)), @as(i32, @intFromFloat(line_h))));
    var line_start: usize = 0;
    var line_idx: usize = 0;
    var i: usize = 0;
    while (i <= buf.len) : (i += 1) {
        const at_eol = i == buf.len or buf[i] == '\n';
        if (at_eol) {
            if (line_idx == target_line) {
                const line = buf[line_start..i];
                const rel_x = @as(f32, @floatFromInt(mx)) - text_x;
                var best: usize = 0;
                var z: [256]u8 = [_]u8{0} ** 256;
                for (line, 0..) |_, ci| {
                    const zn = @min(ci + 1, z.len - 1);
                    @memcpy(z[0..zn], line[0..zn]);
                    const w = rl.measureTextEx(font, z[0..zn :0], font_size, 1).x;
                    if (w > rel_x) break;
                    best = ci + 1;
                }
                return line_start + best;
            }
            line_idx += 1;
            line_start = i + 1;
        }
    }
    return buf.len;
}

fn asciiFromKey(key: rl.KeyboardKey, shift: bool) ?u8 {
    const ka = @intFromEnum(rl.KeyboardKey.a);
    const kz = @intFromEnum(rl.KeyboardKey.z);
    const kv = @intFromEnum(key);
    if (kv >= ka and kv <= kz) {
        const base: u8 = if (shift) 'A' else 'a';
        return base + @as(u8, @intCast(kv - ka));
    }
    const k0 = @intFromEnum(rl.KeyboardKey.zero);
    const k9 = @intFromEnum(rl.KeyboardKey.nine);
    if (kv >= k0 and kv <= k9) {
        if (shift) return switch (key) {
            .one => '!',
            .two => '@',
            .three => '#',
            .four => '$',
            .five => '%',
            .six => '^',
            .seven => '&',
            .eight => '*',
            .nine => '(',
            .zero => ')',
            else => null,
        };
        return '0' + @as(u8, @intCast(kv - k0));
    }
    return switch (key) {
        .space => ' ',
        .apostrophe => if (shift) '"' else '\'',
        .comma => if (shift) '<' else ',',
        .minus => if (shift) '_' else '-',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        .semicolon => if (shift) ':' else ';',
        .equal => if (shift) '+' else '=',
        .left_bracket => if (shift) '{' else '[',
        .right_bracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .grave => if (shift) '~' else '`',
        else => null,
    };
}
