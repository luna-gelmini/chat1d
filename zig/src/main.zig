const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;

const cli = @import("cli");
const crypto = @import("crypto");
const identity = @import("identity");
const plain = @import("plain");
const vaxis_chat = @import("vaxis_chat");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var seed_hex: ?[]const u8 = null;
    var identity_opt: ?[]const u8 = null;
    var init_identity = false;
    var force = false;
    var plain_mode = false;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7000;
    var name: []const u8 = "zig";
    var room_opt: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            seed_hex = argv[i];
        } else if (std.mem.eql(u8, a, "--identity")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            identity_opt = argv[i];
        } else if (std.mem.eql(u8, a, "--init-identity")) {
            init_identity = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--plain")) {
            plain_mode = true;
        } else if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            host = argv[i];
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            port = std.fmt.parseInt(u16, argv[i], 10) catch cli.usage();
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            name = argv[i];
        } else if (std.mem.eql(u8, a, "--room")) {
            i += 1;
            if (i >= argv.len) cli.usage();
            room_opt = argv[i];
        } else {
            std.debug.print("error: unknown argument \"{s}\"\n\n", .{a});
            cli.usage();
        }
    }

    const io = init.io;

    if (seed_hex != null and identity_opt != null) {
        std.debug.print("error: use only one of --seed or --identity\n\n", .{});
        cli.usage();
    }
    if (init_identity and seed_hex != null) {
        std.debug.print("error: do not combine --init-identity with --seed\n\n", .{});
        cli.usage();
    }

    if (init_identity) {
        const seed_path = identity.seedFilePath(arena, init, identity_opt) catch |err| switch (err) {
            error.MissingHome => {
                std.debug.print("error: HOME (or USERPROFILE) is not set; use --identity <path> with --init-identity\n\n", .{});
                cli.usage();
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try identity.initIdentity(io, gpa, seed_path, force);
        std.debug.print("wrote new identity seed to {s}\n", .{seed_path});
        return;
    }

    var seed: [32]u8 = undefined;
    if (seed_hex) |seed_s| {
        if (seed_s.len != 64) {
            std.debug.print("seed must be 64 hex chars\n", .{});
            std.process.exit(1);
        }
        _ = try std.fmt.hexToBytes(&seed, seed_s);
    } else {
        const seed_path = identity.seedFilePath(arena, init, identity_opt) catch |err| switch (err) {
            error.MissingHome => {
                std.debug.print("error: HOME (or USERPROFILE) is not set; pass --seed <64-hex> or --identity <path>\n\n", .{});
                cli.usage();
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        seed = identity.loadSeedFile(io, gpa, seed_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("error: no identity file at \"{s}\"; create one with --init-identity\n\n", .{seed_path});
                std.process.exit(1);
            },
            error.BadIdentityFile => {
                std.debug.print("error: identity file must be 32 raw bytes or 64 hex chars (after trim)\n", .{});
                std.process.exit(1);
            },
            error.BadIdentityHex => {
                std.debug.print("error: identity file hex is not valid hexadecimal\n", .{});
                std.process.exit(1);
            },
            else => |e| return e,
        };
    }

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const pub_bytes = kp.public_key.toBytes();
    const pub_b64 = crypto.b64urlPub(pub_bytes);
    const author_id = crypto.authorIdHex(pub_bytes);
    const author_id_str: []const u8 = &author_id;

    const address = try Io.net.IpAddress.parse(host, port);
    const stream = Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => {
            std.debug.print(
                "error: connection refused to {s}:{d} (nothing listening — start the server or use --host / --port)\n",
                .{ host, port },
            );
            std.process.exit(1);
        },
        error.Timeout => {
            std.debug.print("error: connection timed out to {s}:{d}\n", .{ host, port });
            std.process.exit(1);
        },
        error.NetworkUnreachable, error.HostUnreachable => {
            std.debug.print("error: could not reach {s}:{d} ({s})\n", .{ host, port, @errorName(err) });
            std.process.exit(1);
        },
        else => |e| return e,
    };

    if (plain_mode) {
        try plain.runPlainChat(gpa, io, stream, kp, author_id_str, name, &pub_b64, room_opt);
    } else {
        try vaxis_chat.runVaxisChat(&init, gpa, io, host, port, stream, kp, author_id_str, name, &pub_b64, room_opt);
    }
}
