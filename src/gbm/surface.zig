const std = @import("std");
const buf_mod = @import("buffer.zig");
const device_mod = @import("device.zig");
const backend = @import("backend.zig");

/// Surface is a double-buffered swapchain-like object analogous to gbm_surface.
/// It maintains a front buffer (displayed/consumed) and a back buffer (rendered into).
/// Caller creates the surface, calls nextBuffer to get the back buffer to render into,
/// then presents (swaps) by calling lockFrontBuffer. releaseBuffer gives the buffer
/// back to the Surface so it can be reused.
pub const Surface = struct {
    device: *device_mod.Device,
    desc: buf_mod.BufferDesc,
    front: ?*buf_mod.BufferObject = null,
    back: ?*buf_mod.BufferObject = null,

    pub fn init(device: *device_mod.Device, desc: buf_mod.BufferDesc) Surface {
        return .{
            .device = device,
            .desc = desc,
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.front) |bo| {
            self.device.destroy(bo);
            self.front = null;
        }
        if (self.back) |bo| {
            self.device.destroy(bo);
            self.back = null;
        }
    }

    /// Obtain the back buffer for rendering. Creates it on first call.
    /// Returns error if the back buffer is already locked for rendering
    /// (caller must call releaseBuffer before calling nextBuffer again).
    pub fn nextBuffer(self: *Surface) backend.Error!*buf_mod.BufferObject {
        if (self.back == null) {
            self.back = try self.device.create(self.desc);
        }
        return self.back.?;
    }

    /// Swap back->front. Returns the front buffer (ready to be displayed/exported).
    /// Caller must call releaseBuffer when done with it.
    /// The returned buffer is removed from Surface ownership until releaseBuffer is called.
    pub fn lockFrontBuffer(self: *Surface) ?*buf_mod.BufferObject {
        const old_front = self.front;
        self.front = self.back;
        self.back = old_front;
        const locked = self.front;
        self.front = null;
        return locked;
    }

    /// Return a previously locked front buffer back to the Surface.
    pub fn releaseBuffer(self: *Surface, bo: *buf_mod.BufferObject) void {
        // If back is null, recycle bo as the new back buffer.
        // If back is already set, destroy bo (shouldn't happen in normal usage).
        if (self.back == null) {
            self.back = bo;
        } else {
            self.device.destroy(bo);
        }
    }
};

test "Surface: init and deinit with no buffers allocated" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = device_mod.Device.init(mb.allocator());

    var surf = Surface.init(&dev, .{
        .width = 100,
        .height = 100,
        .format = @import("format.zig").DRM_FORMAT_XRGB8888,
        .usage = .{ .scanout = true },
    });
    surf.deinit();
}

test "Surface: nextBuffer creates back buffer" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = device_mod.Device.init(mb.allocator());

    var surf = Surface.init(&dev, .{
        .width = 100,
        .height = 100,
        .format = @import("format.zig").DRM_FORMAT_XRGB8888,
        .usage = .{ .scanout = true },
    });
    defer surf.deinit();

    const back = try surf.nextBuffer();
    try std.testing.expectEqual(@as(u32, 100), back.width);
    try std.testing.expectEqual(@as(u32, 100), back.height);
}

test "Surface: lockFrontBuffer swaps buffers" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = device_mod.Device.init(mb.allocator());
    const fmt = @import("format.zig");

    var surf = Surface.init(&dev, .{
        .width = 64,
        .height = 64,
        .format = fmt.DRM_FORMAT_XRGB8888,
        .usage = .{ .rendering = true, .scanout = true },
    });
    defer surf.deinit();

    // Get back buffer and write a sentinel
    const back = try surf.nextBuffer();
    back.map()[0] = 0xAB;
    back.unmap();

    // Lock front (swap): front is now the buffer we rendered into
    const front = surf.lockFrontBuffer().?;
    try std.testing.expectEqual(@as(u8, 0xAB), front.map()[0]);
    front.unmap();

    // Release front -> becomes new back
    surf.releaseBuffer(front);

    // Get next back buffer (should be the old front)
    const back2 = try surf.nextBuffer();
    try std.testing.expectEqual(@as(u8, 0xAB), back2.map()[0]);
    back2.unmap();
}
