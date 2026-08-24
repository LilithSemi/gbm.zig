const std = @import("std");
const fmt_mod = @import("format.zig");
const backend = @import("backend.zig");

pub const DmabufExport = struct {
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    format: u32,
    stride: u32,
    offset: u32,
    modifier: u64,
};

pub const STRIDE_ALIGNMENT: usize = 256;

pub const MAX_PLANES: usize = 4;

pub const BufferUsage = packed struct {
    scanout: bool = false,
    rendering: bool = false,
    cursor: bool = false,
    linear: bool = false,
    _padding: u28 = 0,
};

pub const BufferDesc = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64 = fmt_mod.DRM_FORMAT_MOD_LINEAR,
    usage: BufferUsage,
};

/// Exported descriptor for sharing a buffer with another subsystem (e.g. DRM).
pub const BufferExportDesc = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    /// One entry per plane. stride[i] == 0 means plane i is unused.
    strides: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
    offsets: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
    /// GEM handles or fd-based opaque handles, backend-specific.
    handles: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
};

/// Import descriptor for wrapping a foreign buffer.
pub const BufferImportDesc = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64 = fmt_mod.DRM_FORMAT_MOD_LINEAR,
    strides: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
    offsets: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
    handles: [MAX_PLANES]u32 = .{ 0, 0, 0, 0 },
};

pub const BufferObject = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64 = fmt_mod.DRM_FORMAT_MOD_LINEAR,
    stride: u32,
    size: usize,
    data: []u8,
    /// Opaque GEM handle (0 = not backed by a GEM object, pure memory).
    handle: u32 = 0,
    /// Byte offset of plane 0 within `data`. For single-plane formats always 0.
    offset: u32 = 0,
    /// Back-reference to the owning allocator (null for stack-allocated test BOs).
    allocator: ?backend.Allocator = null,

    pub fn map(self: *BufferObject) []u8 {
        return self.data;
    }

    pub fn unmap(self: *BufferObject) void {
        _ = self;
    }

    /// Stride of plane `plane`. Only plane 0 is meaningful for packed formats.
    pub fn getPlaneStride(self: *const BufferObject, plane: u8) u32 {
        return if (plane == 0) self.stride else 0;
    }

    /// Byte offset of plane `plane` from the start of `data`.
    pub fn getPlaneOffset(self: *const BufferObject, plane: u8) u32 {
        return if (plane == 0) self.offset else 0;
    }

    /// Opaque handle for plane `plane` (same as .handle for single-plane).
    pub fn getPlaneHandle(self: *const BufferObject, plane: u8) u32 {
        return if (plane == 0) self.handle else 0;
    }

    /// Export this buffer as a dma-buf fd. The fd is owned by the caller (caller closes it).
    /// Returns error.Unsupported if the backend does not support dmabuf export.
    pub fn exportFd(self: *BufferObject) backend.Error!DmabufExport {
        const alloc = self.allocator orelse return backend.Error.Unsupported;
        return alloc.exportFd(self);
    }

    /// Build an export descriptor from this BufferObject.
    pub fn exportDesc(self: *const BufferObject) BufferExportDesc {
        var desc = BufferExportDesc{
            .width = self.width,
            .height = self.height,
            .format = self.format,
            .modifier = self.modifier,
        };
        desc.strides[0] = self.stride;
        desc.offsets[0] = self.offset;
        desc.handles[0] = self.handle;
        return desc;
    }
};

pub fn computeStride(width: u32, bpp: u8) u32 {
    const raw: usize = @as(usize, width) * @as(usize, bpp);
    const aligned = std.mem.alignForward(usize, raw, STRIDE_ALIGNMENT);
    return @intCast(aligned);
}

pub fn computeSize(stride: u32, height: u32) usize {
    return @as(usize, stride) * @as(usize, height);
}

test "stride: 100px * 4bpp = 400 aligns to 512" {
    const stride = computeStride(100, 4);
    try std.testing.expectEqual(@as(u32, 512), stride);
}

test "stride: 64px * 4bpp = 256 stays 256 (already aligned)" {
    const stride = computeStride(64, 4);
    try std.testing.expectEqual(@as(u32, 256), stride);
}

test "stride: 1px * 4bpp = 4 aligns to 256" {
    const stride = computeStride(1, 4);
    try std.testing.expectEqual(@as(u32, 256), stride);
}

test "size: stride * height" {
    const stride = computeStride(100, 4);
    const size = computeSize(stride, 10);
    try std.testing.expectEqual(@as(usize, 512 * 10), size);
}

test "BufferObject: map returns data slice" {
    var backing = [_]u8{ 1, 2, 3, 4 };
    var bo = BufferObject{
        .width = 1,
        .height = 1,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .stride = 256,
        .size = 256,
        .data = &backing,
    };
    const slice = bo.map();
    try std.testing.expectEqual(@as(usize, 4), slice.len);
    try std.testing.expectEqual(@as(u8, 1), slice[0]);
    bo.unmap();
}

test "BufferObject: getPlaneStride/Offset/Handle plane 0" {
    var backing = [_]u8{0} ** 256;
    const bo = BufferObject{
        .width = 64,
        .height = 1,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .stride = 256,
        .size = 256,
        .data = &backing,
        .handle = 7,
        .offset = 0,
    };
    try std.testing.expectEqual(@as(u32, 256), bo.getPlaneStride(0));
    try std.testing.expectEqual(@as(u32, 0), bo.getPlaneOffset(0));
    try std.testing.expectEqual(@as(u32, 7), bo.getPlaneHandle(0));
}

test "BufferObject: getPlaneStride/Offset/Handle plane 1 returns zeros (packed format)" {
    var backing = [_]u8{0} ** 256;
    const bo = BufferObject{
        .width = 64,
        .height = 1,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .stride = 256,
        .size = 256,
        .data = &backing,
        .handle = 7,
        .offset = 0,
    };
    try std.testing.expectEqual(@as(u32, 0), bo.getPlaneStride(1));
    try std.testing.expectEqual(@as(u32, 0), bo.getPlaneOffset(1));
    try std.testing.expectEqual(@as(u32, 0), bo.getPlaneHandle(1));
}

test "BufferObject: exportDesc round-trip" {
    var backing = [_]u8{0} ** 512;
    const bo = BufferObject{
        .width = 128,
        .height = 1,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .modifier = fmt_mod.DRM_FORMAT_MOD_LINEAR,
        .stride = 512,
        .size = 512,
        .data = &backing,
        .handle = 42,
        .offset = 0,
    };
    const exp = bo.exportDesc();
    try std.testing.expectEqual(@as(u32, 128), exp.width);
    try std.testing.expectEqual(@as(u32, 1), exp.height);
    try std.testing.expectEqual(fmt_mod.DRM_FORMAT_XRGB8888, exp.format);
    try std.testing.expectEqual(fmt_mod.DRM_FORMAT_MOD_LINEAR, exp.modifier);
    try std.testing.expectEqual(@as(u32, 512), exp.strides[0]);
    try std.testing.expectEqual(@as(u32, 0), exp.offsets[0]);
    try std.testing.expectEqual(@as(u32, 42), exp.handles[0]);
}
