//! NVIDIA-RM-backed GBM allocator: allocates device VRAM via the NVIDIA open
//! kernel module (subproject/nvidia) and CPU-maps it, so buffers are real GPU
//! memory you can upload pixels into. Zero C deps.
//!
//! Third gbm backend alongside MemoryBackend and DrmBackend, same Allocator
//! vtable. NOTE: the RM keeps one mmap context per fd, so this backend maps all
//! buffers through the device node and supports one active CPU mapping at a
//! time; a fuller impl would open a dedicated fd per buffer.

const std = @import("std");
const nvidia = @import("nvidia");
const fmt_mod = @import("format.zig");
const buf_mod = @import("buffer.zig");
const backend = @import("backend.zig");

pub const NvidiaBackend = struct {
    gpa: std.mem.Allocator,
    client: nvidia.Client,
    device: nvidia.Device,
    /// Each bo's CPU mapping (it owns a dedicated fd that must be closed on free).
    mappings: std.AutoHashMapUnmanaged(*buf_mod.BufferObject, nvidia.Mapping) = .empty,

    const vtable = backend.VTable{
        .allocate = nvAllocate,
        .free = nvFree,
    };

    /// Open the RM and bring up GPU 0. Returns error.NoDevice when no NVIDIA GPU
    /// is reachable.
    pub fn open(gpa: std.mem.Allocator) !NvidiaBackend {
        var client = nvidia.Client.open() catch return error.NoDevice;
        errdefer client.deinit();
        const device = client.allocDevice(0) catch return error.NoDevice;
        return .{ .gpa = gpa, .client = client, .device = device };
    }

    pub fn deinit(self: *NvidiaBackend) void {
        self.mappings.deinit(self.gpa);
        self.client.freeDevice(self.device);
        self.client.deinit();
    }

    pub fn allocator(self: *NvidiaBackend) backend.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn nvAllocate(ptr: *anyopaque, desc: buf_mod.BufferDesc) backend.Error!*buf_mod.BufferObject {
        const self: *NvidiaBackend = @ptrCast(@alignCast(ptr));

        const bpp = fmt_mod.bytesPerPixel(desc.format) orelse return backend.Error.Unsupported;
        if (desc.width == 0 or desc.height == 0) return backend.Error.InvalidArgument;

        const stride = buf_mod.computeStride(desc.width, bpp);
        const size = buf_mod.computeSize(stride, desc.height);

        const mem = self.client.allocMemory(self.device, .vram, size) catch return backend.Error.OutOfMemory;
        errdefer self.client.freeMemory(self.device, mem);
        const map = self.client.mapMemory(self.device, mem) catch return backend.Error.OutOfMemory;

        const bo = self.gpa.create(buf_mod.BufferObject) catch {
            self.client.unmapMemory(map);
            return backend.Error.OutOfMemory;
        };
        errdefer self.gpa.destroy(bo);
        // Remember the mapping (with its dedicated fd) so free can release it.
        self.mappings.put(self.gpa, bo, map) catch {
            self.client.unmapMemory(map);
            return backend.Error.OutOfMemory;
        };
        bo.* = .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .modifier = fmt_mod.DRM_FORMAT_MOD_LINEAR,
            .stride = @intCast(stride),
            .size = size,
            .data = map.bytes, // CPU-mapped VRAM
            .handle = mem.handle,
        };
        return bo;
    }

    fn nvFree(ptr: *anyopaque, bo: *buf_mod.BufferObject) void {
        const self: *NvidiaBackend = @ptrCast(@alignCast(ptr));
        // Release the bo's CPU mapping (closing its fd), then the memory object.
        if (self.mappings.fetchRemove(bo)) |kv| self.client.unmapMemory(kv.value);
        self.client.freeMemory(self.device, .{ .handle = bo.handle, .size = bo.size, .location = .vram });
        self.gpa.destroy(bo);
    }
};

test "live: NVIDIA backend allocates + maps a GPU buffer" {
    const device = @import("device.zig");
    var be = NvidiaBackend.open(std.testing.allocator) catch return error.SkipZigTest;
    defer be.deinit();
    var dev = device.Device.init(be.allocator());

    const bo = dev.create(.{
        .width = 64,
        .height = 64,
        .format = fmt_mod.DRM_FORMAT_XRGB8888,
        .usage = .{ .rendering = true },
    }) catch |e| switch (e) {
        backend.Error.OutOfMemory => return error.SkipZigTest,
        else => return e,
    };
    defer dev.destroy(bo);

    try std.testing.expect(bo.handle != 0);
    try std.testing.expect(bo.data.len >= bo.size);
    try std.testing.expect(bo.stride >= 64 * 4);

    // Round-trip the CPU through the mapped GPU buffer.
    bo.data[0] = 0x42;
    bo.data[bo.size - 1] = 0x99;
    try std.testing.expectEqual(@as(u8, 0x42), bo.data[0]);
    try std.testing.expectEqual(@as(u8, 0x99), bo.data[bo.size - 1]);
}
