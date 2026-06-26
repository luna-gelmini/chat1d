const std = @import("std");
const Io = std.Io;

pub fn usage() noreturn {
    std.debug.print(
        \\usage: chat1-client [--seed <64-hex> | --identity <path>] [--plain] [--host <ip-literal>] [--port <u16>] [--name <id>] [--room <room>]
        \\
        \\Identity (Ed25519 seed):
        \\  Default: read ~/.chat1d/seed (Windows: %USERPROFILE%\\.chat1d\\seed).
        \\  --identity <path>   read seed from this file instead of the default.
        \\  --init-identity     create ~/.chat1d (or --identity path) and write a new random seed (64 hex + newline).
        \\  --force             with --init-identity, overwrite a non-empty seed file.
        \\  --plain             line-oriented stdin/stdout (no Vaxis TUI).
        \\
        \\Commands (aligned with tools/chat1_client.py):
        \\  /join <room>   /part <room>   /room <room>
        \\  /msg <room> <text>   /me <text>   /nick <name>   (TUI: Ctrl+V paste image)
        \\  /ping [nonce]   /bye [reason]   /quit
        \\
    , .{});
    std.process.exit(1);
}

