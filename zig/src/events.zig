const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const media = @import("media");
const transcript = @import("transcript");

pub const UiEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    server_line: []u8,
    server_closed,
    blob_loaded: struct {
        line_idx: usize,
        bytes: []u8,
    },
    blob_failed: struct {
        line_idx: usize,
    },
    image_ready: struct {
        frame: []u8,
        preview_bytes: []u8,
        line: transcript.TranscriptLine,
    },
    image_send_failed: []u8,
    paste: []const u8,
};

pub const TuiMedia = struct {
    vx: *vaxis.Vaxis,
    tty_wr: *Io.Writer,
    loop: *vaxis.Loop(UiEvent),
    io: Io,
    gpa: std.mem.Allocator,
    fetch_template: []const u8,
};

pub const BlobFetchJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(UiEvent),
    line_idx: usize,
    url: []u8,
    max_bytes: usize,

    fn run(job: *BlobFetchJob) void {
        defer {
            job.gpa.free(job.url);
            job.gpa.destroy(job);
        }
        const bytes = media.httpGetLimited(job.gpa, job.io, job.url, job.max_bytes) catch {
            job.loop.postEvent(.{ .blob_failed = .{ .line_idx = job.line_idx } }) catch {};
            return;
        };
        job.loop.postEvent(.{ .blob_loaded = .{ .line_idx = job.line_idx, .bytes = bytes } }) catch {
            job.gpa.free(bytes);
        };
    }
};

pub fn scheduleAttachPreviewFetch(ctx: *TuiMedia, tr: *std.ArrayList(transcript.TranscriptLine), line_idx: usize) void {
    if (!ctx.vx.caps.kitty_graphics) return;
    if (line_idx >= tr.items.len) return;
    const line = tr.items[line_idx];
    if (line != .attach) return;
    const a = line.attach;
    if (!media.mimeIsImage(a.mime)) return;
    const url = media.cidFetchUrl(ctx.gpa, ctx.fetch_template, a.cid_hex) catch return;
    const max_bytes: usize = 16 * 1024 * 1024;
    const job = ctx.gpa.create(BlobFetchJob) catch {
        ctx.gpa.free(url);
        return;
    };
    job.* = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .loop = ctx.loop,
        .line_idx = line_idx,
        .url = url,
        .max_bytes = max_bytes,
    };
    const th = std.Thread.spawn(.{}, BlobFetchJob.run, .{job}) catch {
        ctx.gpa.free(url);
        ctx.gpa.destroy(job);
        return;
    };
    th.detach();
}

