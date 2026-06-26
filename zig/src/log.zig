const std = @import("std");
const Io = std.Io;

pub fn appendLog(gpa: std.mem.Allocator, log: *std.ArrayList([]u8), msg: []const u8) !void {
    const owned = try gpa.dupe(u8, msg);
    errdefer gpa.free(owned);
    try log.append(gpa, owned);
    const max_lines: usize = 8000;
    while (log.items.len > max_lines) {
        const old = log.orderedRemove(0);
        gpa.free(old);
    }
}

pub fn appendLogOwned(gpa: std.mem.Allocator, log: *std.ArrayList([]u8), owned: []u8) !void {
    errdefer gpa.free(owned);
    try log.append(gpa, owned);
    const max_lines: usize = 8000;
    while (log.items.len > max_lines) {
        const old = log.orderedRemove(0);
        gpa.free(old);
    }
}

pub fn formatWireForDisplay(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (raw) |c| {
        switch (c) {
            '\t' => try list.appendSlice(gpa, " │ "),
            '\r', '\n' => {},
            0...8, 11...12, 14...31 => try list.append(gpa, '?'),
            else => try list.append(gpa, c),
        }
    }
    return try list.toOwnedSlice(gpa);
}

