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
        };
        return bo;
    }

    fn drmFree(ptr: *anyopaque, bo: *buf_mod.BufferObject) void {
        const self: *DrmBackend = @ptrCast(@alignCast(ptr));
        if (bo.handle != 0) self.node.destroyDumb(bo.handle) catch {};
        self.gpa.destroy(bo);
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
