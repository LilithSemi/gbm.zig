const std = @import("std");
const fmt_mod = @import("format.zig");
const buf_mod = @import("buffer.zig");

pub const Error = error{ OutOfMemory, Unsupported, InvalidArgument };

pub const VTable = struct {
    allocate: *const fn (ptr: *anyopaque, desc: buf_mod.BufferDesc) Error!*buf_mod.BufferObject,
    free: *const fn (ptr: *anyopaque, bo: *buf_mod.BufferObject) void,
};

pub const Allocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn allocate(self: Allocator, desc: buf_mod.BufferDesc) Error!*buf_mod.BufferObject {
        return self.vtable.allocate(self.ptr, desc);
    }

    pub fn free(self: Allocator, bo: *buf_mod.BufferObject) void {
        self.vtable.free(self.ptr, bo);
    }
};

pub const MemoryBackend = struct {
    gpa: std.mem.Allocator,

    const vtable = VTable{
        .allocate = memAllocate,
        .free = memFree,
    };

    pub fn init(gpa: std.mem.Allocator) MemoryBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryBackend) void {
        _ = self;
    }

    pub fn allocator(self: *MemoryBackend) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn memAllocate(ptr: *anyopaque, desc: buf_mod.BufferDesc) Error!*buf_mod.BufferObject {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));

        const bpp = fmt_mod.bytesPerPixel(desc.format) orelse return Error.Unsupported;
        if (desc.width == 0 or desc.height == 0) return Error.InvalidArgument;

        const stride = buf_mod.computeStride(desc.width, bpp);
        const size = buf_mod.computeSize(stride, desc.height);

        const data = self.gpa.alloc(u8, size) catch return Error.OutOfMemory;
        errdefer self.gpa.free(data);

        const bo = self.gpa.create(buf_mod.BufferObject) catch return Error.OutOfMemory;
        bo.* = .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .modifier = desc.modifier,
            .stride = stride,
            .size = size,
            .data = data,
        };
        return bo;
    }

    fn memFree(ptr: *anyopaque, bo: *buf_mod.BufferObject) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.gpa.free(bo.data);
        self.gpa.destroy(bo);
    }
};

test "MemoryBackend: alloc->map->write pixel->read->free" {
    var mb = MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    const alloc = mb.allocator();

    const desc = buf_mod.BufferDesc{
        .width = 100,
        .height = 50,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .modifier = fmt_mod.DRM_FORMAT_MOD_LINEAR,
        .usage = .{ .scanout = true },
    };

    const bo = try alloc.allocate(desc);
    defer alloc.free(bo);

    try std.testing.expectEqual(@as(u32, 100), bo.width);
    try std.testing.expectEqual(fmt_mod.DRM_FORMAT_MOD_LINEAR, bo.modifier);
    try std.testing.expectEqual(@as(u32, 50), bo.height);
    try std.testing.expectEqual(@as(u32, 512), bo.stride);
    try std.testing.expectEqual(@as(usize, 512 * 50), bo.size);

    const pixels = bo.map();
    // Write a pixel at (0,0): XRGB 0x00FF0000 (red, little-endian: B G R X)
    pixels[0] = 0x00; // B
    pixels[1] = 0x00; // G
    pixels[2] = 0xFF; // R
    pixels[3] = 0x00; // X
    bo.unmap();

    // Read it back
    const readback = bo.map();
    try std.testing.expectEqual(@as(u8, 0x00), readback[0]);
    try std.testing.expectEqual(@as(u8, 0x00), readback[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), readback[2]);
    try std.testing.expectEqual(@as(u8, 0x00), readback[3]);
    bo.unmap();
}

test "MemoryBackend: unsupported format returns error" {
    var mb = MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    const alloc = mb.allocator();

    const desc = buf_mod.BufferDesc{
        .width = 64,
        .height = 64,
        .format = 0xdeadbeef,
        .usage = .{},
    };
    const result = alloc.allocate(desc);
    try std.testing.expectError(Error.Unsupported, result);
}

test "MemoryBackend: zero dimension returns error" {
    var mb = MemoryBackend.init(std.testing.allocator);
    defer mb.deinit();
    const alloc = mb.allocator();

    const desc = buf_mod.BufferDesc{
        .width = 0,
        .height = 64,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .usage = .{},
    };
    const result = alloc.allocate(desc);
    try std.testing.expectError(Error.InvalidArgument, result);
}
