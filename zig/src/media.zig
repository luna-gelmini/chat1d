const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_image_bytes: usize = 16 * 1024 * 1024;

pub const kitty_graphics_hint =
    \\⚠ Image/video previews need a terminal with Kitty graphics (Kitty, Ghostty, WezTerm, …). Text chat works in any terminal. Set CHAT1_FETCH_TEMPLATE for blob URLs (default http://127.0.0.1:8090/%s).
;

pub const kitty_graphics_ok_hint =
    \\ℹ Kitty graphics active — image attachments can preview in-chat. Video attachments are metadata only (open externally).
;

pub fn mimeIsImage(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "image/") or
        std.mem.eql(u8, mime, "image") or
        std.ascii.eqlIgnoreCase(mime, "image/png") or
        std.ascii.eqlIgnoreCase(mime, "image/jpeg") or
        std.ascii.eqlIgnoreCase(mime, "image/gif") or
        std.ascii.eqlIgnoreCase(mime, "image/webp");
}

pub fn mimeIsVideo(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "video/");
}

pub fn cidHexSha256(bytes: []const u8) [64]u8 {
    var h: Sha256 = Sha256.init(.{});
    h.update(bytes);
    return cryptoHexLower64(h.finalResult());
}

fn cryptoHexLower64(digest: [32]u8) [64]u8 {
    const hex = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 15];
    }
    return out;
}

pub fn sniffImageMime(bytes: []const u8) []const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], "GIF87a")) return "image/gif";
    if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return "application/octet-stream";
}

pub fn defaultFilenameForMime(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "image.png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "image.jpg";
    if (std.mem.eql(u8, mime, "image/gif")) return "image.gif";
    if (std.mem.eql(u8, mime, "image/webp")) return "image.webp";
    return "image.bin";
}

pub fn isLikelyImagePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".webp");
}

pub fn readImageFile(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n\"'");
    return Io.Dir.cwd().readFileAlloc(io, trimmed, gpa, .limited(max_image_bytes));
}

pub fn readClipboardImage(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("CHAT1_CLIPBOARD_IMAGE")) |cmdline| {
        if (try readClipboardViaCommand(gpa, io, cmdline)) |b| return b;
    }
    const attempts = [_][]const []const u8{
        &.{ "wl-paste", "-t", "image/png" },
        &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
        &.{ "xclip", "-selection", "clipboard", "-t", "image/jpeg", "-o" },
    };
    for (attempts) |argv| {
        if (try readClipboardArgv(gpa, io, argv)) |b| return b;
    }
    return null;
}

fn readClipboardArgv(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !?[]u8 {
    const run = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_image_bytes),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(run.stderr);
    if (run.stdout.len < 12) {
        gpa.free(run.stdout);
        return null;
    }
    if (!mimeIsImage(sniffImageMime(run.stdout))) {
        gpa.free(run.stdout);
        return null;
    }
    return run.stdout;
}

fn readClipboardViaCommand(gpa: std.mem.Allocator, io: Io, cmdline: []const u8) !?[]u8 {
    var it = std.mem.tokenizeScalar(u8, cmdline, ' ');
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;
    while (it.next()) |tok| {
        if (argc >= argv_buf.len) return null;
        argv_buf[argc] = tok;
        argc += 1;
    }
    if (argc == 0) return null;
    return readClipboardArgv(gpa, io, argv_buf[0..argc]);
}

pub fn cidFetchUrl(gpa: std.mem.Allocator, fetch_template: []const u8, cid: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, fetch_template, "%s") orelse return std.fmt.allocPrint(gpa, "{s}{s}", .{ fetch_template, cid });
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ fetch_template[0..pos], cid, fetch_template[pos + 2 ..] });
}

pub fn httpGetLimited(gpa: std.mem.Allocator, io: Io, url: []const u8, max_bytes: usize) ![]u8 {
    if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedUrl;
    const rest = url["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadUrl;
    const host_port = rest[0..slash];
    const path = rest[slash..];
    const host, const port = if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| blk: {
        break :blk .{ host_port[0..colon], try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) };
    } else .{ host_port, @as(u16, 80) };
    const addr = try Io.net.IpAddress.parse(host, port);
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer Io.net.Stream.close(&stream, io);

    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(req_buf[0..], "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
    var wbuf: [4096]u8 = undefined;
    var nw = Io.net.Stream.writer(stream, io, &wbuf);
    try Io.Writer.writeAll(&nw.interface, req);
    try Io.Writer.flush(&nw.interface);

    var rbuf: [8192]u8 = undefined;
    var nr = Io.net.Stream.reader(stream, io, &rbuf);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    while (raw.items.len < max_bytes + 65536) {
        const n = try nr.interface.readSliceShort(rbuf[0..]);
        if (n == 0) break;
        try raw.appendSlice(gpa, rbuf[0..n]);
    }
    const hdr_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.HttpIncomplete;
    const header = raw.items[0..hdr_end];
    if (std.mem.indexOf(u8, header, "200") == null) return error.HttpStatus;
    var content_len: ?usize = null;
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    _ = lines.next();
    const cl_pfx = "Content-Length:";
    while (lines.next()) |line| {
        if (line.len >= cl_pfx.len and std.ascii.eqlIgnoreCase(line[0..cl_pfx.len], cl_pfx)) {
            const v = std.mem.trim(u8, line[cl_pfx.len..], " \t");
            content_len = std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    const to_read = @min(content_len orelse max_bytes, max_bytes);
    const body_start = hdr_end + 4;
    if (body_start >= raw.items.len) return try gpa.alloc(u8, 0);
    const avail = raw.items[body_start..];
    if (avail.len >= to_read) return try gpa.dupe(u8, avail[0..to_read]);
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(gpa, avail);
    while (body.items.len < to_read) {
        const n = try nr.interface.readSliceShort(rbuf[0..]);
        if (n == 0) break;
        const take = @min(n, to_read - body.items.len);
        try body.appendSlice(gpa, rbuf[0..take]);
    }
    return try body.toOwnedSlice(gpa);
}

pub fn httpPutBytes(gpa: std.mem.Allocator, io: Io, url: []const u8, body: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedUrl;
    const rest = url["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadUrl;
    const host_port = rest[0..slash];
    const path = rest[slash..];
    const host, const port = if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| blk: {
        break :blk .{ host_port[0..colon], try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) };
    } else .{ host_port, @as(u16, 80) };
    const addr = try Io.net.IpAddress.parse(host, port);
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer Io.net.Stream.close(&stream, io);

    var req_buf: [2048]u8 = undefined;
    const req = try std.fmt.bufPrint(
        req_buf[0..],
        "PUT {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n",
        .{ path, host, body.len },
    );
    var wbuf: [8192]u8 = undefined;
    var nw = Io.net.Stream.writer(stream, io, &wbuf);
    try Io.Writer.writeAll(&nw.interface, req);
    try Io.Writer.writeAll(&nw.interface, body);
    try Io.Writer.flush(&nw.interface);

    var rbuf: [4096]u8 = undefined;
    var nr = Io.net.Stream.reader(stream, io, &rbuf);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    while (raw.items.len < 65536) {
        const n = try nr.interface.readSliceShort(rbuf[0..]);
        if (n == 0) break;
        try raw.appendSlice(gpa, rbuf[0..n]);
    }
    const hdr_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.HttpIncomplete;
    const header = raw.items[0..hdr_end];
    if (std.mem.indexOf(u8, header, "200") != null or
        std.mem.indexOf(u8, header, "201") != null or
        std.mem.indexOf(u8, header, "204") != null)
        return;
    return error.HttpStatus;
}

pub fn uploadBlob(gpa: std.mem.Allocator, io: Io, fetch_template: []const u8, cid_hex: []const u8, bytes: []const u8) !void {
    const url = try cidFetchUrl(gpa, fetch_template, cid_hex);
    defer gpa.free(url);
    try httpPutBytes(gpa, io, url, bytes);
}
