const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const util = @import("util");
const media = @import("media");
const log = @import("log");

const libc_time = @extern(*const fn (?*anyopaque) callconv(.c) i64, .{ .name = "time" });

pub fn nowTs() i64 {
    return libc_time(null);
}

pub const TranscriptLine = union(enum) {
    global: struct { text: []u8, ts: i64 = 0 },
    room: struct { room: []u8, nick: []u8, body: []u8, ts: i64 = 0 },
    attach: struct {
        room: []u8,
        caption: []u8,
        cid_hex: []u8,
        mime: []u8,
        fname: []u8,
        preview_id: ?u32 = null,
        preview_w: u16 = 0,
        preview_h: u16 = 0,
        preview_rows: u16 = 0,
        ts: i64 = 0,
    },
};

pub fn transcriptLineDeinit(gpa: std.mem.Allocator, t: TranscriptLine) void {
    switch (t) {
        .global => |g| gpa.free(g.text),
        .room => |m| {
            gpa.free(m.room);
            gpa.free(m.nick);
            gpa.free(m.body);
        },
        .attach => |a| {
            gpa.free(a.room);
            gpa.free(a.caption);
            gpa.free(a.cid_hex);
            gpa.free(a.mime);
            gpa.free(a.fname);
        },
    }
}

pub fn freeTranscriptPreviews(vx: *vaxis.Vaxis, tty_wr: *Io.Writer, tr: *std.ArrayList(TranscriptLine)) void {
    for (tr.items) |*line| {
        if (line.* != .attach) continue;
        if (line.attach.preview_id) |id| {
            vx.freeImage(tty_wr, id);
            line.attach.preview_id = null;
        }
    }
}

pub fn attachPreviewImage(preview_id: ?u32, preview_w: u16, preview_h: u16) ?vaxis.Image {
    const id = preview_id orelse return null;
    return .{ .id = id, .width = preview_w, .height = preview_h };
}

pub fn transcriptDisplayRows(line: TranscriptLine) usize {
    return switch (line) {
        .global, .room => 1,
        .attach => |a| 1 + @as(usize, a.preview_rows),
    };
}

pub fn makeAttachTranscriptLine(
    gpa: std.mem.Allocator,
    room: []const u8,
    author_nick: []const u8,
    cid: []const u8,
    byte_len: []const u8,
    mime: []const u8,
    fname: []const u8,
) !TranscriptLine {
    const cid_short: []const u8 = if (cid.len > 12) cid[0..12] else cid;
    const extra: []const u8 = if (media.mimeIsVideo(mime))
        "  [video — open externally; in-terminal playback needs Kitty-class terminal for images only]"
    else if (!media.mimeIsImage(mime) and !std.mem.eql(u8, mime, "-"))
        "  [non-image attach]"
    else
        "";
    const caption = try std.fmt.allocPrint(
        gpa,
        "<{s}> [attach {s}… {s} B  {s}  {s}]{s}",
        .{ author_nick, cid_short, byte_len, mime, fname, extra },
    );
    errdefer gpa.free(caption);
    const room_o = try gpa.dupe(u8, room);
    errdefer gpa.free(room_o);
    const cid_o = try gpa.dupe(u8, cid);
    errdefer gpa.free(cid_o);
    const mime_o = try gpa.dupe(u8, mime);
    errdefer gpa.free(mime_o);
    const fname_o = try gpa.dupe(u8, fname);
    return .{ .attach = .{
        .room = room_o,
        .caption = caption,
        .cid_hex = cid_o,
        .mime = mime_o,
        .fname = fname_o,
        .ts = nowTs(),
    } };
}

pub fn appendTranscriptGlobal(gpa: std.mem.Allocator, tr: *std.ArrayList(TranscriptLine), msg: []const u8) !void {
    const s = try gpa.dupe(u8, msg);
    errdefer gpa.free(s);
    try tr.append(gpa, .{ .global = .{ .text = s, .ts = nowTs() } });
    const max_lines: usize = 8000;
    while (tr.items.len > max_lines) {
        const old = tr.orderedRemove(0);
        transcriptLineDeinit(gpa, old);
    }
}

pub fn appendTranscriptOwned(gpa: std.mem.Allocator, tr: *std.ArrayList(TranscriptLine), line: TranscriptLine) !void {
    try tr.append(gpa, line);
    const max_lines: usize = 8000;
    while (tr.items.len > max_lines) {
        const old = tr.orderedRemove(0);
        transcriptLineDeinit(gpa, old);
    }
}

pub fn tryAppendSentMsgEcho(
    gpa: std.mem.Allocator,
    transcript: ?*std.ArrayList(TranscriptLine),
    room: []const u8,
    nick: []const u8,
    body_text: []const u8,
) std.mem.Allocator.Error!void {
    const tr = transcript orelse return;
    const room_o = try gpa.dupe(u8, room);
    errdefer gpa.free(room_o);
    const nick_o = try gpa.dupe(u8, util.nickShort(nick));
    errdefer gpa.free(nick_o);
    const body_o = try gpa.dupe(u8, body_text);
    try appendTranscriptOwned(gpa, tr, .{ .room = .{ .room = room_o, .nick = nick_o, .body = body_o, .ts = nowTs() } });
}

pub fn decodeUrlB64Body(gpa: std.mem.Allocator, b64: []const u8) ?[]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return null;
    const buf = gpa.alloc(u8, n) catch return null;
    dec.decode(buf, b64) catch {
        gpa.free(buf);
        return null;
    };
    return buf;
}

pub fn flattenBodyForTranscript(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (body) |c| {
        if (c == '\n' or c == '\r') try list.append(gpa, ' ') else try list.append(gpa, c);
    }
    return try list.toOwnedSlice(gpa);
}

fn globalLine(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!TranscriptLine {
    const s = try gpa.dupe(u8, text);
    return .{ .global = .{ .text = s, .ts = nowTs() } };
}

pub fn decodeIncomingWire(
    gpa: std.mem.Allocator,
    raw: []const u8,
    self_author: []const u8,
    self_nick: []const u8,
) (error{SkipLine} || std.mem.Allocator.Error)!TranscriptLine {
    var it = std.mem.splitScalar(u8, raw, '\t');
    const verb = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
    if (std.mem.eql(u8, verb, "PONG")) return error.SkipLine;
    if (std.mem.eql(u8, verb, "END")) return error.SkipLine;
    if (std.mem.eql(u8, verb, "HELLO")) {
        const srv = it.next() orelse "-";
        const proto = it.next() orelse "-";
        const st = it.next() orelse "-";
        const s = try std.fmt.allocPrint(gpa, "● connected  server={s}  proto={s}  status={s}", .{ srv, proto, st });
        return .{ .global = .{ .text = s, .ts = nowTs() } };
    }
    if (std.mem.eql(u8, verb, "ERR")) {
        const code = it.next() orelse "-";
        const txt = it.next() orelse "-";
        const s = try std.fmt.allocPrint(gpa, "✖ error {s}: {s}", .{ code, txt });
        return .{ .global = .{ .text = s, .ts = nowTs() } };
    }
    if (std.mem.eql(u8, verb, "MSG")) {
        const room = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        _ = it.next();
        const author = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        _ = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        const body_b64 = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        const body_dec = decodeUrlB64Body(gpa, body_b64);
        defer if (body_dec) |b| gpa.free(b);
        const body_src: []const u8 = if (body_dec) |b| b else "<decode failed>";
        const body_flat = try flattenBodyForTranscript(gpa, body_src);
        const nick_disp: []const u8 = if (std.mem.eql(u8, author, self_author))
            util.nickShort(self_nick)
        else
            util.nickShort(author);
        const room_own = try gpa.dupe(u8, room);
        errdefer gpa.free(room_own);
        const nick_o = try gpa.dupe(u8, nick_disp);
        errdefer gpa.free(nick_o);
        return .{ .room = .{ .room = room_own, .nick = nick_o, .body = body_flat, .ts = nowTs() } };
    }
    if (std.mem.eql(u8, verb, "ATTACH")) {
        const room = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        _ = it.next();
        const author = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        _ = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        const cid = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        const bl = it.next() orelse return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
        const mime = it.next() orelse "-";
        const fname = it.next() orelse "-";
        const nick_disp: []const u8 = if (std.mem.eql(u8, author, self_author))
            util.nickShort(self_nick)
        else
            util.nickShort(author);
        if (std.mem.eql(u8, author, self_author)) return error.SkipLine;
        return makeAttachTranscriptLine(gpa, room, nick_disp, cid, bl, mime, fname);
    }
    if (std.mem.eql(u8, verb, "PING")) {
        const nonce = it.next() orelse "-";
        const s = try std.fmt.allocPrint(gpa, "↔ ping {s}", .{nonce});
        return .{ .global = .{ .text = s, .ts = nowTs() } };
    }
    return globalLine(gpa, try log.formatWireForDisplay(gpa, raw));
}
