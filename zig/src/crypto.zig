const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sendLine(w: *Io.Writer, line: []const u8) !void {
    try Io.Writer.writeAll(w, line);
    try Io.Writer.writeAll(w, "\n");
    try Io.Writer.flush(w);
}

pub fn hexLower64(digest: [32]u8) [64]u8 {
    const hex = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 15];
    }
    return out;
}

pub fn b64urlPub(pub32: [32]u8) [43]u8 {
    var buf: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&buf, &pub32);
    return buf;
}

pub fn b64urlSig(sig64: [64]u8) [86]u8 {
    var buf: [86]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&buf, &sig64);
    return buf;
}

pub fn authorIdHex(pub32: [32]u8) [64]u8 {
    var h: Sha256 = Sha256.init(.{});
    h.update(&pub32);
    return hexLower64(h.finalResult());
}

pub fn canonicalMsg(alloc: std.mem.Allocator, room: []const u8, author_hex64: []const u8, ts_ms: u64, body_b64: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "msg\n{s}\n{s}\n{d}\n{s}\n",
        .{ room, author_hex64, ts_ms, body_b64 },
    );
}

pub fn canonicalAttach(
    alloc: std.mem.Allocator,
    room: []const u8,
    author_hex64: []const u8,
    ts_ms: u64,
    cid_hex: []const u8,
    byte_len: u64,
    mime: []const u8,
    name: []const u8,
) ![]u8 {
    const m = if (mime.len == 0) "-" else mime;
    const n = if (name.len == 0) "-" else name;
    return std.fmt.allocPrint(
        alloc,
        "attach\n{s}\n{s}\n{d}\n{s}\n{d}\n{s}\n{s}\n",
        .{ room, author_hex64, ts_ms, cid_hex, byte_len, m, n },
    );
}

pub fn b64urlBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const need = enc.calcSize(text.len);
    const buf = try alloc.alloc(u8, need);
    _ = enc.encode(buf, text);
    return buf;
}

pub fn readLineStdin(alloc: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    var one: [1]u8 = undefined;
    while (true) {
        const n = try posix.read(0, &one);
        if (n == 0) {
            if (list.items.len == 0) return error.EndOfStream;
            return try list.toOwnedSlice(alloc);
        }
        if (one[0] == '\n') return try list.toOwnedSlice(alloc);
        if (one[0] != '\r') try list.append(alloc, one[0]);
    }
}

