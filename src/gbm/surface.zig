const std = @import("std");
const buf_mod = @import("buffer.zig");
const device_mod = @import("device.zig");
const backend = @import("backend.zig");

/// Surface is a double-buffered swapchain analogous to gbm_surface. It keeps a
/// front buffer (displayed) and a back buffer (rendered into).
///
/// Posting and locking are split like real libgbm + EGL. nextBuffer hands the
/// renderer the back buffer to draw into. swapBuffers posts it so back becomes
/// front (eglSwapBuffers). lockFrontBuffer takes the posted front out for
/// scanout. releaseBuffer returns it after the flip for reuse. The renderer
/// (EGL) and the presenter (a KMS compositor) each drive their own step.
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

    /// Post the rendered back buffer: back becomes the new front, and the old
    /// front becomes the back (available to render into next). The front stays in
    /// the Surface for the presenter to lockFrontBuffer. The renderer calls this
    /// from eglSwapBuffers.
    pub fn swapBuffers(self: *Surface) void {
        const old_front = self.front;
        self.front = self.back;
        self.back = old_front;
    }

    /// Take the posted front buffer out for display/scanout, or null if nothing
    /// was posted since the last lock. The presenter calls this after swapBuffers,
    /// then releaseBuffer once the flip is done. Does not swap.
    pub fn lockFrontBuffer(self: *Surface) ?*buf_mod.BufferObject {
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

test "Surface: swapBuffers posts, lockFrontBuffer hands off, releaseBuffer recycles" {
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

    // Nothing posted yet: locking returns null.
    try std.testing.expectEqual(@as(?*buf_mod.BufferObject, null), surf.lockFrontBuffer());

    // Render into the back buffer and post it.
    const back = try surf.nextBuffer();
    back.map()[0] = 0xAB;
    back.unmap();
    surf.swapBuffers();

    // Lock the posted front (no second post): it is the buffer we rendered into.
    const front = surf.lockFrontBuffer().?;
    try std.testing.expectEqual(@as(u8, 0xAB), front.map()[0]);
    front.unmap();

    // A second lock without a new post returns null (the front was taken).
    try std.testing.expectEqual(@as(?*buf_mod.BufferObject, null), surf.lockFrontBuffer());

    // Release the front so it recycles as the new back.
    surf.releaseBuffer(front);
    const back2 = try surf.nextBuffer();
    try std.testing.expectEqual(@as(u8, 0xAB), back2.map()[0]);
    back2.unmap();
}
