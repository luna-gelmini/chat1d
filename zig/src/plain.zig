const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;

const util = @import("util");
const crypto = @import("crypto");
const media = @import("media");
const commands = @import("commands");

pub fn runPlainChat(
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    name: []const u8,
    pub_b64: *const [43]u8,
    room_opt: ?[]const u8,
) !void {
    const PlainRecv = struct {
        stream: Io.net.Stream,
        io: Io,
        read_buf: [8192]u8 = undefined,
        fn recvLoop(p: *@This()) void {
            var nr = Io.net.Stream.reader(p.stream, p.io, &p.read_buf);
            while (true) {
                const line = nr.interface.takeDelimiterExclusive('\n') catch break;
                if (line.len == 0) continue;
                std.debug.print("{s}\n", .{line});
            }
            std.debug.print("[server closed]\n", .{});
        }
    };
    var pr = PlainRecv{ .stream = stream, .io = io };
    const recv_thread = try std.Thread.spawn(.{}, PlainRecv.recvLoop, .{&pr});

    defer {
        Io.net.Stream.shutdown(&stream, io, .both) catch {};
        recv_thread.join();
        Io.net.Stream.close(&stream, io);
    }

    var send_wbuf: [8192]u8 = undefined;
    var net_w = Io.net.Stream.writer(stream, io, &send_wbuf);
    const w = &net_w.interface;

    {
        var hello_buf: [256]u8 = undefined;
        const hello = try std.fmt.bufPrint(
            hello_buf[0..],
            "HELLO\t{s}\t1\tnonce\t{s}",
            .{ name, pub_b64 },
        );
        try crypto.sendLine(w, hello);
    }

    var current_room: ?[]const u8 = null;
    defer if (current_room) |cr| gpa.free(cr);

    if (room_opt) |r| {
        current_room = try gpa.dupe(u8, r);
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{r});
        try crypto.sendLine(w, sub);
    }

    var display_nick = try gpa.dupe(u8, name);
    defer gpa.free(display_nick);

    std.debug.print("{s}\n", .{media.kitty_graphics_hint});
    std.debug.print("connected. type in room after /join; images: use TUI (Ctrl+V). /help\n", .{});

    while (true) {
        const prompt = current_room orelse "-";
        std.debug.print("{s}> ", .{prompt});
        const owned = crypto.readLineStdin(gpa) catch break;
        defer gpa.free(owned);
        const trimmed = std.mem.trim(u8, owned, " \t\r");
        if (trimmed.len == 0) continue;

        switch (try commands.handleChatLine(gpa, io, trimmed, &kp, author_id_str, &display_nick, w, &current_room, null, null, null, '/')) {
            .quit => break,
            .cont => {},
        }
    }
}

