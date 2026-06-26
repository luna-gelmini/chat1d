const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const crypto = @import("crypto");

pub fn homeDirectory(init: std.process.Init) ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => init.environ_map.get("USERPROFILE") orelse init.environ_map.get("HOME"),
        else => init.environ_map.get("HOME"),
    };
}

pub fn seedFilePath(arena: std.mem.Allocator, init: std.process.Init, identity_opt: ?[]const u8) error{ MissingHome, OutOfMemory }![]const u8 {
    if (identity_opt) |p| return p;
    const h = homeDirectory(init) orelse return error.MissingHome;
    return std.fs.path.join(arena, &.{ h, ".chat1d", "seed" });
}

pub fn loadSeedFile(io: Io, gpa: std.mem.Allocator, file_path: []const u8) !([32]u8) {
    const raw = try Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(4096));
    defer gpa.free(raw);
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 32) {
        var s: [32]u8 = undefined;
        @memcpy(&s, t[0..32]);
        return s;
    }
    if (t.len != 64) return error.BadIdentityFile;
    var s: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&s, t) catch return error.BadIdentityHex;
    return s;
}

pub fn initIdentity(io: Io, gpa: std.mem.Allocator, file_path: []const u8, force: bool) !void {
    if (!force) {
        const maybe = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (maybe) |raw| {
            defer gpa.free(raw);
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (t.len > 0) {
                std.debug.print("error: identity file already exists at \"{s}\" (use --force to overwrite)\n", .{file_path});
                std.process.exit(1);
            }
        }
    }

    const kp = Ed25519.KeyPair.generate(io);
    const seed_bytes = kp.secret_key.seed();
    const hex64 = crypto.hexLower64(seed_bytes);

    var atomic = try Io.Dir.cwd().createFileAtomic(io, file_path, .{
        .make_path = true,
        .replace = true,
        .permissions = if (builtin.os.tag == .windows) .default_file else Io.File.Permissions.fromMode(0o600),
    });
    defer atomic.deinit(io);

    var wbuf: [256]u8 = undefined;
    var fw = atomic.file.writer(io, &wbuf);
    try Io.Writer.writeAll(&fw.interface, &hex64);
    try Io.Writer.writeAll(&fw.interface, "\n");
    try fw.flush();
    try atomic.replace(io);
}

