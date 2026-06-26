const std = @import("std");
const sidebar = @import("sidebar");

pub const Member = struct {
    name: []const u8,
    online: bool,
};

pub fn rosterFromChannel(ch: ?*const sidebar.Channel, gpa: std.mem.Allocator, out: *std.ArrayList(Member)) !void {
    for (out.items) |m| gpa.free(m.name);
    out.clearRetainingCapacity();
    const chp = ch orelse return;
    if (chp.online_summary) |csv| try appendCsv(gpa, out, csv, true);
    if (chp.offline_summary) |csv| try appendCsv(gpa, out, csv, false);
}

fn appendCsv(gpa: std.mem.Allocator, out: *std.ArrayList(Member), csv: []const u8, online: bool) !void {
    if (csv.len == 0 or (csv.len == 1 and csv[0] == '-')) return;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        try out.append(gpa, .{ .name = try gpa.dupe(u8, name), .online = online });
    }
}

pub fn deinitList(gpa: std.mem.Allocator, list: *std.ArrayList(Member)) void {
    for (list.items) |m| gpa.free(m.name);
    list.deinit(gpa);
}
