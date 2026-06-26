const std = @import("std");
const Io = std.Io;
const sidebar = @import("sidebar");
const tr = @import("transcript");
const events = @import("events");
const crypto = @import("crypto");
const members = @import("members");

/// Full room log replay from server (`WANT\troom\t-`).
pub fn requestRoomHistory(w: *Io.Writer, room: []const u8) !void {
    var buf: [256]u8 = undefined;
    const frame = try std.fmt.bufPrint(buf[0..], "WANT\t{s}\t-", .{room});
    try crypto.sendLine(w, frame);
}

pub fn defaultRoomIndex(sidebar_st: *const sidebar.RoomSidebarState) ?usize {
    if (sidebar_st.find("general")) |i| return i;
    if (sidebar_st.channels.items.len > 0) return 0;
    return null;
}

pub fn selectRoom(
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    sidebar_st: *sidebar.RoomSidebarState,
    member_list: *std.ArrayList(members.Member),
    channel_sel: usize,
    current_room: *?[]const u8,
) !void {
    if (channel_sel >= sidebar_st.channels.items.len) return;
    const ch = &sidebar_st.channels.items[channel_sel];
    if (current_room.*) |cr| gpa.free(cr);
    current_room.* = try gpa.dupe(u8, ch.name);
    if (!ch.subscribed) {
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{ch.name});
        try crypto.sendLine(w, sub);
        ch.subscribed = true;
    }
    try requestRoomHistory(w, ch.name);
    try members.rosterFromChannel(ch, gpa, member_list);
}

pub fn appendIncomingWire(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(tr.TranscriptLine),
    raw_owned: []u8,
    harness: ?*HarnessUi,
    self_author: []const u8,
    self_nick: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw_owned, "\r\n");
    if (std.mem.startsWith(u8, trimmed, "ROOMS\t")) {
        if (harness) |hu| {
            try sidebar.applyRoomsWire(gpa, hu.sidebar, trimmed["ROOMS\t".len..]);
        }
        gpa.free(raw_owned);
        return;
    }
    const decoded = tr.decodeIncomingWire(gpa, trimmed, self_author, self_nick) catch |err| switch (err) {
        error.SkipLine => {
            gpa.free(raw_owned);
            return;
        },
        else => |e| {
            gpa.free(raw_owned);
            return e;
        },
    };
    gpa.free(raw_owned);
    const idx = lines.items.len;
    try tr.appendTranscriptOwned(gpa, lines, decoded);
    if (decoded == .attach) {
        if (harness) |hu| {
            if (hu.media) |m| events.scheduleAttachPreviewFetch(m, lines, idx);
        }
    }
}

pub const HarnessUi = struct {
    sidebar: *sidebar.RoomSidebarState,
    channel_sel: *usize,
    media: ?*events.TuiMedia = null,
};
