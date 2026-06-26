const std = @import("std");
const Io = std.Io;
const media = @import("media");

pub const GuiBlobPending = struct {
    mutex: std.atomic.Mutex = .unlocked,
    ready: std.ArrayList(Result) = .empty,

    pub const Result = union(enum) {
        loaded: struct {
            line_idx: usize,
            bytes: []u8,
            mime_owned: []u8,
        },
        failed: struct {
            line_idx: usize,
        },
    };

    pub fn deinit(self: *GuiBlobPending, gpa: std.mem.Allocator) void {
        for (self.ready.items) |r| {
            switch (r) {
                .loaded => |l| {
                    gpa.free(l.bytes);
                    gpa.free(l.mime_owned);
                },
                .failed => {},
            }
        }
        self.ready.deinit(gpa);
    }

    pub fn drain(self: *GuiBlobPending, gpa: std.mem.Allocator) ![]Result {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        const slice = try self.ready.toOwnedSlice(gpa);
        self.ready = .empty;
        return slice;
    }

    pub fn schedule(
        self: *GuiBlobPending,
        gpa: std.mem.Allocator,
        io: Io,
        fetch_template: []const u8,
        line_idx: usize,
        cid_hex: []const u8,
        mime: []const u8,
    ) void {
        const url = media.cidFetchUrl(gpa, fetch_template, cid_hex) catch return;
        const mime_owned = gpa.dupe(u8, mime) catch {
            gpa.free(url);
            return;
        };
        const job = gpa.create(BlobJob) catch {
            gpa.free(url);
            gpa.free(mime_owned);
            return;
        };
        job.* = .{
            .gpa = gpa,
            .io = io,
            .pending = self,
            .line_idx = line_idx,
            .url = url,
            .mime = mime_owned,
        };
        const th = std.Thread.spawn(.{}, BlobJob.run, .{job}) catch {
            gpa.free(url);
            gpa.free(mime_owned);
            gpa.destroy(job);
            return;
        };
        th.detach();
    }
};

const BlobJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    pending: *GuiBlobPending,
    line_idx: usize,
    url: []u8,
    mime: []u8,

    fn run(job: *BlobJob) void {
        const gpa = job.gpa;
        const io = job.io;
        const pending = job.pending;
        const line_idx = job.line_idx;
        const url = job.url;
        const mime = job.mime;
        gpa.destroy(job);

        defer gpa.free(url);

        const bytes = media.httpGetLimited(gpa, io, url, media.max_image_bytes) catch {
            defer gpa.free(mime);
            while (!pending.mutex.tryLock()) {}
            defer pending.mutex.unlock();
            pending.ready.append(gpa, .{ .failed = .{ .line_idx = line_idx } }) catch {};
            return;
        };

        while (!pending.mutex.tryLock()) {}
        defer pending.mutex.unlock();
        pending.ready.append(gpa, .{
            .loaded = .{
                .line_idx = line_idx,
                .bytes = bytes,
                .mime_owned = mime,
            },
        }) catch {
            gpa.free(bytes);
            gpa.free(mime);
        };
    }
};
