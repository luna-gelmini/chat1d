const std = @import("std");
const vaxis = @import("vaxis");
const layout = @import("layout");
const sidebar = @import("sidebar");
const members = @import("members");

pub const Effect = union(enum) {
    none,
    pick_room: usize,
    pick_member: usize,
    scroll_transcript: isize,
};

pub fn handle(
    mouse: vaxis.Mouse,
    lay: layout.Layout,
    sidebar_st: *const sidebar.RoomSidebarState,
    member_list: *const std.ArrayList(members.Member),
) Effect {
    if (mouse.col < 0 or mouse.row < 0) return .none;
    const col: u16 = @intCast(mouse.col);
    const row: u16 = @intCast(mouse.row);

    const wheel = mouse.button == .wheel_up or mouse.button == .wheel_down;
    if (wheel and lay.transcript.contains(col, row)) {
        return .{ .scroll_transcript = if (mouse.button == .wheel_up) -4 else 4 };
    }

    if (mouse.type != .press or mouse.button != .left) return .none;

    if (lay.show_rooms and lay.rooms.contains(col, row)) {
        const inner = row -| lay.rooms.y;
        if (inner >= 1) {
            const idx: usize = inner - 1;
            if (idx < sidebar_st.channels.items.len) return .{ .pick_room = idx };
        }
    }

    if (lay.show_members and lay.members.contains(col, row)) {
        const inner = row -| lay.members.y;
        if (inner >= 1) {
            const idx: usize = inner - 1;
            if (idx < member_list.items.len) return .{ .pick_member = idx };
        }
    }

    return .none;
}
