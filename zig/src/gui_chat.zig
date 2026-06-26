const std = @import("std");
const Io = std.Io;
const rl = @import("raylib");
const Ed25519 = std.crypto.sign.Ed25519;
const posix = std.posix;

const crypto = @import("crypto");
const media = @import("media");
const transcript_mod = @import("transcript");
const sidebar = @import("sidebar");
const layout = @import("layout");
const focus = @import("focus");
const members = @import("members");
const wire = @import("wire");
const commands = @import("commands");
const tui = @import("tui");
const painter_mod = @import("gui/painter");
const font_mod = @import("gui/font");
const start_screen = @import("gui/start_screen");
const gui_input = @import("gui/input");
const chrome = @import("gui/chrome");
const context_menu = @import("gui/context_menu");
const transcript_layout = @import("gui/transcript_layout");
const blob_fetch = @import("gui/blob_fetch");

const ImageReady = struct {
    frame: []u8,
    preview_bytes: []u8,
    line: transcript_mod.TranscriptLine,
};

const PendingGui = struct {
    mutex: std.atomic.Mutex = .unlocked,
    ready: std.ArrayList(ImageReady) = .empty,
    failed: std.ArrayList([]u8) = .empty,

    fn deinit(self: *PendingGui, gpa: std.mem.Allocator) void {
        for (self.ready.items) |ir| {
            gpa.free(ir.frame);
            gpa.free(ir.preview_bytes);
            transcript_mod.transcriptLineDeinit(gpa, ir.line);
        }
        self.ready.deinit(gpa);
        for (self.failed.items) |m| gpa.free(m);
        self.failed.deinit(gpa);
    }

    fn drain(self: *PendingGui, gpa: std.mem.Allocator) !struct { ready: []ImageReady, failed: [][]u8 } {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        const r = try self.ready.toOwnedSlice(gpa);
        const f = try self.failed.toOwnedSlice(gpa);
        self.ready = .empty;
        self.failed = .empty;
        return .{ .ready = r, .failed = f };
    }
};

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

fn guiMaxSkip(
    p: *const painter_mod.Painter,
    transcript: *const std.ArrayList(transcript_mod.TranscriptLine),
    attach_tex: *const std.ArrayList(?rl.Texture2D),
    current_room: ?[]const u8,
    lay: layout.Layout,
) usize {
    const inner_h = tui.transcriptInnerRows(lay);
    const max_cols = p.transcriptCols(lay);
    const total = transcript_layout.visibleTotal(transcript.items, current_room, attach_tex.items, p.cell_h, p.transcriptMaxW(lay), max_cols);
    return transcript_layout.maxSkip(total, inner_h);
}

fn guiAtBottom(transcript_skip: usize, max_skip: usize) bool {
    return transcript_skip >= max_skip;
}

fn pumpNet(
    gpa: std.mem.Allocator,
    net_pump: *tui.NetPump,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    harness: *wire.HarnessUi,
    author_id_str: []const u8,
    display_nick: []const u8,
    current_room: ?[]const u8,
    lay: layout.Layout,
    transcript_skip: *usize,
    p: *const painter_mod.Painter,
    attach_tex: *const std.ArrayList(?rl.Texture2D),
) !void {
    const max_skip = guiMaxSkip(p, transcript, attach_tex, current_room, lay);
    const at_bottom = guiAtBottom(transcript_skip.*, max_skip);
    while (try net_pump.pollLine(gpa)) |ln| {
        const before = transcript.items.len;
        try wire.appendIncomingWire(gpa, transcript, ln, harness, author_id_str, display_nick);
        if (transcript.items.len > before and at_bottom) {
            transcript_skip.* = guiMaxSkip(p, transcript, attach_tex, current_room, lay);
        }
    }
}

fn extForMime(mime: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, mime, "image/jpeg")) return ".jpg";
    if (std.mem.eql(u8, mime, "image/gif")) return ".gif";
    if (std.mem.eql(u8, mime, "image/webp")) return ".webp";
    return ".png";
}

fn loadTextureFromBytes(bytes: []const u8, mime: []const u8) ?rl.Texture2D {
    const ext = extForMime(mime);
    const img = rl.loadImageFromMemory(ext, bytes) catch return null;
    defer rl.unloadImage(img);
    return rl.loadTextureFromImage(img) catch return null;
}

fn ensureAttachSlots(
    gpa: std.mem.Allocator,
    attach_tex: *std.ArrayList(?rl.Texture2D),
    attach_fetching: *std.ArrayList(bool),
    len: usize,
) !void {
    while (attach_tex.items.len < len) try attach_tex.append(gpa, null);
    while (attach_fetching.items.len < len) try attach_fetching.append(gpa, false);
}

fn scheduleAttachFetches(
    gpa: std.mem.Allocator,
    io: Io,
    blob_pending: *blob_fetch.GuiBlobPending,
    fetch_template: []const u8,
    transcript: *const std.ArrayList(transcript_mod.TranscriptLine),
    attach_tex: *std.ArrayList(?rl.Texture2D),
    attach_fetching: *std.ArrayList(bool),
) void {
    ensureAttachSlots(gpa, attach_tex, attach_fetching, transcript.items.len) catch return;
    for (transcript.items, 0..) |line, i| {
        if (line != .attach) continue;
        if (attach_tex.items[i] != null) continue;
        if (attach_fetching.items[i]) continue;
        attach_fetching.items[i] = true;
        const a = line.attach;
        blob_pending.schedule(gpa, io, fetch_template, i, a.cid_hex, a.mime);
    }
}

fn drainAttachFetches(
    gpa: std.mem.Allocator,
    blob_pending: *blob_fetch.GuiBlobPending,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    attach_tex: *std.ArrayList(?rl.Texture2D),
    attach_fetching: *std.ArrayList(bool),
) !void {
    const results = try blob_pending.drain(gpa);
    defer gpa.free(results);
    for (results) |r| {
        switch (r) {
            .loaded => |l| {
                if (l.line_idx < attach_tex.items.len) {
                    attach_tex.items[l.line_idx] = loadTextureFromBytes(l.bytes, l.mime_owned);
                }
                gpa.free(l.bytes);
                gpa.free(l.mime_owned);
            },
            .failed => |f| {
                if (f.line_idx < attach_fetching.items.len) attach_fetching.items[f.line_idx] = false;
                try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] attach preview failed — run: make blob-server");
            },
        }
    }
}

const ImageJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    pending: *PendingGui,
    kp: Ed25519.KeyPair,
    author_id: []u8,
    display_nick: []u8,
    room: []u8,
    fetch_template: []u8,
    bytes: []u8,

    fn run(job: *ImageJob) void {
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
            const msg = job.gpa.dupe(u8, "[sys] image send failed — run: make blob-server") catch return;
            while (!job.pending.mutex.tryLock()) {}
            defer job.pending.mutex.unlock();
            job.pending.failed.append(job.gpa, msg) catch job.gpa.free(msg);
            return;
        };
        while (!job.pending.mutex.tryLock()) {}
        defer job.pending.mutex.unlock();
        job.pending.ready.append(job.gpa, .{
            .frame = prepared.frame,
            .preview_bytes = prepared.preview_bytes,
            .line = prepared.line,
        }) catch {
            job.gpa.free(prepared.frame);
            job.gpa.free(prepared.preview_bytes);
            transcript_mod.transcriptLineDeinit(job.gpa, prepared.line);
        };
    }
};

fn scheduleImage(
    gpa: std.mem.Allocator,
    io: Io,
    pending: *PendingGui,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    room: []const u8,
    fetch_template: []const u8,
    image_bytes: []const u8,
) void {
    const job = gpa.create(ImageJob) catch return;
    job.* = .{
        .gpa = gpa,
        .io = io,
        .pending = pending,
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
        .bytes = gpa.dupe(u8, image_bytes) catch {
            gpa.free(job.author_id);
            gpa.free(job.display_nick);
            gpa.free(job.room);
            gpa.free(job.fetch_template);
            gpa.destroy(job);
            return;
        },
    };
    const th = std.Thread.spawn(.{}, ImageJob.run, .{job}) catch {
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

fn queueImage(
    gpa: std.mem.Allocator,
    io: Io,
    pending: *PendingGui,
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
    scheduleImage(gpa, io, pending, kp, author_id_str, display_nick, room, fetch_template, image_bytes);
}

fn sendBye(w: *Io.Writer, sent: *bool) void {
    if (sent.*) return;
    crypto.sendLine(w, "BYE\tquit") catch {};
    sent.* = true;
}

fn freeTextures(attach_tex: *std.ArrayList(?rl.Texture2D)) void {
    for (attach_tex.items) |*opt| {
        if (opt.*) |tex| rl.unloadTexture(tex);
        opt.* = null;
    }
}

pub fn runGui(
    init: *const std.process.Init,
    gpa: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    initial_name: []const u8,
    name_from_cli: bool,
    pub_b64: *const [43]u8,
    room_opt: ?[]const u8,
) !void {
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(1280, 720, "chat1");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const loaded = font_mod.loadGuiFonts(16);
    defer if (loaded.owned_chat) rl.unloadFont(loaded.chat);

    var name_owned: ?[]u8 = null;
    defer if (name_owned) |n| gpa.free(n);

    const nick: []const u8 = if (name_from_cli) initial_name else blk: {
        name_owned = try start_screen.run(gpa, loaded.chat, 16, initial_name) orelse return;
        break :blk name_owned.?;
    };

    const address = try Io.net.IpAddress.parse(host, port);
    const stream = Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => {
            std.debug.print("error: connection refused to {s}:{d}\n", .{ host, port });
            return;
        },
        else => |e| return e,
    };

    try runGuiChat(init, gpa, io, host, port, stream, kp, author_id_str, nick, pub_b64, room_opt, loaded.chat, loaded.ui);
}

fn handleChromeAction(
    gpa: std.mem.Allocator,
    act: chrome.Action,
    host: []const u8,
    port: u16,
    connected: bool,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    transcript_skip: *usize,
    toolbar_sel: *painter_mod.ToolbarSel,
) !bool {
    switch (act) {
        .none, .menu_file, .menu_edit, .menu_view, .menu_tools, .menu_help => {},
        .win_close => return true,
        .win_minimize => rl.minimizeWindow(),
        .win_maximize => rl.toggleFullscreen(),
        .tool_server => {
            toolbar_sel.* = .server;
            var msg: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(msg[0..], "[sys] server {s}:{d} · {s}", .{ host, port, if (connected) "connected" else "offline" });
            try transcript_mod.appendTranscriptGlobal(gpa, transcript, line);
        },
        .tool_logs => {
            toolbar_sel.* = .logs;
            transcript_skip.* = 0;
            try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] logs — scrolled to top");
        },
        .tool_settings => {
            toolbar_sel.* = .settings;
            try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] settings — use :help for commands");
        },
    }
    return false;
}

fn chromeMenuKind(act: chrome.Action) ?context_menu.Kind {
    return switch (act) {
        .menu_file => .file,
        .menu_edit => .edit,
        .menu_view => .view,
        .menu_tools => .tools,
        .menu_help => .help,
        else => null,
    };
}

fn menubarHighlight(menu: *const context_menu.State) ?context_menu.Kind {
    if (!menu.open) return null;
    return switch (menu.kind) {
        .file, .edit, .view, .tools, .help => menu.kind,
        else => null,
    };
}

fn pasteFromClipboard(
    gpa: std.mem.Allocator,
    io: Io,
    input: *std.ArrayList(u8),
    pending: *PendingGui,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    current_room: *?[]const u8,
    fetch_template: []const u8,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
) !void {
    const clip = rl.getClipboardText();
    if (clip.len >= 12 and media.mimeIsImage(media.sniffImageMime(clip))) {
        try queueImage(gpa, io, pending, transcript, kp, author_id_str, display_nick, current_room, fetch_template, clip);
    } else if (media.isLikelyImagePath(std.mem.trim(u8, clip, " \t\r\n"))) {
        const path = std.mem.trim(u8, clip, " \t\r\n");
        if (media.readImageFile(gpa, io, path)) |bytes| {
            defer gpa.free(bytes);
            try queueImage(gpa, io, pending, transcript, kp, author_id_str, display_nick, current_room, fetch_template, bytes);
        } else |_| {}
    } else if (clip.len > 0) {
        const trimmed = std.mem.trim(u8, clip, " \t\r\n");
        if (trimmed.len > 0 and input.items.len + trimmed.len <= 512) {
            try input.appendSlice(gpa, trimmed);
        }
    }
}

fn copyTranscriptSelection(
    gpa: std.mem.Allocator,
    transcript: []const transcript_mod.TranscriptLine,
    from: usize,
    to: usize,
) !void {
    if (from > to or to >= transcript.len) return;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (transcript[from .. to + 1]) |line| {
        const text = try formatTranscriptLine(gpa, line);
        defer gpa.free(text);
        try list.appendSlice(gpa, text);
        try list.append(gpa, '\n');
    }
    if (list.items.len == 0) return;
    var z: [8192]u8 = undefined;
    const n = @min(list.items.len, z.len - 1);
    @memcpy(z[0..n], list.items[0..n]);
    z[n] = 0;
    rl.setClipboardText(z[0..n :0]);
}

fn inputPromptPrefix(cmd_mode: bool, current_room: ?[]const u8, prompt: *[80]u8) [:0]const u8 {
    if (cmd_mode) {
        const t = std.fmt.bufPrint(prompt[0..], ">:", .{}) catch return ">";
        prompt[t.len] = 0;
        return prompt[0..t.len :0];
    }
    if (current_room) |room| {
        const t = std.fmt.bufPrint(prompt[0..], "> #{s} ", .{room}) catch return "> ";
        prompt[t.len] = 0;
        return prompt[0..t.len :0];
    }
    const t = std.fmt.bufPrint(prompt[0..], "> ", .{}) catch return ">";
    prompt[t.len] = 0;
    return prompt[0..t.len :0];
}

fn nickFromAttachCaption(caption: []const u8) ?[]const u8 {
    if (caption.len < 3 or caption[0] != '<') return null;
    const end = std.mem.indexOfScalar(u8, caption, '>') orelse return null;
    if (end <= 1) return null;
    return caption[1..end];
}

fn submitInputLines(
    gpa: std.mem.Allocator,
    io: Io,
    input: *std.ArrayList(u8),
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: *[]u8,
    w: *Io.Writer,
    current_room: *?[]const u8,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    harness: *wire.HarnessUi,
    pending: *PendingGui,
    fetch_template: []const u8,
) !void {
    if (input.items.len == 0) return;
    if (input.items[0] == ':') {
        const trimmed = std.mem.trim(u8, input.items, " \t\r\n");
        if (trimmed.len == 0) return;
        if (commands.cmdArg(trimmed, ':', "attach")) |path| {
            if (path.len == 0) {
                try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] usage: :attach /path/to/image.png");
            } else if (media.readImageFile(gpa, io, path)) |bytes| {
                defer gpa.free(bytes);
                try queueImage(gpa, io, pending, transcript, kp, author_id_str, display_nick.*, current_room, fetch_template, bytes);
            } else |_| {
                try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] :attach could not read file");
            }
        } else {
            _ = try commands.handleChatLine(gpa, io, trimmed, &kp, author_id_str, display_nick, w, current_room, null, transcript, harness, ':');
        }
        return;
    }
    var lines = std.mem.splitScalar(u8, input.items, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        _ = try commands.handleChatLine(gpa, io, trimmed, &kp, author_id_str, display_nick, w, current_room, null, transcript, harness, ':');
    }
}

fn toggleMenubarFromKind(p: *const painter_mod.Painter, ctx_menu: *context_menu.State, kind: context_menu.Kind, vp: rl.Rectangle) void {
    const act: chrome.Action = switch (kind) {
        .file => .menu_file,
        .edit => .menu_edit,
        .view => .menu_view,
        .tools => .menu_tools,
        .help => .menu_help,
        else => return,
    };
    if (p.menuAnchor(act)) |anchor| {
        _ = ctx_menu.toggleMenubar(anchor, kind, vp);
    }
}

fn formatTranscriptLine(gpa: std.mem.Allocator, line: transcript_mod.TranscriptLine) ![]u8 {
    switch (line) {
        .global => |g| return try gpa.dupe(u8, g.text),
        .room => |m| {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(gpa);
            try list.appendSlice(gpa, "<");
            try list.appendSlice(gpa, m.nick);
            try list.appendSlice(gpa, "> ");
            try list.appendSlice(gpa, m.body);
            return try list.toOwnedSlice(gpa);
        },
        .attach => |a| {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(gpa);
            try list.appendSlice(gpa, "[img] ");
            try list.appendSlice(gpa, a.caption);
            return try list.toOwnedSlice(gpa);
        },
    }
}

fn deleteTranscriptLine(
    gpa: std.mem.Allocator,
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    attach_tex: *std.ArrayList(?rl.Texture),
    idx: usize,
) void {
    if (idx >= transcript.items.len) return;
    transcript_mod.transcriptLineDeinit(gpa, transcript.items[idx]);
    _ = transcript.orderedRemove(idx);
    if (idx < attach_tex.items.len) {
        if (attach_tex.items[idx]) |t| rl.unloadTexture(t);
        _ = attach_tex.orderedRemove(idx);
    }
}

fn setClipboardFromLine(gpa: std.mem.Allocator, line: transcript_mod.TranscriptLine) !void {
    const text = try formatTranscriptLine(gpa, line);
    defer gpa.free(text);
    var z: [4096]u8 = undefined;
    const n = @min(text.len, z.len - 1);
    @memcpy(z[0..n], text[0..n]);
    z[n] = 0;
    rl.setClipboardText(z[0..n :0]);
}

fn handleMenuPick(
    gpa: std.mem.Allocator,
    io: Io,
    menu: *const context_menu.State,
    pick: context_menu.Pick,
    input: *std.ArrayList(u8),
    transcript: *std.ArrayList(transcript_mod.TranscriptLine),
    attach_tex: *std.ArrayList(?rl.Texture),
    member_list: *const std.ArrayList(members.Member),
    sidebar_st: *sidebar.RoomSidebarState,
    current_room: *?[]const u8,
    transcript_skip: *usize,
    members_forced: *bool,
    pending: *PendingGui,
    kp: Ed25519.KeyPair,
    author_id_str: []const u8,
    display_nick: []const u8,
    fetch_template: []const u8,
    w: *Io.Writer,
    bye_sent: *bool,
    ui_focus: *focus.Focus,
) !bool {
    switch (pick) {
        .none, .outside => return false,
        .reply => {
            if (menu.target_idx >= transcript.items.len) return false;
            switch (transcript.items[menu.target_idx]) {
                .room => |m| {
                    var at: [80]u8 = undefined;
                    if (std.fmt.bufPrint(at[0..], "@{s} ", .{m.nick})) |ins| {
                        try input.appendSlice(gpa, ins);
                    } else |_| {}
                },
                .attach => |a| {
                    if (nickFromAttachCaption(a.caption)) |nick| {
                        var at: [80]u8 = undefined;
                        if (std.fmt.bufPrint(at[0..], "@{s} ", .{nick})) |ins| {
                            try input.appendSlice(gpa, ins);
                        } else |_| {}
                    } else {
                        var at: [160]u8 = undefined;
                        if (std.fmt.bufPrint(at[0..], "re: {s} ", .{a.caption})) |ins| {
                            try input.appendSlice(gpa, ins);
                        } else |_| {}
                    }
                },
                .global => |g| {
                    var q: [512]u8 = undefined;
                    if (std.fmt.bufPrint(q[0..], "> {s} ", .{g.text})) |ins| {
                        try input.appendSlice(gpa, ins);
                    } else |_| {}
                },
            }
            ui_focus.* = .input;
        },
        .copy => switch (menu.kind) {
            .transcript => {
                if (menu.target_idx < transcript.items.len) {
                    try setClipboardFromLine(gpa, transcript.items[menu.target_idx]);
                }
            },
            .member => {
                if (menu.target_idx < member_list.items.len) {
                    const name = member_list.items[menu.target_idx].name;
                    var z: [128]u8 = undefined;
                    const n = @min(name.len, z.len - 1);
                    @memcpy(z[0..n], name[0..n]);
                    z[n] = 0;
                    rl.setClipboardText(z[0..n :0]);
                }
            },
            else => {},
        },
        .delete => deleteTranscriptLine(gpa, transcript, attach_tex, menu.target_idx),
        .mention => {
            if (menu.target_idx < member_list.items.len) {
                var at: [80]u8 = undefined;
                const m = member_list.items[menu.target_idx].name;
                if (std.fmt.bufPrint(at[0..], "@{s} ", .{m})) |ins| {
                    try input.appendSlice(gpa, ins);
                } else |_| {}
            }
        },
        .part => {
            if (menu.target_idx < sidebar_st.channels.items.len) {
                const ch = sidebar_st.channels.items[menu.target_idx];
                var u_buf: [128]u8 = undefined;
                const u = try std.fmt.bufPrint(u_buf[0..], "UNSUB\t{s}", .{ch.name});
                try crypto.sendLine(w, u);
                if (current_room.*) |cr| {
                    if (sidebar.RoomSidebarState.namesEqual(cr, ch.name)) {
                        gpa.free(cr);
                        current_room.* = null;
                    }
                }
                var msg: [96]u8 = undefined;
                const line = try std.fmt.bufPrint(msg[0..], "[sys] parted #{s}", .{ch.name});
                try transcript_mod.appendTranscriptGlobal(gpa, transcript, line);
            }
        },
        .quit => {
            sendBye(w, bye_sent);
            return true;
        },
        .join_channel => {
            try input.appendSlice(gpa, ":join ");
            ui_focus.* = .input;
        },
        .clear_input => input.clearRetainingCapacity(),
        .paste_input => try pasteFromClipboard(gpa, io, input, pending, kp, author_id_str, display_nick, current_room, fetch_template, transcript),
        .toggle_members => members_forced.* = !members_forced.*,
        .scroll_top => transcript_skip.* = 0,
        .refresh_rooms => try crypto.sendLine(w, "LIST"),
        .show_help => try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] :help :join :part :attach · scroll · Ctrl+V paste"),
        .about => try transcript_mod.appendTranscriptGlobal(gpa, transcript, "[sys] chat1d native client — zig + raylib"),
    }
    return false;
}

fn runGuiChat(
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
    mono_font: rl.Font,
    ui_font: rl.Font,
) !void {
    var p = painter_mod.Painter.init(mono_font, ui_font, 16);

    var net_pump = tui.NetPump{ .stream = stream };
    defer net_pump.deinit(gpa);
    defer {
        Io.net.Stream.shutdown(&stream, io, .both) catch {};
        Io.net.Stream.close(&stream, io);
    }

    var send_wbuf: [8192]u8 = undefined;
    var net_w = Io.net.Stream.writer(stream, io, &send_wbuf);
    const w = &net_w.interface;

    {
        var hello_buf: [256]u8 = undefined;
        const hello = try std.fmt.bufPrint(hello_buf[0..], "HELLO\t{s}\t1\tnonce\t{s}", .{ name, pub_b64 });
        try crypto.sendLine(w, hello);
    }

    var display_nick = try gpa.dupe(u8, name);
    defer gpa.free(display_nick);

    var current_room: ?[]const u8 = null;
    defer if (current_room) |cr| gpa.free(cr);

    var transcript: std.ArrayList(transcript_mod.TranscriptLine) = .empty;
    defer {
        for (transcript.items) |t| transcript_mod.transcriptLineDeinit(gpa, t);
        transcript.deinit(gpa);
    }

    var attach_tex: std.ArrayList(?rl.Texture2D) = .empty;
    defer {
        freeTextures(&attach_tex);
        attach_tex.deinit(gpa);
    }

    var attach_fetching: std.ArrayList(bool) = .empty;
    defer attach_fetching.deinit(gpa);

    var blob_pending: blob_fetch.GuiBlobPending = .{};
    defer blob_pending.deinit(gpa);

    var sidebar_st: sidebar.RoomSidebarState = .{};
    defer sidebar_st.deinit(gpa);

    var channel_sel: usize = 0;
    var member_sel: usize = 0;
    var ui_focus: focus.Focus = .input;
    var members_forced = false;
    var toolbar_sel: painter_mod.ToolbarSel = .server;
    var ctx_menu: context_menu.State = .{};
    var transcript_skip: usize = 0;
    var connected = true;
    var cmd_mode = false;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    var input_cursor: usize = 0;

    var sel_anchor: ?usize = null;
    var sel_to: ?usize = null;

    var member_list: std.ArrayList(members.Member) = .empty;
    defer members.deinitList(gpa, &member_list);

    const fetch_template = init.environ_map.get("CHAT1_FETCH_TEMPLATE") orelse "http://127.0.0.1:8090/%s";
    var harness = wire.HarnessUi{
        .sidebar = &sidebar_st,
        .channel_sel = &channel_sel,
        .media = null,
    };

    try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] GUI client - inline image previews enabled");

    var lay = layout.Layout.computeGui(120, 40, members_forced);

    try crypto.sendLine(w, "LIST");
    var boot: u32 = 0;
    while (boot < 30) : (boot += 1) {
        const before = sidebar_st.channels.items.len;
        try pumpNet(gpa, &net_pump, &transcript, &harness, author_id_str, display_nick, current_room, lay, &transcript_skip, &p, &attach_tex);
        if (sidebar_st.channels.items.len > before) break;
        var fds = [_]posix.pollfd{.{
            .fd = net_pump.stream.socket.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if ((posix.poll(fds[0..], 40) catch 0) > 0) boot = 0;
    }

    if (room_opt) |r| {
        current_room = try gpa.dupe(u8, r);
        var sub_buf: [256]u8 = undefined;
        try crypto.sendLine(w, try std.fmt.bufPrint(sub_buf[0..], "SUB\t{s}", .{r}));
        channel_sel = try sidebar_st.upsert(gpa, r, true);
        try wire.requestRoomHistory(w, r);
    } else if (wire.defaultRoomIndex(&sidebar_st)) |idx| {
        channel_sel = idx;
        try wire.selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
    }

    var pending: PendingGui = .{};
    defer pending.deinit(gpa);

    var frame: u32 = 0;
    var bye_sent = false;
    var pending_ctrl_w = false;
    var scroll_grab_dy: ?f32 = null;
    while (!rl.windowShouldClose()) {
        frame +%= 1;
        const ww: i32 = rl.getScreenWidth();
        const wh: i32 = rl.getScreenHeight();
        const grid = p.colsRows(ww, wh);
        lay = layout.Layout.computeGui(grid.cols, grid.rows, members_forced);

        try pumpNet(gpa, &net_pump, &transcript, &harness, author_id_str, display_nick, current_room, lay, &transcript_skip, &p, &attach_tex);
        if (net_pump.closed and connected) {
            connected = false;
            try transcript_mod.appendTranscriptGlobal(gpa, &transcript, "[sys] disconnected");
        }

        const drained = try pending.drain(gpa);
        defer {
            gpa.free(drained.ready);
            for (drained.failed) |m| gpa.free(m);
            gpa.free(drained.failed);
        }
        for (drained.failed) |msg| try transcript_mod.appendTranscriptGlobal(gpa, &transcript, msg);
        for (drained.ready) |ir| {
            const mime = ir.line.attach.mime;
            try crypto.sendLine(w, ir.frame);
            gpa.free(ir.frame);
            const preview = ir.preview_bytes;
            const idx = transcript.items.len;
            try transcript_mod.appendTranscriptOwned(gpa, &transcript, ir.line);
            const max_skip = guiMaxSkip(&p, &transcript, &attach_tex, current_room, lay);
            if (guiAtBottom(transcript_skip, max_skip)) transcript_skip = max_skip;
            while (attach_tex.items.len < transcript.items.len) try attach_tex.append(gpa, null);
            while (attach_fetching.items.len < transcript.items.len) try attach_fetching.append(gpa, false);
            attach_tex.items[idx] = loadTextureFromBytes(preview, mime);
            gpa.free(preview);
        }

        scheduleAttachFetches(gpa, io, &blob_pending, fetch_template, &transcript, &attach_tex, &attach_fetching);
        try drainAttachFetches(gpa, &blob_pending, &transcript, &attach_tex, &attach_fetching);

        if (rl.isKeyPressed(rl.KeyboardKey.escape)) {
            if (ctx_menu.open) ctx_menu.close() else {
                sendBye(w, &bye_sent);
                break;
            }
        }

        if (rl.isKeyPressed(rl.KeyboardKey.enter) or rl.isKeyPressed(rl.KeyboardKey.kp_enter)) {
            const shift = rl.isKeyDown(rl.KeyboardKey.left_shift) or rl.isKeyDown(rl.KeyboardKey.right_shift);
            if (shift and ui_focus == .input) {
                if (input.items.len < 512) {
                    try input.insert(gpa, @min(input_cursor, input.items.len), '\n');
                    input_cursor += 1;
                }
            } else {
                try submitInputLines(gpa, io, &input, kp, author_id_str, &display_nick, w, &current_room, &transcript, &harness, &pending, fetch_template);
                input.clearRetainingCapacity();
                input_cursor = 0;
                cmd_mode = false;
            }
        }

        try gui_input.pumpKeys(gpa, &input, 512, &input_cursor);
        cmd_mode = input.items.len > 0 and input.items[0] == ':';

        if (rl.isKeyPressed(rl.KeyboardKey.v) and (rl.isKeyDown(rl.KeyboardKey.left_control) or rl.isKeyDown(rl.KeyboardKey.right_control))) {
            try pasteFromClipboard(gpa, io, &input, &pending, kp, author_id_str, display_nick, &current_room, fetch_template, &transcript);
            input_cursor = input.items.len;
        }

        if (rl.isKeyDown(rl.KeyboardKey.left_control) or rl.isKeyDown(rl.KeyboardKey.right_control)) {
            if (rl.isKeyPressed(rl.KeyboardKey.c)) {
                if (sel_anchor) |a| {
                    if (sel_to) |t| {
                        const lo = @min(a, t);
                        const hi = @max(a, t);
                        try copyTranscriptSelection(gpa, transcript.items, lo, hi);
                    }
                }
            }
            const max_skip = guiMaxSkip(&p, &transcript, &attach_tex, current_room, lay);
            if (rl.isKeyPressed(rl.KeyboardKey.u)) {
                transcript_skip = @min(transcript_skip + 4, max_skip);
            } else if (rl.isKeyPressed(rl.KeyboardKey.d)) {
                if (transcript_skip >= 4) transcript_skip -= 4;
            } else if (rl.isKeyPressed(rl.KeyboardKey.w)) {
                pending_ctrl_w = true;
            } else if (rl.isKeyPressed(rl.KeyboardKey.m)) {
                members_forced = !members_forced;
            }
        }

        if (pending_ctrl_w) {
            if (rl.isKeyPressed(rl.KeyboardKey.h)) {
                ui_focus = focus.left(ui_focus, lay);
                pending_ctrl_w = false;
            } else if (rl.isKeyPressed(rl.KeyboardKey.l)) {
                ui_focus = focus.right(ui_focus, lay);
                pending_ctrl_w = false;
            }
        }

        if (focus.isList(ui_focus)) {
            if (rl.isKeyPressed(rl.KeyboardKey.j) or rl.isKeyPressed(rl.KeyboardKey.down)) {
                switch (ui_focus) {
                    .rooms => {
                        if (channel_sel + 1 < sidebar_st.channels.items.len) channel_sel += 1;
                    },
                    .members => {
                        if (member_sel + 1 < member_list.items.len) member_sel += 1;
                    },
                    else => {},
                }
            } else if (rl.isKeyPressed(rl.KeyboardKey.k) or rl.isKeyPressed(rl.KeyboardKey.up)) {
                switch (ui_focus) {
                    .rooms => {
                        if (channel_sel > 0) channel_sel -= 1;
                    },
                    .members => {
                        if (member_sel > 0) member_sel -= 1;
                    },
                    else => {},
                }
            } else if (rl.isKeyPressed(rl.KeyboardKey.enter) or rl.isKeyPressed(rl.KeyboardKey.kp_enter)) {
                switch (ui_focus) {
                    .rooms => {
                        if (sidebar_st.channels.items.len > 0) {
                            try selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
                            ui_focus = .input;
                            transcript_skip = 0;
                        }
                    },
                    .members => {
                        if (member_sel < member_list.items.len) {
                            var at: [80]u8 = undefined;
                            if (std.fmt.bufPrint(at[0..], "@{s} ", .{member_list.items[member_sel].name})) |ins| {
                                try input.appendSlice(gpa, ins);
                            } else |_| {}
                            ui_focus = .input;
                        }
                    },
                    else => {},
                }
            }
        }

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            const mx = rl.getMouseX();
            const my = rl.getMouseY();
            if (p.hitPane(lay, mx, my) == .transcript) {
                const max_skip = guiMaxSkip(&p, &transcript, &attach_tex, current_room, lay);
                if (wheel < 0) {
                    transcript_skip = @min(transcript_skip + 4, max_skip);
                } else if (transcript_skip >= 4) {
                    transcript_skip -= 4;
                }
            }
        }

        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        const vp = p.viewport();

        const alt = rl.isKeyDown(rl.KeyboardKey.left_alt) or rl.isKeyDown(rl.KeyboardKey.right_alt);
        if (alt) {
            if (rl.isKeyPressed(rl.KeyboardKey.f)) toggleMenubarFromKind(&p, &ctx_menu, .file, vp);
            if (rl.isKeyPressed(rl.KeyboardKey.e)) toggleMenubarFromKind(&p, &ctx_menu, .edit, vp);
            if (rl.isKeyPressed(rl.KeyboardKey.v)) toggleMenubarFromKind(&p, &ctx_menu, .view, vp);
            if (rl.isKeyPressed(rl.KeyboardKey.t)) toggleMenubarFromKind(&p, &ctx_menu, .tools, vp);
            if (rl.isKeyPressed(rl.KeyboardKey.h)) toggleMenubarFromKind(&p, &ctx_menu, .help, vp);
        }

        if (scroll_grab_dy) |grab| {
            if (rl.isMouseButtonDown(rl.MouseButton.left)) {
                transcript_skip = p.scrollSkipFromY(my, grab);
            } else {
                scroll_grab_dy = null;
            }
        } else if (rl.isMouseButtonPressed(rl.MouseButton.left) and !ctx_menu.open) {
            if (p.hitScrollThumb(mx, my)) {
                scroll_grab_dy = @as(f32, @floatFromInt(my)) - p.scroll_thumb_rect.y;
            } else if (p.hitScrollTrack(mx, my)) {
                transcript_skip = p.scrollSkipFromY(my, p.scroll_thumb_rect.height * 0.5);
            }
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.right)) {
            const act = p.hitChrome(mx, my);
            if (chromeMenuKind(act)) |mk| {
                if (p.menuAnchor(act)) |anchor| {
                    _ = ctx_menu.toggleMenubar(anchor, mk, vp);
                }
            } else {
                ctx_menu.close();
                if (act == .none and !p.hitInput(mx, my)) {
                    if (p.hitMember(mx, my, member_list.items.len)) |mi| {
                        ctx_menu.openMember(@floatFromInt(mx), @floatFromInt(my), mi, vp);
                    } else if (lay.show_rooms) {
                        if (p.hitTab(mx, my, sidebar_st.channels.items.len)) |ti| {
                            ctx_menu.openTab(@floatFromInt(mx), @floatFromInt(my), ti, vp);
                        } else if (p.hitTranscriptLine(mx, my, transcript.items, attach_tex.items, current_room, transcript_skip, lay)) |li| {
                            ctx_menu.openTranscript(@floatFromInt(mx), @floatFromInt(my), li, vp);
                        }
                    } else if (p.hitTranscriptLine(mx, my, transcript.items, attach_tex.items, current_room, transcript_skip, lay)) |li| {
                        ctx_menu.openTranscript(@floatFromInt(mx), @floatFromInt(my), li, vp);
                    }
                }
            }
        }

        if (rl.isMouseButtonDown(rl.MouseButton.left) and sel_anchor != null) {
            if (p.hitTranscriptLine(mx, my, transcript.items, attach_tex.items, current_room, transcript_skip, lay)) |li| {
                sel_to = li;
            }
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.left)) {
            if (ctx_menu.open) {
                const pick = ctx_menu.pick(mx, my);
                if (try handleMenuPick(gpa, io, &ctx_menu, pick, &input, &transcript, &attach_tex, &member_list, &sidebar_st, &current_room, &transcript_skip, &members_forced, &pending, kp, author_id_str, display_nick, fetch_template, w, &bye_sent, &ui_focus)) break;
                ctx_menu.close();
            } else {
                const act = p.hitChrome(mx, my);
                if (chromeMenuKind(act)) |mk| {
                    if (p.menuAnchor(act)) |anchor| {
                        _ = ctx_menu.toggleMenubar(anchor, mk, vp);
                    }
                } else if (try handleChromeAction(gpa, act, host, port, connected, &transcript, &transcript_skip, &toolbar_sel)) {
                    sendBye(w, &bye_sent);
                    break;
                } else if (!p.hitScrollThumb(mx, my) and !p.hitScrollTrack(mx, my)) {
                    if (p.hitInput(mx, my)) {
                        ui_focus = .input;
                        var prompt_buf: [80]u8 = undefined;
                        const pfx = inputPromptPrefix(cmd_mode, current_room, &prompt_buf);
                        input_cursor = p.inputCursorAt(mx, my, input.items, pfx);
                        sel_anchor = null;
                        sel_to = null;
                    } else if (p.hitPane(lay, mx, my)) |pane| {
                        switch (pane) {
                            .rooms => {
                                ui_focus = .rooms;
                                if (p.hitTab(mx, my, sidebar_st.channels.items.len)) |idx| {
                                    channel_sel = idx;
                                    try selectRoom(gpa, w, &sidebar_st, &member_list, channel_sel, &current_room);
                                    ui_focus = .input;
                                    transcript_skip = 0;
                                }
                            },
                            .members => {
                                ui_focus = .members;
                                if (p.hitMember(mx, my, member_list.items.len)) |mi| {
                                    member_sel = mi;
                                    var at: [80]u8 = undefined;
                                    if (std.fmt.bufPrint(at[0..], "@{s} ", .{member_list.items[member_sel].name})) |ins| {
                                        try input.appendSlice(gpa, ins);
                                    } else |_| {}
                                    ui_focus = .input;
                                }
                            },
                            .input => {
                                ui_focus = .input;
                                var prompt_buf: [80]u8 = undefined;
                                const pfx = inputPromptPrefix(cmd_mode, current_room, &prompt_buf);
                                input_cursor = p.inputCursorAt(mx, my, input.items, pfx);
                            },
                            .transcript => {
                                ui_focus = .transcript;
                                if (p.hitTranscriptLine(mx, my, transcript.items, attach_tex.items, current_room, transcript_skip, lay)) |li| {
                                    sel_anchor = li;
                                    sel_to = li;
                                }
                            },
                            .servers => ui_focus = .servers,
                        }
                    }
                }
            }
        }

        const selection: ?painter_mod.LineSelection = if (sel_anchor) |a| if (sel_to) |t| .{
            .from = @min(a, t),
            .to = @max(a, t),
        } else null else null;
        const member_hover: ?usize = if (lay.show_members) p.hitMember(mx, my, member_list.items.len) else null;
        const tab_hover: ?usize = if (lay.show_rooms) p.hitTab(mx, my, sidebar_st.channels.items.len) else null;
        rl.beginDrawing();
        p.begin();
        p.drawHarness(
            lay,
            ui_focus,
            host,
            port,
            display_nick,
            current_room,
            connected,
            &sidebar_st,
            &member_list,
            channel_sel,
            member_sel,
            &transcript,
            transcript_skip,
            input.items,
            cmd_mode,
            &attach_tex,
            frame,
            toolbar_sel,
            menubarHighlight(&ctx_menu),
            member_hover,
            tab_hover,
            mx,
            my,
            selection,
            input_cursor,
        );
        p.drawContextMenu(&ctx_menu, mx, my);
        rl.endDrawing();
    }
    sendBye(w, &bye_sent);
}
