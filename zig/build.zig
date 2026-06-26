const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default ReleaseSmall ~864KiB ELF; Debug may SEGV on Zig 0.16)",
    ) orelse .ReleaseSmall;

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_mod = raylib_dep.module("raylib");
    const raylib_art = raylib_dep.artifact("raylib");

    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crypto_mod = b.createModule(.{ .root_source_file = b.path("src/crypto.zig"), .target = target, .optimize = optimize });
    const cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize });
    const log_mod = b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize });
    const sidebar_mod = b.createModule(.{ .root_source_file = b.path("src/sidebar.zig"), .target = target, .optimize = optimize });
    const layout_mod = b.createModule(.{ .root_source_file = b.path("src/layout.zig"), .target = target, .optimize = optimize });
    const focus_mod = b.createModule(.{ .root_source_file = b.path("src/focus.zig"), .target = target, .optimize = optimize });
    focus_mod.addImport("layout", layout_mod);
    const members_mod = b.createModule(.{ .root_source_file = b.path("src/members.zig"), .target = target, .optimize = optimize });
    members_mod.addImport("sidebar", sidebar_mod);
    const media_mod = b.createModule(.{ .root_source_file = b.path("src/media.zig"), .target = target, .optimize = optimize });

    const identity_mod = b.createModule(.{ .root_source_file = b.path("src/identity.zig"), .target = target, .optimize = optimize });
    identity_mod.addImport("crypto", crypto_mod);

    const transcript_mod = b.createModule(.{ .root_source_file = b.path("src/transcript.zig"), .target = target, .optimize = optimize });
    transcript_mod.addImport("util", util_mod);
    transcript_mod.addImport("media", media_mod);
    transcript_mod.addImport("log", log_mod);
    transcript_mod.addImport("vaxis", vaxis_mod);

    const events_mod = b.createModule(.{ .root_source_file = b.path("src/events.zig"), .target = target, .optimize = optimize });
    events_mod.addImport("media", media_mod);
    events_mod.addImport("transcript", transcript_mod);
    events_mod.addImport("vaxis", vaxis_mod);

    const wire_mod = b.createModule(.{ .root_source_file = b.path("src/wire.zig"), .target = target, .optimize = optimize });
    wire_mod.addImport("sidebar", sidebar_mod);
    wire_mod.addImport("transcript", transcript_mod);
    wire_mod.addImport("events", events_mod);
    wire_mod.addImport("crypto", crypto_mod);
    wire_mod.addImport("members", members_mod);

    const commands_mod = b.createModule(.{ .root_source_file = b.path("src/commands.zig"), .target = target, .optimize = optimize });
    commands_mod.addImport("util", util_mod);
    commands_mod.addImport("crypto", crypto_mod);
    commands_mod.addImport("media", media_mod);
    commands_mod.addImport("log", log_mod);
    commands_mod.addImport("transcript", transcript_mod);
    commands_mod.addImport("sidebar", sidebar_mod);
    commands_mod.addImport("wire", wire_mod);
    commands_mod.addImport("events", events_mod);

    const tui_mod = b.createModule(.{ .root_source_file = b.path("src/tui.zig"), .target = target, .optimize = optimize });
    tui_mod.addImport("events", events_mod);
    tui_mod.addImport("transcript", transcript_mod);
    tui_mod.addImport("sidebar", sidebar_mod);
    tui_mod.addImport("layout", layout_mod);
    tui_mod.addImport("focus", focus_mod);
    tui_mod.addImport("members", members_mod);
    tui_mod.addImport("vaxis", vaxis_mod);

    const mouse_ui_mod = b.createModule(.{ .root_source_file = b.path("src/mouse_ui.zig"), .target = target, .optimize = optimize });
    mouse_ui_mod.addImport("layout", layout_mod);
    mouse_ui_mod.addImport("sidebar", sidebar_mod);
    mouse_ui_mod.addImport("members", members_mod);
    mouse_ui_mod.addImport("vaxis", vaxis_mod);

    const plain_mod = b.createModule(.{ .root_source_file = b.path("src/plain.zig"), .target = target, .optimize = optimize });
    plain_mod.addImport("util", util_mod);
    plain_mod.addImport("crypto", crypto_mod);
    plain_mod.addImport("media", media_mod);
    plain_mod.addImport("commands", commands_mod);

    const vaxis_chat_mod = b.createModule(.{ .root_source_file = b.path("src/vaxis_chat.zig"), .target = target, .optimize = optimize });
    vaxis_chat_mod.addImport("crypto", crypto_mod);
    vaxis_chat_mod.addImport("media", media_mod);
    vaxis_chat_mod.addImport("transcript", transcript_mod);
    vaxis_chat_mod.addImport("sidebar", sidebar_mod);
    vaxis_chat_mod.addImport("layout", layout_mod);
    vaxis_chat_mod.addImport("focus", focus_mod);
    vaxis_chat_mod.addImport("members", members_mod);
    vaxis_chat_mod.addImport("events", events_mod);
    vaxis_chat_mod.addImport("wire", wire_mod);
    vaxis_chat_mod.addImport("commands", commands_mod);
    vaxis_chat_mod.addImport("tui", tui_mod);
    vaxis_chat_mod.addImport("mouse_ui", mouse_ui_mod);
    vaxis_chat_mod.addImport("vaxis", vaxis_mod);

    const gui_input_mod = b.createModule(.{ .root_source_file = b.path("src/gui/input.zig"), .target = target, .optimize = optimize });
    gui_input_mod.addImport("raylib", raylib_mod);

    const gui_win98_mod = b.createModule(.{ .root_source_file = b.path("src/gui/win98.zig"), .target = target, .optimize = optimize });
    gui_win98_mod.addImport("raylib", raylib_mod);

    const gui_chrome_mod = b.createModule(.{ .root_source_file = b.path("src/gui/chrome.zig"), .target = target, .optimize = optimize });
    gui_chrome_mod.addImport("raylib", raylib_mod);
    gui_win98_mod.addImport("gui/chrome", gui_chrome_mod);

    const gui_context_menu_mod = b.createModule(.{ .root_source_file = b.path("src/gui/context_menu.zig"), .target = target, .optimize = optimize });
    gui_context_menu_mod.addImport("raylib", raylib_mod);
    gui_context_menu_mod.addImport("gui/win98", gui_win98_mod);

    const gui_transcript_layout_mod = b.createModule(.{ .root_source_file = b.path("src/gui/transcript_layout.zig"), .target = target, .optimize = optimize });
    gui_transcript_layout_mod.addImport("raylib", raylib_mod);
    gui_transcript_layout_mod.addImport("transcript", transcript_mod);
    gui_transcript_layout_mod.addImport("tui", tui_mod);

    const gui_blob_fetch_mod = b.createModule(.{ .root_source_file = b.path("src/gui/blob_fetch.zig"), .target = target, .optimize = optimize });
    gui_blob_fetch_mod.addImport("media", media_mod);

    const gui_font_mod = b.createModule(.{ .root_source_file = b.path("src/gui/font.zig"), .target = target, .optimize = optimize });
    gui_font_mod.addImport("raylib", raylib_mod);

    const gui_start_mod = b.createModule(.{ .root_source_file = b.path("src/gui/start_screen.zig"), .target = target, .optimize = optimize });
    gui_start_mod.addImport("raylib", raylib_mod);
    gui_start_mod.addImport("gui/input", gui_input_mod);
    gui_start_mod.addImport("gui/win98", gui_win98_mod);

    const gui_painter_mod = b.createModule(.{ .root_source_file = b.path("src/gui/painter.zig"), .target = target, .optimize = optimize });
    gui_painter_mod.addImport("raylib", raylib_mod);
    gui_painter_mod.addImport("layout", layout_mod);
    gui_painter_mod.addImport("sidebar", sidebar_mod);
    gui_painter_mod.addImport("members", members_mod);
    gui_painter_mod.addImport("focus", focus_mod);
    gui_painter_mod.addImport("transcript", transcript_mod);
    gui_painter_mod.addImport("tui", tui_mod);
    gui_painter_mod.addImport("gui/win98", gui_win98_mod);
    gui_painter_mod.addImport("gui/chrome", gui_chrome_mod);
    gui_painter_mod.addImport("gui/context_menu", gui_context_menu_mod);
    gui_painter_mod.addImport("gui/transcript_layout", gui_transcript_layout_mod);
    gui_painter_mod.addImport("gui/input", gui_input_mod);
    gui_painter_mod.addImport("util", util_mod);

    const gui_chat_mod = b.createModule(.{ .root_source_file = b.path("src/gui_chat.zig"), .target = target, .optimize = optimize });
    gui_chat_mod.addImport("crypto", crypto_mod);
    gui_chat_mod.addImport("media", media_mod);
    gui_chat_mod.addImport("transcript", transcript_mod);
    gui_chat_mod.addImport("sidebar", sidebar_mod);
    gui_chat_mod.addImport("layout", layout_mod);
    gui_chat_mod.addImport("focus", focus_mod);
    gui_chat_mod.addImport("members", members_mod);
    gui_chat_mod.addImport("wire", wire_mod);
    gui_chat_mod.addImport("commands", commands_mod);
    gui_chat_mod.addImport("tui", tui_mod);
    gui_chat_mod.addImport("raylib", raylib_mod);
    gui_chat_mod.addImport("gui/painter", gui_painter_mod);
    gui_chat_mod.addImport("gui/font", gui_font_mod);
    gui_chat_mod.addImport("gui/input", gui_input_mod);
    gui_chat_mod.addImport("gui/chrome", gui_chrome_mod);
    gui_chat_mod.addImport("gui/context_menu", gui_context_menu_mod);
    gui_chat_mod.addImport("gui/transcript_layout", gui_transcript_layout_mod);
    gui_chat_mod.addImport("gui/blob_fetch", gui_blob_fetch_mod);
    gui_chat_mod.addImport("gui/start_screen", gui_start_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "identity", .module = identity_mod },
            .{ .name = "plain", .module = plain_mod },
            .{ .name = "vaxis_chat", .module = vaxis_chat_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "chat1-client",
        .root_module = root_mod,
    });
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const gui_root_mod = b.createModule(.{
        .root_source_file = b.path("src/gui_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "identity", .module = identity_mod },
            .{ .name = "gui_chat", .module = gui_chat_mod },
        },
    });
    const gui_exe = b.addExecutable(.{
        .name = "chat1-gui",
        .root_module = gui_root_mod,
    });
    gui_exe.root_module.linkLibrary(raylib_art);
    gui_exe.root_module.link_libc = true;
    b.installArtifact(gui_exe);

    const install_font = b.addInstallFile(b.path("src/gui/assets/DejaVuSansMono.ttf"), "bin/DejaVuSansMono.ttf");
    b.getInstallStep().dependOn(&install_font.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the CHAT/1 client");
    run_step.dependOn(&run_cmd.step);
}
