const std = @import("std");
const Io = std.Io;

pub const ChatAction = enum { cont, quit };

pub fn wallClockMs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
}

pub fn nickShort(s: []const u8) []const u8 {
    return if (s.len > 12) s[0..12] else s;
}

