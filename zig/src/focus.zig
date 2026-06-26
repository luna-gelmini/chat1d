const layout = @import("layout");

pub const Focus = layout.Pane;

pub fn left(f: Focus, lay: layout.Layout) Focus {
    return switch (f) {
        .members => if (lay.show_rooms) .transcript else .input,
        .transcript => if (lay.show_rooms) .rooms else if (lay.show_servers) .servers else .input,
        .rooms => if (lay.show_servers) .servers else .input,
        .servers, .input => .input,
    };
}

pub fn right(f: Focus, lay: layout.Layout) Focus {
    return switch (f) {
        .input => if (lay.show_servers) .servers else if (lay.show_rooms) .rooms else if (lay.show_members) .members else .transcript,
        .servers => if (lay.show_rooms) .rooms else if (lay.show_members) .members else .transcript,
        .rooms => if (lay.show_members) .members else .transcript,
        .transcript => if (lay.show_members) .members else .transcript,
        .members => .members,
    };
}

pub fn isList(f: Focus) bool {
    return f == .servers or f == .rooms or f == .members;
}
