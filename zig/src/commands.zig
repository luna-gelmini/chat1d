const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

const util = @import("util");
const crypto = @import("crypto");
const media = @import("media");
const log_mod = @import("log");
const transcript_mod = @import("transcript");
const sidebar = @import("sidebar");
const wire = @import("wire");
const events = @import("events");

pub fn appendUserFeedback(
    gpa: std.mem.Allocator,
    log: ?*std.ArrayList([]u8),
    transcript: ?*std.ArrayList(transcript_mod.TranscriptLine),
    msg: []const u8,
) !void {
    if (transcript) |tr| {
        try transcript_mod.appendTranscriptGlobal(gpa, tr, msg);
    } else if (log) |l| {
        try log_mod.appendLog(gpa, l, msg);
    } else {
        std.debug.print("{s}\n", .{msg});
    }
}

pub fn slashCmdArg(line: []const u8, cmd: []const u8) ?[]const u8 {
    return cmdArg(line, '/', cmd[1..]);
}

pub fn cmdArg(line: []const u8, prefix: u8, verb: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != prefix) return null;
    const rest = std.mem.trim(u8, line[1..], " \t");
    if (std.mem.eql(u8, rest, verb)) return "";
    if (rest.len <= verb.len or !std.mem.startsWith(u8, rest, verb)) return null;
    const sep = rest[verb.len];
    if (sep != ' ' and sep != '\t') return null;
    return std.mem.trim(u8, rest[verb.len + 1 ..], " \t");
}

fn cmdRest(line: []const u8, prefix: u8) ?[]const u8 {
    if (line.len == 0 or line[0] != prefix) return null;
    return std.mem.trim(u8, line[1..], " \t");
}

pub fn handleChatLine(
    gpa: std.mem.Allocator,
    io: Io,
    trimmed: []const u8,
    kp: *const Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: *[]u8,
    w: *Io.Writer,
    current_room: *?[]const u8,
    log: ?*std.ArrayList([]u8),
    transcript: ?*std.ArrayList(transcript_mod.TranscriptLine),
    harness: ?*wire.HarnessUi,
    cmd_prefix: u8,
) !util.ChatAction {
    if (cmd_prefix == ':' and trimmed.len > 0 and trimmed[0] == '/') {
        try appendUserFeedback(gpa, log, transcript, "TUI uses :commands (:help)");
        return .cont;
    }
    const rest_all = cmdRest(trimmed, cmd_prefix);
    if (rest_all) |r| {
        if (std.mem.eql(u8, r, "quit")) {
            try crypto.sendLine(w, "BYE\tquit");
            return .quit;
        }
        if (std.mem.eql(u8, r, "help")) {
            const msg = if (cmd_prefix == ':')
                "Enter send · Ctrl+V/:attach image · :join :nick :list :quit · blob: make blob-server"
            else
                "Type to chat. /join /nick /me /list /quit";
            try appendUserFeedback(gpa, log, transcript, msg);
            return .cont;
        }
        if (std.mem.eql(u8, r, "list")) {
            try crypto.sendLine(w, "LIST");
            return .cont;
        }
    }
    if (cmdArg(trimmed, cmd_prefix, "nick")) |nn| {
        if (nn.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /nick <name>  (TUI + /me label; HELLO client id still from --name until reconnect)");
            return .cont;
        }
        if (nn.len > 63) {
            try appendUserFeedback(gpa, log, transcript, "nick max 63 chars");
            return .cont;
        }
        gpa.free(display_nick.*);
        display_nick.* = try gpa.dupe(u8, nn);
        try appendUserFeedback(gpa, log, transcript, "nick updated");
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "roomopen")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /roomopen <room_id>  (register open room on server)");
            return .cont;
        }
        var rb: [128]u8 = undefined;
        const frame = try std.fmt.bufPrint(rb[0..], "ROOM\topen\t{s}", .{room});
        try crypto.sendLine(w, frame);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "roomprivate")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /roomprivate <room_id>  (register private room on server)");
            return .cont;
        }
        var rb: [128]u8 = undefined;
        const frame = try std.fmt.bufPrint(rb[0..], "ROOM\tprivate\t{s}", .{room});
        try crypto.sendLine(w, frame);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "join")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /join <room>  (subscribe + set current channel)");
            return .cont;
        }
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{room});
        try crypto.sendLine(w, sub);
        if (current_room.*) |cr| gpa.free(cr);
        current_room.* = try gpa.dupe(u8, room);
        if (harness) |hu| {
            const idx = try hu.sidebar.upsert(gpa, room, true);
            hu.channel_sel.* = idx;
        }
        try wire.requestRoomHistory(w, room);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "sub")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /sub <room>  (subscribe + set current channel)");
            return .cont;
        }
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{room});
        try crypto.sendLine(w, sub);
        if (current_room.*) |cr| gpa.free(cr);
        current_room.* = try gpa.dupe(u8, room);
        if (harness) |hu| {
            const idx = try hu.sidebar.upsert(gpa, room, true);
            hu.channel_sel.* = idx;
        }
        try wire.requestRoomHistory(w, room);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "part")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /part <room>");
            return .cont;
        }
        var u_buf: [256]u8 = undefined;
        const u = try std.fmt.bufPrint(u_buf[0..], "UNSUB\t{s}", .{room});
        try crypto.sendLine(w, u);
        if (harness) |hu| hu.sidebar.remove(gpa, room);
        if (current_room.*) |cr| {
            if (sidebar.RoomSidebarState.namesEqual(cr, room)) {
                gpa.free(cr);
                current_room.* = null;
            }
        }
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "unsub")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /unsub <room>");
            return .cont;
        }
        var u_buf: [256]u8 = undefined;
        const u = try std.fmt.bufPrint(u_buf[0..], "UNSUB\t{s}", .{room});
        try crypto.sendLine(w, u);
        if (harness) |hu| hu.sidebar.remove(gpa, room);
        if (current_room.*) |cr| {
            if (sidebar.RoomSidebarState.namesEqual(cr, room)) {
                gpa.free(cr);
                current_room.* = null;
            }
        }
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "room")) |room| {
        if (room.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /room <room>  (set channel without subscribing)");
            return .cont;
        }
        if (current_room.*) |cr| gpa.free(cr);
        current_room.* = try gpa.dupe(u8, room);
        if (harness) |hu| {
            const idx = try hu.sidebar.upsert(gpa, room, false);
            hu.channel_sel.* = idx;
        }
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "ping")) |nonce_tail| {
        const nonce = if (nonce_tail.len == 0) "n" else nonce_tail;
        var p_buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(p_buf[0..], "PING\t{s}", .{nonce});
        try crypto.sendLine(w, p);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "bye")) |reason_tail| {
        const reason = if (reason_tail.len == 0) "bye" else reason_tail;
        var b_buf: [256]u8 = undefined;
        const b = try std.fmt.bufPrint(b_buf[0..], "BYE\t{s}", .{reason});
        try crypto.sendLine(w, b);
        return .quit;
    }
    if (cmdArg(trimmed, cmd_prefix, "msg")) |after| {
        if (after.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: :msg <room> <text>");
            return .cont;
        }
        const sp = std.mem.indexOfAny(u8, after, " \t") orelse {
            try appendUserFeedback(gpa, log, transcript, "usage: :msg <room> <text>");
            return .cont;
        };
        const room = std.mem.trim(u8, after[0..sp], " \t");
        const text = std.mem.trim(u8, after[sp + 1 ..], " \t");
        if (text.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: :msg <room> <text>");
            return .cont;
        }
        const ts_ms = util.wallClockMs(io);
        const body_b64 = try crypto.b64urlBody(gpa, text);
        defer gpa.free(body_b64);
        const canon = try crypto.canonicalMsg(gpa, room, author_id_str, ts_ms, body_b64);
        defer gpa.free(canon);
        var mid_h: Sha256 = Sha256.init(.{});
        mid_h.update(canon);
        const mid_hex = crypto.hexLower64(mid_h.finalResult());
        const sig = try kp.sign(canon, null);
        const sig_b64 = crypto.b64urlSig(sig.toBytes());
        var m_buf: [2048]u8 = undefined;
        const frame = try std.fmt.bufPrint(
            m_buf[0..],
            "MSG\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}",
            .{ room, &mid_hex, author_id_str, ts_ms, body_b64, &sig_b64 },
        );
        try crypto.sendLine(w, frame);
        return .cont;
    }
    if (cmdArg(trimmed, cmd_prefix, "me")) |text| {
        if (text.len == 0) {
            try appendUserFeedback(gpa, log, transcript, "usage: /me <action text>");
            return .cont;
        }
        const r = current_room.* orelse {
            try appendUserFeedback(gpa, log, transcript, "select a channel first");
            return .cont;
        };
        const action = try std.fmt.allocPrint(gpa, "* {s} {s}", .{ display_nick.*, text });
        defer gpa.free(action);
        const ts_ms = util.wallClockMs(io);
        const body_b64 = try crypto.b64urlBody(gpa, action);
        defer gpa.free(body_b64);
        const canon = try crypto.canonicalMsg(gpa, r, author_id_str, ts_ms, body_b64);
        defer gpa.free(canon);
        var mid_h: Sha256 = Sha256.init(.{});
        mid_h.update(canon);
        const mid_hex = crypto.hexLower64(mid_h.finalResult());
        const sig = try kp.sign(canon, null);
        const sig_b64 = crypto.b64urlSig(sig.toBytes());
        var m_buf: [2048]u8 = undefined;
        const frame = try std.fmt.bufPrint(
            m_buf[0..],
            "MSG\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}",
            .{ r, &mid_hex, author_id_str, ts_ms, body_b64, &sig_b64 },
        );
        try crypto.sendLine(w, frame);
        return .cont;
    }
    if (trimmed.len == 0 or trimmed[0] != cmd_prefix) {
        const r = current_room.* orelse {
            try appendUserFeedback(gpa, log, transcript, "select a channel first");
            return .cont;
        };
        const ts_ms = util.wallClockMs(io);
        const body_b64 = try crypto.b64urlBody(gpa, trimmed);
        defer gpa.free(body_b64);
        const canon = try crypto.canonicalMsg(gpa, r, author_id_str, ts_ms, body_b64);
        defer gpa.free(canon);
        var mid_h: Sha256 = Sha256.init(.{});
        mid_h.update(canon);
        const mid_hex = crypto.hexLower64(mid_h.finalResult());
        const sig = try kp.sign(canon, null);
        const sig_b64 = crypto.b64urlSig(sig.toBytes());
        var m_buf: [2048]u8 = undefined;
        const frame = try std.fmt.bufPrint(
            m_buf[0..],
            "MSG\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}",
            .{ r, &mid_hex, author_id_str, ts_ms, body_b64, &sig_b64 },
        );
        try crypto.sendLine(w, frame);
        return .cont;
    }
    try appendUserFeedback(gpa, log, transcript, "unknown command");
    return .cont;
}

pub const PreparedImageAttach = struct {
    frame: []u8,
    preview_bytes: []u8,
    line: transcript_mod.TranscriptLine,
};

pub fn prepareImageAttach(
    gpa: std.mem.Allocator,
    io: Io,
    kp: *const Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    room: []const u8,
    fetch_template: []const u8,
    image_bytes: []const u8,
) !PreparedImageAttach {
    if (image_bytes.len == 0 or image_bytes.len > media.max_image_bytes) return error.ImageTooLarge;
    const mime = media.sniffImageMime(image_bytes);
    if (!media.mimeIsImage(mime)) return error.NotImage;
    const cid = media.cidHexSha256(image_bytes);
    try media.uploadBlob(gpa, io, fetch_template, &cid, image_bytes);
    const fname = media.defaultFilenameForMime(mime);
    const bl: u64 = @intCast(image_bytes.len);
    const ts_ms = util.wallClockMs(io);
    const canon = try crypto.canonicalAttach(gpa, room, author_id_str, ts_ms, &cid, bl, mime, fname);
    defer gpa.free(canon);
    var mid_h: Sha256 = Sha256.init(.{});
    mid_h.update(canon);
    const mid_hex = crypto.hexLower64(mid_h.finalResult());
    const sig = try kp.sign(canon, null);
    const sig_b64 = crypto.b64urlSig(sig.toBytes());
    const frame = try std.fmt.allocPrint(
        gpa,
        "ATTACH\t{s}\t{s}\t{s}\t{d}\t{s}\t{d}\t{s}\t{s}\t{s}",
        .{ room, &mid_hex, author_id_str, ts_ms, &cid, bl, mime, fname, &sig_b64 },
    );
    var bl_buf: [32]u8 = undefined;
    const bl_s = try std.fmt.bufPrint(&bl_buf, "{d}", .{bl});
    const line = try transcript_mod.makeAttachTranscriptLine(gpa, room, util.nickShort(display_nick), &cid, bl_s, mime, fname);
    const preview_bytes = try gpa.dupe(u8, image_bytes);
    return .{ .frame = frame, .preview_bytes = preview_bytes, .line = line };
}

pub fn tryConsumePastedImage(
    gpa: std.mem.Allocator,
    io: Io,
    pasted: []const u8,
) !?[]u8 {
    if (pasted.len >= 12 and media.mimeIsImage(media.sniffImageMime(pasted))) {
        return try gpa.dupe(u8, pasted);
    }
    const trimmed = std.mem.trim(u8, pasted, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (!media.isLikelyImagePath(trimmed)) return null;
    return media.readImageFile(gpa, io, trimmed) catch null;
}

