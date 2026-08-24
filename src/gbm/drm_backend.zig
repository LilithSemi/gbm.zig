//! DRM-backed GBM allocator: allocates real DRM dumb buffers through a DRM node,
//! built on the drm subproject. Implements the same backend.Allocator vtable as
//! MemoryBackend. Buffers carry the GEM handle and are not CPU-mapped.

const std = @import("std");
const drm = @import("drm");
const fmt_mod = @import("format.zig");
const buf_mod = @import("buffer.zig");
const backend = @import("backend.zig");

pub const DrmBackend = struct {
    gpa: std.mem.Allocator,
    node: drm.Node,

    const vtable = backend.VTable{
        .allocate = drmAllocate,
        .free = drmFree,
        .exportFd = drmExportFd,
    };

    /// Open the first available DRM node (primary). Returns error.NoDevice if
    /// none can be opened.
    pub fn open(gpa: std.mem.Allocator) !DrmBackend {
        var iter = drm.Node.Iterator.init(gpa, .primary);
        const node = iter.next() orelse return error.NoDevice;
        return .{ .gpa = gpa, .node = node };
    }

    pub fn deinit(self: *DrmBackend) void {
        self.node.deinit();
    }

    pub fn allocator(self: *DrmBackend) backend.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn drmAllocate(ptr: *anyopaque, desc: buf_mod.BufferDesc) backend.Error!*buf_mod.BufferObject {
        const self: *DrmBackend = @ptrCast(@alignCast(ptr));

        const bpp = fmt_mod.bytesPerPixel(desc.format) orelse return backend.Error.Unsupported;
        if (desc.width == 0 or desc.height == 0) return backend.Error.InvalidArgument;

        const dumb = self.node.createDumb(desc.width, desc.height, @intCast(bpp * 8)) catch
            return backend.Error.OutOfMemory;
        errdefer self.node.destroyDumb(dumb.handle) catch {};

        const bo = self.gpa.create(buf_mod.BufferObject) catch return backend.Error.OutOfMemory;
        bo.* = .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .modifier = fmt_mod.DRM_FORMAT_MOD_LINEAR,
            .stride = dumb.pitch,
            .size = dumb.size,
            .data = &[_]u8{}, // not CPU-mapped by this backend
            .handle = dumb.handle,
            .allocator = self.allocator(),
        };
        return bo;
    }

    fn drmFree(ptr: *anyopaque, bo: *buf_mod.BufferObject) void {
        const self: *DrmBackend = @ptrCast(@alignCast(ptr));
        if (bo.handle != 0) self.node.destroyDumb(bo.handle) catch {};
        self.gpa.destroy(bo);
    }

    fn drmExportFd(ptr: *anyopaque, bo: *buf_mod.BufferObject) backend.Error!buf_mod.DmabufExport {
        const self: *DrmBackend = @ptrCast(@alignCast(ptr));
        const fd = self.node.primeHandleToFd(bo.handle, 0x80002) catch return backend.Error.ExportFailed;
        return .{
            .fd = fd,
            .width = bo.width,
            .height = bo.height,
            .format = bo.format,
            .stride = bo.stride,
            .offset = bo.offset,
            .modifier = bo.modifier,
        };
    }
};

test "live: DRM backend allocates a real dumb buffer" {
    const device = @import("device.zig");
    var be = DrmBackend.open(std.testing.allocator) catch return error.SkipZigTest;
    defer be.deinit();
    var dev = device.Device.init(be.allocator());

    const bo = dev.create(.{
        .width = 64,
        .height = 64,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .usage = .{ .scanout = true },
    }) catch |e| switch (e) {
        // Driver without dumb-buffer support: skip rather than fail.
        backend.Error.OutOfMemory => return error.SkipZigTest,
        else => return e,
    };
    defer dev.destroy(bo);

    try std.testing.expect(bo.handle != 0);
    try std.testing.expect(bo.size >= 64 * 64 * 4);
    try std.testing.expect(bo.stride >= 64 * 4);
}

test "live: DRM backend exports dma-buf fd via PRIME" {
    const device = @import("device.zig");
    var be = DrmBackend.open(std.testing.allocator) catch return error.SkipZigTest;
    defer be.deinit();
    var dev = device.Device.init(be.allocator());

    const bo = dev.create(.{
        .width = 64,
        .height = 64,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .usage = .{ .scanout = true },
    }) catch |e| switch (e) {
        backend.Error.OutOfMemory => return error.SkipZigTest,
        else => return e,
    };
    defer dev.destroy(bo);

    const exp = bo.exportFd() catch |e| switch (e) {
        backend.Error.ExportFailed => return error.SkipZigTest,
        else => return e,
    };
    defer _ = std.os.linux.close(exp.fd);

    try std.testing.expect(exp.fd >= 0);
    try std.testing.expect(exp.stride >= 64 * 4);
    try std.testing.expectEqual(fmt_mod.DRM_FORMAT_MOD_LINEAR, exp.modifier);
    try std.testing.expectEqual(@as(u32, 64), exp.width);
    try std.testing.expectEqual(@as(u32, 64), exp.height);

    // Bonus: verify the fd points to a dmabuf via /proc/self/fd readlink
    var link_buf: [256]u8 = undefined;
    var fd_path_buf: [64:0]u8 = undefined;
    const fd_path_slice = std.fmt.bufPrint(&fd_path_buf, "/proc/self/fd/{d}", .{exp.fd}) catch unreachable;
    fd_path_buf[fd_path_slice.len] = 0;
    const link_len = std.os.linux.readlink(@ptrCast(fd_path_buf[0..fd_path_slice.len :0]), &link_buf, link_buf.len);
    defer _ = std.os.linux.close(exp.fd);
    try std.testing.expect(@as(isize, @bitCast(link_len)) > 0);
    const target = link_buf[0..link_len];
    try std.testing.expect(std.mem.indexOf(u8, target, "dmabuf") != null);
}
