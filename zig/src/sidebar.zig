const std = @import("std");

pub const Channel = struct {
    name: []u8,
    subscribed: bool,
    is_private: bool = false,
    online_summary: ?[]u8 = null,
    offline_summary: ?[]u8 = null,

    fn deinitOne(gpa: std.mem.Allocator, ch: Channel) void {
        gpa.free(ch.name);
        if (ch.online_summary) |s| gpa.free(s);
        if (ch.offline_summary) |s| gpa.free(s);
    }
};

pub const RoomSidebarState = struct {
    channels: std.ArrayList(Channel) = .empty,

    pub fn deinit(self: *RoomSidebarState, gpa: std.mem.Allocator) void {
        for (self.channels.items) |ch| Channel.deinitOne(gpa, ch);
        self.channels.deinit(gpa);
    }

    /// Canonical id: trim, strip one leading '#'.
    pub fn roomKey(name: []const u8) []const u8 {
        const t = std.mem.trim(u8, name, " \t");
        if (t.len > 0 and t[0] == '#') return t[1..];
        return t;
    }

    pub fn namesEqual(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, roomKey(a), roomKey(b));
    }

    pub fn find(self: *const RoomSidebarState, name: []const u8) ?usize {
        const key = roomKey(name);
        for (self.channels.items, 0..) |ch, i| {
            if (std.mem.eql(u8, roomKey(ch.name), key)) return i;
        }
        return null;
    }

    pub fn upsert(self: *RoomSidebarState, gpa: std.mem.Allocator, name: []const u8, subscribed: bool) std.mem.Allocator.Error!usize {
        const key = roomKey(name);
        if (key.len == 0) return if (self.channels.items.len > 0) self.channels.items.len - 1 else 0;
        if (self.find(key)) |i| {
            self.channels.items[i].subscribed = subscribed;
            return i;
        }
        try self.channels.append(gpa, .{ .name = try gpa.dupe(u8, key), .subscribed = subscribed });
        return self.channels.items.len - 1;
    }

    pub fn mergeServerRoster(self: *RoomSidebarState, gpa: std.mem.Allocator, name: []const u8, is_private: bool, on_csv: []const u8, off_csv: []const u8) std.mem.Allocator.Error!void {
        const key = roomKey(name);
        if (key.len == 0) return;
        if (self.find(key)) |i| {
            var ch = &self.channels.items[i];
            ch.is_private = is_private;
            if (ch.online_summary) |s| gpa.free(s);
            if (ch.offline_summary) |s| gpa.free(s);
            ch.online_summary = if (on_csv.len == 1 and on_csv[0] == '-') null else try gpa.dupe(u8, on_csv);
            ch.offline_summary = if (off_csv.len == 1 and off_csv[0] == '-') null else try gpa.dupe(u8, off_csv);
            return;
        }
        const name_d = try gpa.dupe(u8, key);
        errdefer gpa.free(name_d);
        const on_o: ?[]u8 = if (on_csv.len == 1 and on_csv[0] == '-') null else try gpa.dupe(u8, on_csv);
        errdefer if (on_o) |s| gpa.free(s);
        const off_o: ?[]u8 = if (off_csv.len == 1 and off_csv[0] == '-') null else try gpa.dupe(u8, off_csv);
        errdefer if (off_o) |s| gpa.free(s);
        try self.channels.append(gpa, .{
            .name = name_d,
            .subscribed = false,
            .is_private = is_private,
            .online_summary = on_o,
            .offline_summary = off_o,
        });
    }

    pub fn remove(self: *RoomSidebarState, gpa: std.mem.Allocator, name: []const u8) void {
        if (self.find(name)) |i| {
            const ch = self.channels.swapRemove(i);
            Channel.deinitOne(gpa, ch);
        }
    }
};

pub fn applyRoomsWire(gpa: std.mem.Allocator, side: *RoomSidebarState, payload_in: []const u8) std.mem.Allocator.Error!void {
    const payload = std.mem.trim(u8, payload_in, " \t\r\n");
    if (payload.len == 0) return;

    var incoming: std.ArrayList(Channel) = .empty;
    errdefer {
        for (incoming.items) |ch| Channel.deinitOne(gpa, ch);
        incoming.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, payload, '|');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        var parts = std.mem.splitScalar(u8, seg, ';');
        const room_name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const vis = parts.next() orelse continue;
        const on = parts.next() orelse continue;
        const off = parts.next() orelse continue;
        const key = RoomSidebarState.roomKey(room_name);
        if (key.len == 0) continue;
        const priv = (vis.len == 1 and vis[0] == 'p');

        if (findIncoming(&incoming, key)) |i| {
            const ch = &incoming.items[i];
            ch.is_private = priv;
            if (ch.online_summary) |s| gpa.free(s);
            if (ch.offline_summary) |s| gpa.free(s);
            ch.online_summary = if (on.len == 1 and on[0] == '-') null else try gpa.dupe(u8, on);
            ch.offline_summary = if (off.len == 1 and off[0] == '-') null else try gpa.dupe(u8, off);
            continue;
        }

        const name_d = try gpa.dupe(u8, key);
        errdefer gpa.free(name_d);
        const on_o: ?[]u8 = if (on.len == 1 and on[0] == '-') null else try gpa.dupe(u8, on);
        errdefer if (on_o) |s| gpa.free(s);
        const off_o: ?[]u8 = if (off.len == 1 and off[0] == '-') null else try gpa.dupe(u8, off);
        errdefer if (off_o) |s| gpa.free(s);
        try incoming.append(gpa, .{
            .name = name_d,
            .subscribed = false,
            .is_private = priv,
            .online_summary = on_o,
            .offline_summary = off_o,
        });
    }

    for (incoming.items) |*ch| {
        if (side.find(ch.name)) |old_i| {
            ch.subscribed = side.channels.items[old_i].subscribed;
        }
    }

    for (side.channels.items) |ch| Channel.deinitOne(gpa, ch);
    side.channels.clearRetainingCapacity();
    try side.channels.appendSlice(gpa, incoming.items);
    incoming.deinit(gpa);
}

fn findIncoming(list: *const std.ArrayList(Channel), key: []const u8) ?usize {
    for (list.items, 0..) |ch, i| {
        if (std.mem.eql(u8, RoomSidebarState.roomKey(ch.name), key)) return i;
    }
    return null;
}
