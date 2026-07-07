const std = @import("std");
const fmt_mod = @import("format.zig");
const buf_mod = @import("buffer.zig");
const backend = @import("backend.zig");

/// Device is the top-level GBM object: it owns an Allocator backend and
/// acts as the factory for BufferObjects. It is analogous to gbm_device in
/// libgbm. The caller is responsible for the lifetime of the Allocator.
pub const Device = struct {
    alloc: backend.Allocator,

    pub fn init(alloc: backend.Allocator) Device {
        return .{ .alloc = alloc };
    }

    /// Create a new BufferObject described by `desc`.
    /// Caller frees with `device.destroy(bo)`.
    pub fn create(self: *Device, desc: buf_mod.BufferDesc) backend.Error!*buf_mod.BufferObject {
        return self.alloc.allocate(desc);
    }

    /// Destroy a BufferObject previously created by this Device.
    pub fn destroy(self: *Device, bo: *buf_mod.BufferObject) void {
        self.alloc.free(bo);
    }

    /// Returns true if the device backend can handle the given DRM format.
    /// For the MemoryBackend, any format with a known bytes-per-pixel is supported.
    pub fn supportsFormat(self: *const Device, fmt: u32) bool {
        _ = self;
        return fmt_mod.bytesPerPixel(fmt) != null;
    }

    /// Returns true if the device supports the given format+modifier combination.
    /// The MemoryBackend only supports linear (modifier == 0).
    pub fn supportsFormatModifier(self: *const Device, fmt: u32, mod: u64) bool {
        if (!self.supportsFormat(fmt)) return false;
        return mod == fmt_mod.DRM_FORMAT_MOD_LINEAR or mod == fmt_mod.DRM_FORMAT_MOD_INVALID;
    }
};

test "Device: create and destroy a buffer" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = Device.init(mb.allocator());

    const bo = try dev.create(.{
        .width = 64,
        .height = 64,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .usage = .{ .rendering = true },
    });
    defer dev.destroy(bo);

    try std.testing.expectEqual(@as(u32, 64), bo.width);
    try std.testing.expectEqual(@as(u32, 64), bo.height);
    try std.testing.expectEqual(fmt_mod.DRM_FORMAT_XRGB8888, bo.format);
}

test "Device: supportsFormat known and unknown" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = Device.init(mb.allocator());

    try std.testing.expect(dev.supportsFormat(fmt_mod.DRM_FORMAT_XRGB8888));
    try std.testing.expect(dev.supportsFormat(fmt_mod.DRM_FORMAT_RGB565));
    try std.testing.expect(!dev.supportsFormat(fmt_mod.DRM_FORMAT_NV12));
    try std.testing.expect(!dev.supportsFormat(0xdeadbeef));
}

test "Device: supportsFormatModifier linear ok, tiled not ok" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = Device.init(mb.allocator());

    try std.testing.expect(dev.supportsFormatModifier(fmt_mod.DRM_FORMAT_XRGB8888, fmt_mod.DRM_FORMAT_MOD_LINEAR));
    // INVALID modifier is treated as "unspecified" which MemoryBackend allows
    try std.testing.expect(dev.supportsFormatModifier(fmt_mod.DRM_FORMAT_XRGB8888, fmt_mod.DRM_FORMAT_MOD_INVALID));
    // A made-up tiled modifier should fail
    const fake_tiled: u64 = (@as(u64, fmt_mod.DRM_FORMAT_MOD_VENDOR_AMD) << 56) | 0x1;
    try std.testing.expect(!dev.supportsFormatModifier(fmt_mod.DRM_FORMAT_XRGB8888, fake_tiled));
}

test "Device: create with RGB565 format" {
    var mb = @import("backend.zig").MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    var dev = Device.init(mb.allocator());

    const bo = try dev.create(.{
        .width = 320,
        .height = 240,
        .format = fmt_mod.DRM_FORMAT_RGB565,
        .usage = .{ .scanout = true },
    });
    defer dev.destroy(bo);

    // stride: 320 * 2 = 640 bytes, aligns up to next 256 multiple = 768
    try std.testing.expectEqual(@as(u32, 320), bo.width);
    try std.testing.expectEqual(@as(u32, 240), bo.height);
    try std.testing.expectEqual(@as(usize, 768 * 240), bo.size);
}
