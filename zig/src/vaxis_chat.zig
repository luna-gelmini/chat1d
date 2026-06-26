const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const Ed25519 = std.crypto.sign.Ed25519;

const crypto = @import("crypto");
const media = @import("media");
const transcript_mod = @import("transcript");
const sidebar = @import("sidebar");
const layout = @import("layout");
const focus = @import("focus");
const members = @import("members");
const events = @import("events");
const wire = @import("wire");
const commands = @import("commands");
const tui = @import("tui");
const mouse_ui = @import("mouse_ui");

const posix = std.posix;

fn selectRoom(
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    sidebar_st: *sidebar.RoomSidebarState,
    member_list: *std.ArrayList(members.Member),
    channel_sel: usize,
    current_room: *?[]const u8,
) !void {
    try wire.selectRoom(gpa, w, sidebar_st, member_list, channel_sel, current_room);
}

fn pumpNetLines(
    gpa: std.mem.Allocator,
    net_pump: *tui.NetPump,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    harness: *wire.HarnessUi,
    author_id_str: []const u8,
    display_nick: []const u8,
    current_room: ?[]const u8,
    lay: layout.Layout,
    transcript_skip: *usize,
) !void {
    while (try net_pump.pollLine(gpa)) |ln| {
        const before = transcript.items.len;
        try wire.appendIncomingWire(gpa, transcript, ln, harness, author_id_str, display_nick);
        if (transcript.items.len > before) {
            const inner = tui.transcriptInnerRows(lay);
            transcript_skip.* = tui.stickTranscriptSkip(transcript, current_room, inner);
        }
    }
}

fn waitBootNet(
    gpa: std.mem.Allocator,
    net_pump: *tui.NetPump,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    harness: *wire.HarnessUi,
    author_id_str: []const u8,
    display_nick: []const u8,
    current_room: ?[]const u8,
    lay: layout.Layout,
    transcript_skip: *usize,
    sidebar_st: *sidebar.RoomSidebarState,
) !void {
    var idle_ticks: u32 = 0;
    while (idle_ticks < 30) : (idle_ticks += 1) {
        const before = sidebar_st.channels.items.len;
        try pumpNetLines(gpa, net_pump, transcript, harness, author_id_str, display_nick, current_room, lay, transcript_skip);
        if (sidebar_st.channels.items.len > before) return;
        var fds = [_]posix.pollfd{.{
            .fd = net_pump.stream.socket.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if ((posix.poll(fds[0..], 40) catch 0) > 0) {
            idle_ticks = 0;
            continue;
        }
    }
}

pub fn runVaxisChat(
    init: *const std.process.Init,
    gpa: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    stream: Io.net.Stream,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    name: []const u8,
    pub_b64: *const [43]u8,
    room_opt: ?[]const u8,
) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{ .system_clipboard_allocator = gpa });
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(events.UiEvent) = .init(io, &tty, &vx);
    defer loop.stop();

    var net_pump = tui.NetPump{ .stream = stream };
    defer net_pump.deinit(gpa);
    defer {
        Io.net.Stream.shutdown(&stream, io, .both) catch {};
        Io.net.Stream.close(&stream, io);
    }

    try loop.start();

    // Clear leftover Kitty/alt-screen state from a prior run (avoids escape bytes in input).
    try tty.writer().writeAll(vaxis.ctlseqs.csi_u_pop);
    try tty.writer().flush();

    try vx.enterAltScreen(tty.writer());
    try vx.setMouseMode(tty.writer(), true);
    try vx.setBracketedPaste(tty.writer(), true);
    // Skip queryTerminal: enables Kitty keyboard on VS Code; keys arrive as CSI u without text.
    {
        const winsize = try tty.getWinsize();
        try vx.resize(gpa, tty.writer(), winsize);
    }
    while (try loop.tryEvent()) |ev| {
        switch (ev) {
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            .key_press, .paste => {}, // drop startup noise (Kitty/resize dribble)
            else => {},
        }
    }
    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    const tty_wr = tty.writer();

    var text_input = vaxis.widgets.TextInput.init(gpa);
    defer text_input.deinit();
    text_input.clearRetainingCapacity();

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

    var display_nick = try gpa.dupe(u8, name);
    defer gpa.free(display_nick);

    var current_room: ?[]const u8 = null;
    defer if (current_room) |cr| gpa.free(cr);

    var transcript: std.ArrayList(transcript_mod.TranscriptLine) = .empty;
    defer {
        transcript_mod.freeTranscriptPreviews(&vx, tty_wr, &transcript);
        for (transcript.items) |t| transcript_mod.transcriptLineDeinit(gpa, t);
        transcript.deinit(gpa);
    }

    var sidebar_st: sidebar.RoomSidebarState = .{};
    defer sidebar_st.deinit(gpa);

    var channel_sel: usize = 0;
    var member_sel: usize = 0;
    var ui_focus: focus.Focus = .input;
    var members_forced = false;
    var transcript_skip: usize = 0;
    var connected: bool = true;
    var pending_ctrl_w = false;
    var cmd_mode = false;
    var member_list: std.ArrayList(members.Member) = .empty;
    defer members.deinitList(gpa, &member_list);
    const fetch_template = init.environ_map.get("CHAT1_FETCH_TEMPLATE") orelse "http://127.0.0.1:8090/%s";
    var tui_media = events.TuiMedia{
        .vx = &vx,
        .tty_wr = tty_wr,
        .loop = &loop,
        .io = io,
        .gpa = gpa,
        .fetch_template = fetch_template,
    };
    var harness = wire.HarnessUi{
        .sidebar = &sidebar_st,
        .channel_sel = &channel_sel,
        .media = &tui_media,
    };

    if (!vx.caps.kitty_graphics) {
        try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] text-only terminal (no inline images)");
    }

    var lay = layout.Layout.compute(vx.window().width, vx.window().height, members_forced);

    const paint = struct {
        fn doIt(
            vx_: *vaxis.Vaxis,
            transcript_: *const std.ArrayList(transcript_mod.TranscriptLine),
            sidebar_st_: *const sidebar.RoomSidebarState,
            member_list_: *const std.ArrayList(members.Member),
            channel_sel_: usize,
            member_sel_: usize,
            ui_focus_: focus.Focus,
            lay_: layout.Layout,
            text_input_: *vaxis.widgets.TextInput,
            host_: []const u8,
            port_: u16,
            display_nick_: []const u8,
            current_room_: ?[]const u8,
            transcript_skip_: usize,
            connected_: bool,
            cmd_mode_: bool,
            tty_wr_: *Io.Writer,
        ) !void {
            tui.redrawHarness(vx_, transcript_, sidebar_st_, member_list_, channel_sel_, member_sel_, ui_focus_, lay_, text_input_, host_, port_, display_nick_, current_room_, transcript_skip_, connected_, cmd_mode_);
            try vx_.render(tty_wr_);
            try tty_wr_.flush();
        }
    };

    try paint.doIt(&vx, &transcript, &sidebar_st, &member_list, channel_sel, member_sel, ui_focus, lay, &text_input, host, port, display_nick, current_room, transcript_skip, connected, cmd_mode, tty_wr);

    try crypto.sendLine(w, "LIST");
    try waitBootNet(gpa, &net_pump, &transcript, &harness, author_id_str, display_nick, current_room, lay, &transcript_skip, &sidebar_st);

    if (room_opt) |r| {
        current_room = try gpa.dupe(u8, r);
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{r});
        try crypto.sendLine(w, sub);
        channel_sel = try sidebar_st.upsert(gpa, r, true);
        try wire.requestRoomHistory(w, r);
    } else if (wire.defaultRoomIndex(&sidebar_st)) |idx| {
        channel_sel = idx;
        try wire.selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
    }

    try paint.doIt(&vx, &transcript, &sidebar_st, &member_list, channel_sel, member_sel, ui_focus, lay, &text_input, host, port, display_nick, current_room, transcript_skip, connected, cmd_mode, tty_wr);

    while (true) {
        try pumpNetLines(gpa, &net_pump, &transcript, &harness, author_id_str, display_nick, current_room, lay, &transcript_skip);
        if (net_pump.closed and connected) {
            connected = false;
            try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] disconnected");
        }

        var quit = false;
        while (try loop.tryEvent()) |ev| {
            switch (ev) {
            .server_line => |ln| {
                gpa.free(ln);
            },
            .server_closed => {},
            .blob_loaded => |bl| {
                defer gpa.free(bl.bytes);
                if (bl.line_idx < transcript.items.len and transcript.items[bl.line_idx] == .attach) {
                    const a = &transcript.items[bl.line_idx].attach;
                    if (a.preview_id == null) {
                        if (vx.loadImage(gpa, tty_wr, .{ .mem = bl.bytes })) |img| {
                            a.preview_id = img.id;
                            a.preview_w = img.width;
                            a.preview_h = img.height;
                            const cs = img.cellSize(vx.window()) catch vaxis.Image.CellSize{ .rows = 8, .cols = 24 };
                            a.preview_rows = @min(cs.rows, 16);
                        } else |_| {}
                    }
                }
            },
            .blob_failed => |bf| {
                if (bf.line_idx < transcript.items.len and transcript.items[bf.line_idx] == .attach) {
                    const suffix = "  (image preview fetch failed)";
                    const a = &transcript.items[bf.line_idx].attach;
                    const new_cap = std.fmt.allocPrint(gpa, "{s}{s}", .{ a.caption, suffix }) catch break;
                    gpa.free(a.caption);
                    a.caption = new_cap;
                }
            },
            .winsize => |ws| {
                try vx.resize(gpa, tty.writer(), ws);
                lay = layout.Layout.compute(vx.window().width, vx.window().height, members_forced);
            },
            .paste => |pasted| {
                defer gpa.free(@constCast(pasted));
                ui_focus = .input;
                if (try commands.tryConsumePastedImage(gpa, io, pasted)) |img| {
                    defer gpa.free(img);
                    try queueImageSend(gpa, io, &loop, &transcript, kp, author_id_str, display_nick, &current_room, fetch_template, img);
                    text_input.clearRetainingCapacity();
                } else if (media.isLikelyImagePath(std.mem.trim(u8, pasted, " \t\r\n"))) {
                    try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] paste image path with :attach <path> (bracketed binary paste needs Kitty-class terminal)");
                    try text_input.insertSliceAtCursor(pasted);
                } else {
                    try text_input.insertSliceAtCursor(pasted);
                }
            },
            .image_ready => |ir| {
                defer gpa.free(ir.frame);
                defer gpa.free(ir.preview_bytes);
                try crypto.sendLine(w, ir.frame);
                const idx = transcript.items.len;
                try transcript_mod.appendTranscriptOwned(gpa, &transcript, ir.line);
                transcript_skip = tui.stickTranscriptSkip(&transcript, current_room, tui.transcriptInnerRows(lay));
                if (transcript.items[idx] == .attach) {
                    const a = &transcript.items[idx].attach;
                    if (vx.caps.kitty_graphics and a.preview_id == null) {
                        if (vx.loadImage(gpa, tty_wr, .{ .mem = ir.preview_bytes })) |img| {
                            a.preview_id = img.id;
                            a.preview_w = img.width;
                            a.preview_h = img.height;
                            const cs = img.cellSize(vx.window()) catch vaxis.Image.CellSize{ .rows = 8, .cols = 24 };
                            a.preview_rows = @min(cs.rows, 16);
                        } else |_| {}
                    }
                }
            },
            .image_send_failed => |msg| {
                defer gpa.free(msg);
                try transcript_mod.appendTranscriptGlobal(gpa, &transcript, msg);
            },
            .mouse => |mouse| {
                switch (mouse_ui.handle(mouse, lay, &sidebar_st, &member_list)) {
                    .none => {},
                    .scroll_transcript => |delta| {
                        if (delta < 0) {
                            const d: usize = @intCast(-delta);
                            if (transcript_skip >= d) transcript_skip -= d;
                        } else {
                            transcript_skip +|= @intCast(delta);
                        }
                    },
                    .pick_room => |idx| {
                        channel_sel = idx;
                        try selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
                        ui_focus = .input;
                        transcript_skip = 0;
                    },
                    .pick_member => |idx| {
                        member_sel = idx;
                        if (member_sel < member_list.items.len) {
                            const nick = member_list.items[member_sel].name;
                            var at: [80]u8 = undefined;
                            if (std.fmt.bufPrint(at[0..], "@{s} ", .{nick})) |ins| {
                                try text_input.insertSliceAtCursor(ins);
                            } else |_| {}
                            ui_focus = .input;
                        }
                    },
                }
            },
            .key_press => |key| {
                if (pending_ctrl_w) {
                    pending_ctrl_w = false;
                    if (key.codepoint == 'h') ui_focus = focus.left(ui_focus, lay);
                    if (key.codepoint == 'l') ui_focus = focus.right(ui_focus, lay);
                } else if (key.matches('w', .{ .ctrl = true })) {
                    pending_ctrl_w = true;
                } else if (key.matches('m', .{ .ctrl = true }) or key.matches('M', .{})) {
                    members_forced = !members_forced;
                    lay = layout.Layout.compute(vx.window().width, vx.window().height, members_forced);
                } else if (ui_focus == .input and key.matches('u', .{ .ctrl = true })) {
                    transcript_skip +|= 8;
                } else if (ui_focus == .input and key.matches('d', .{ .ctrl = true })) {
                    if (transcript_skip >= 8) transcript_skip -= 8;
                } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) {
                    if (ui_focus == .rooms) {
                        if (channel_sel >= sidebar_st.channels.items.len) channel_sel = sidebar_st.channels.items.len - 1;
                        if (sidebar_st.channels.items.len > 0) {
                            try selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
                            ui_focus = .input;
                            transcript_skip = 0;
                        }
                    } else if (ui_focus == .members) {
                        if (member_list.items.len > 0) {
                            if (member_sel >= member_list.items.len) member_sel = member_list.items.len - 1;
                            const nick = member_list.items[member_sel].name;
                            var at: [80]u8 = undefined;
                            if (std.fmt.bufPrint(at[0..], "@{s} ", .{nick})) |ins| {
                                try text_input.insertSliceAtCursor(ins);
                            } else |_| {}
                            ui_focus = .input;
                        }
                    } else if (ui_focus == .input) {
                        const line_owned = text_input.toOwnedSlice() catch null;
                        if (line_owned) |line| {
                            defer gpa.free(line);
                            const trimmed = std.mem.trim(u8, line, " \t\r\n");
                            cmd_mode = false;
                            if (trimmed.len > 0) {
                                if (commands.cmdArg(trimmed, ':', "attach")) |path| {
                                    if (path.len == 0) {
                                        try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] usage: :attach /path/to/image.png");
                                    } else {
                                        const img = media.readImageFile(gpa, io, path) catch null;
                                        if (img) |bytes| {
                                            try queueImageSend(gpa, io, &loop, &transcript, kp, author_id_str, display_nick, &current_room, fetch_template, bytes);
                                            gpa.free(bytes);
                                        } else {
                                            try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] :attach could not read image file");
                                        }
                                    }
                                } else {
                                    switch (try commands.handleChatLine(gpa, io, trimmed, &kp, author_id_str, &display_nick, w, &current_room, null, &transcript, &harness, ':')) {
                                        .quit => quit = true,
                                        .cont => {},
                                    }
                                }
                                text_input.clearRetainingCapacity();
                            }
                        }
                    } else {
                        ui_focus = .input;
                    }
                } else if (key.matches('c', .{ .ctrl = true })) {
                    try crypto.sendLine(w, "BYE\tquit");
                    quit = true;
                } else if (focus.isList(ui_focus)) {
                    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                        if (ui_focus == .rooms and channel_sel + 1 < sidebar_st.channels.items.len) channel_sel += 1;
                        if (ui_focus == .members and member_sel + 1 < member_list.items.len) member_sel += 1;
                    }
                    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                        if (ui_focus == .rooms and channel_sel > 0) channel_sel -= 1;
                        if (ui_focus == .members and member_sel > 0) member_sel -= 1;
                    }
                    if (key.text != null or tui.keyHasPrintableChar(key)) {
                        ui_focus = .input;
                        try tui.applyTextInputKey(&text_input, key);
                    }
                } else if (ui_focus == .input and key.matches('v', .{ .ctrl = true })) {
                    if (try media.readClipboardImage(gpa, io, init.environ_map)) |img| {
                        try queueImageSend(gpa, io, &loop, &transcript, kp, author_id_str, display_nick, &current_room, fetch_template, img);
                        gpa.free(img);
                        text_input.clearRetainingCapacity();
                    } else {
                        try transcript_mod.appendTranscriptGlobal(
                            gpa,
                            &transcript,
                            "[sys] no clipboard image — use :attach /path.png or paste path; needs blob on :8090 (make blob-server)",
                        );
                    }
                } else if (ui_focus == .input) {
                    if (key.text) |t| {
                        if (t.len == 1 and t[0] == ':' and text_input.byteOffsetToCursor() == 0) cmd_mode = true;
                    }
                    try tui.applyTextInputKey(&text_input, key);
                }
            },
            }
            if (quit) break;
        }
        try paint.doIt(&vx, &transcript, &sidebar_st, &member_list, channel_sel, member_sel, ui_focus, lay, &text_input, host, port, display_nick, current_room, transcript_skip, connected, cmd_mode, tty_wr);
        if (quit) break;
        try loop.pollEvent();
    }
}

fn queueImageSend(
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(events.UiEvent),
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    current_room: *?[]const u8,
    fetch_template: []const u8,
    image_bytes: []const u8,
) !void {
    const room = current_room.* orelse {
        try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] select a channel first");
        return;
    };
    scheduleImageSend(gpa, io, loop, kp, author_id_str, display_nick, room, fetch_template, image_bytes);
}

const ImageSendJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(events.UiEvent),
    kp: Ed25519.KeyPair,
    author_id: []u8,
    display_nick: []u8,
    room: []u8,
    fetch_template: []u8,
    bytes: []u8,

    fn run(job: *ImageSendJob) void {
        defer {
            job.gpa.free(job.author_id);
            job.gpa.free(job.display_nick);
            job.gpa.free(job.room);
            job.gpa.free(job.fetch_template);
            job.gpa.free(job.bytes);
            job.gpa.destroy(job);
        }
        const prepared = commands.prepareImageAttach(
            job.gpa,
            job.io,
            &job.kp,
            job.author_id,
            job.display_nick,
            job.room,
            job.fetch_template,
            job.bytes,
        ) catch {
            const msg = job.gpa.dupe(u8, "[sys] image send failed — start blob: make blob-server (PUT http://127.0.0.1:8090/<cid>)") catch return;
            job.loop.postEvent(.{ .image_send_failed = msg }) catch job.gpa.free(msg);
            return;
        };
        job.loop.postEvent(.{
            .image_ready = .{
                .frame = prepared.frame,
                .preview_bytes = prepared.preview_bytes,
                .line = prepared.line,
            },
        }) catch {
            job.gpa.free(prepared.frame);
            job.gpa.free(prepared.preview_bytes);
            transcript_mod.transcriptLineDeinit(job.gpa, prepared.line);
        };
    }
};

fn scheduleImageSend(
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(events.UiEvent),
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    room: []const u8,
    fetch_template: []const u8,
    bytes: []const u8,
) void {
    const job = gpa.create(ImageSendJob) catch return;
    job.* = .{
        .gpa = gpa,
        .io = io,
        .loop = loop,
        .kp = kp,
        .author_id = gpa.dupe(u8, author_id_str) catch {
            gpa.destroy(job);
            return;
        },
        .display_nick = gpa.dupe(u8, display_nick) catch {
            gpa.free(job.author_id);
            gpa.destroy(job);
            return;
        },
        .room = gpa.dupe(u8, room) catch {
            gpa.free(job.author_id);
            gpa.free(job.display_nick);
            gpa.destroy(job);
            return;
        },
        .fetch_template = gpa.dupe(u8, fetch_template) catch {
            gpa.free(job.author_id);
            gpa.free(job.display_nick);
            gpa.free(job.room);
            gpa.destroy(job);
            return;
        },
        .bytes = gpa.dupe(u8, bytes) catch {
            gpa.free(job.author_id);
            gpa.free(job.display_nick);
            gpa.free(job.room);
            gpa.free(job.fetch_template);
            gpa.destroy(job);
            return;
        },
    };
    const th = std.Thread.spawn(.{}, ImageSendJob.run, .{job}) catch {
        gpa.free(job.author_id);
        gpa.free(job.display_nick);
        gpa.free(job.room);
        gpa.free(job.fetch_template);
        gpa.free(job.bytes);
        gpa.destroy(job);
        return;
    };
    th.detach();
}

