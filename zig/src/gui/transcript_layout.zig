const std = @import("std");
const rl = @import("raylib");
const transcript_mod = @import("transcript");
const tui = @import("tui");

pub const TranscriptLine = transcript_mod.TranscriptLine;

/// Byte-column wrap row count (matches painter clip/wrap).
pub fn wrapRows(text: []const u8, max_cols: usize) usize {
    if (max_cols == 0) return 1;
    if (text.len == 0) return 1;
    var rows: usize = 1;
    var col: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            rows += 1;
            col = 0;
            continue;
        }
        col += 1;
        if (col > max_cols) {
            rows += 1;
            col = 1;
        }
    }
    return rows;
}

pub fn roomLineRows(nick: []const u8, body: []const u8, max_cols: usize) usize {
    if (max_cols == 0) return 1;
    var head: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(head[0..], "<{s}> ", .{nick}) catch return wrapRows(body, max_cols);
    if (prefix.len >= max_cols) return wrapRows(prefix, max_cols) + wrapRows(body, max_cols);
    var rows: usize = 1;
    var col: usize = prefix.len;
    for (body) |c| {
        if (c == '\n') {
            rows += 1;
            col = 0;
            continue;
        }
        col += 1;
        if (col > max_cols) {
            rows += 1;
            col = 1;
        }
    }
    return rows;
}

pub fn attachCaptionRows(caption: []const u8, max_cols: usize) usize {
    var cap: [160]u8 = undefined;
    const line = std.fmt.bufPrint(cap[0..], "[img] {s}", .{caption}) catch return wrapRows(caption, max_cols);
    return wrapRows(line, max_cols);
}

/// Image block row count for a loaded attach texture (caption row is separate).
/// scale = min(1, max_w_px / tex.width); rows = max(2, floor(scaled_h / cell_h) + 2).
pub fn attachImageRows(tex: ?rl.Texture2D, cell_h: i32, max_w_px: f32) u16 {
    const t = tex orelse return 0;
    if (t.width <= 0 or t.height <= 0 or cell_h <= 0) return 2;
    const scale = @min(1.0, max_w_px / @as(f32, @floatFromInt(t.width)));
    const th_px: f32 = @as(f32, @floatFromInt(t.height)) * scale;
    const used_rows: u16 = @intCast(@as(usize, @intFromFloat(th_px)) / @as(usize, @intCast(cell_h)) + 2);
    return @max(@as(u16, 2), used_rows);
}

/// Total GUI rows for one transcript line (caption + optional image block).
pub fn guiLineRows(line: TranscriptLine, tex: ?rl.Texture2D, cell_h: i32, max_w_px: f32, max_cols: usize) usize {
    return switch (line) {
        .global => |g| wrapRows(g.text, max_cols),
        .room => |m| roomLineRows(m.nick, m.body, max_cols),
        .attach => |a| attachCaptionRows(a.caption, max_cols) + @as(usize, attachImageRows(tex, cell_h, max_w_px)),
    };
}

/// Sum of `guiLineRows` over room-visible transcript entries.
pub fn visibleTotal(
    transcript: []const TranscriptLine,
    current_room: ?[]const u8,
    attach_tex: []const ?rl.Texture2D,
    cell_h: i32,
    max_w_px: f32,
    max_cols: usize,
) usize {
    var total: usize = 0;
    for (transcript, 0..) |line, idx| {
        if (!tui.visibleTranscriptLine(line, current_room)) continue;
        const tex: ?rl.Texture2D = if (idx < attach_tex.len) attach_tex[idx] else null;
        total += guiLineRows(line, tex, cell_h, max_w_px, max_cols);
    }
    return total;
}

/// Maximum scroll skip so the last `inner_h` rows stay visible.
pub fn maxSkip(visible_total: usize, inner_h: usize) usize {
    return if (visible_total > inner_h) visible_total - inner_h else 0;
}

/// Map a display row (0 = top of clipped transcript) to transcript line index.
/// Mirrors painter draw / hit-test iteration: visibility filter, skip, per-line row span.
pub fn lineIndexAtRow(
    transcript: []const TranscriptLine,
    current_room: ?[]const u8,
    attach_tex: []const ?rl.Texture2D,
    cell_h: i32,
    max_w_px: f32,
    max_cols: usize,
    inner_h: usize,
    transcript_skip: usize,
    target_row: usize,
) ?usize {
    const vtotal = visibleTotal(transcript, current_room, attach_tex, cell_h, max_w_px, max_cols);
    const skip = @min(transcript_skip, maxSkip(vtotal, inner_h));

    var passed: usize = 0;
    var dr: u16 = 0;

    for (transcript, 0..) |line, idx| {
        if (!tui.visibleTranscriptLine(line, current_room)) continue;

        const tex: ?rl.Texture2D = if (idx < attach_tex.len) attach_tex[idx] else null;
        const rows = guiLineRows(line, tex, cell_h, max_w_px, max_cols);
        if (passed + rows <= skip) {
            passed += rows;
            continue;
        }

        const line_start: u16 = dr;
        const line_end: u16 = dr + @as(u16, @intCast(rows));
        dr = line_end;

        if (target_row >= line_start and target_row < line_end) return idx;

        passed += rows;
        if (dr >= inner_h) break;
    }
    return null;
}

test "attachImageRows min 2" {
    const tex = rl.Texture2D{ .id = 1, .width = 100, .height = 10, .format = 7 };
    try std.testing.expectEqual(@as(u16, 2), attachImageRows(tex, 20, 200));
}

test "guiLineRows attach with texture" {
    const tex = rl.Texture2D{ .id = 1, .width = 100, .height = 40, .format = 7 };
    const line = TranscriptLine{ .attach = .{
        .room = "r",
        .caption = "c",
        .cid_hex = "x",
        .mime = "image/png",
        .fname = "f",
    } };
    try std.testing.expectEqual(@as(usize, 4), guiLineRows(line, tex, 20, 200, 80));
}

test "wrapRows long line" {
    const text = "abcdefghijklmnopqrstuvwxyz";
    try std.testing.expectEqual(@as(usize, 2), wrapRows(text, 20));
}

test "visibleTotal counts only current room" {
    const lines = [_]TranscriptLine{
        .{ .global = .{ .text = "sys", .ts = 0 } },
        .{ .room = .{ .room = "a", .nick = "n", .body = "hi" } },
        .{ .room = .{ .room = "b", .nick = "n", .body = "no" } },
    };
    try std.testing.expectEqual(@as(usize, 2), visibleTotal(&lines, "a", &.{}, 20, 200, 80));
}

test "lineIndexAtRow" {
    const lines = [_]TranscriptLine{
        .{ .global = .{ .text = "one", .ts = 0 } },
        .{ .global = .{ .text = "two", .ts = 0 } },
    };
    try std.testing.expectEqual(@as(?usize, 0), lineIndexAtRow(&lines, null, &.{}, 20, 200, 80, 10, 0, 0));
    try std.testing.expectEqual(@as(?usize, 1), lineIndexAtRow(&lines, null, &.{}, 20, 200, 80, 10, 0, 1));
}
