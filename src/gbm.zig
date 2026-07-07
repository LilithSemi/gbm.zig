const std = @import("std");

pub const name = "gbm";

pub const format = @import("gbm/format.zig");
pub const buffer = @import("gbm/buffer.zig");
pub const backend = @import("gbm/backend.zig");
pub const device = @import("gbm/device.zig");
pub const surface = @import("gbm/surface.zig");
pub const drm_backend = @import("gbm/drm_backend.zig");
pub const nvidia_backend = @import("gbm/nvidia_backend.zig");

// Top-level re-exports for ergonomic use
pub const Device = device.Device;
pub const Surface = surface.Surface;
pub const BufferObject = buffer.BufferObject;
pub const BufferDesc = buffer.BufferDesc;
pub const BufferUsage = buffer.BufferUsage;
pub const BufferExportDesc = buffer.BufferExportDesc;
pub const BufferImportDesc = buffer.BufferImportDesc;
pub const MemoryBackend = backend.MemoryBackend;
pub const DrmBackend = drm_backend.DrmBackend;
pub const NvidiaBackend = nvidia_backend.NvidiaBackend;
pub const Allocator = backend.Allocator;

test {
    std.testing.refAllDecls(@This());
}

test "gbm subproject identifies itself" {
    try std.testing.expectEqualStrings("gbm", name);
}
