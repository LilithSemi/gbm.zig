const std = @import("std");

pub fn fourcc(s: *const [4]u8) u32 {
    return @as(u32, s[0]) |
        (@as(u32, s[1]) << 8) |
        (@as(u32, s[2]) << 16) |
        (@as(u32, s[3]) << 24);
}

// 32-bit formats
pub const DRM_FORMAT_XRGB8888: u32 = fourcc("XR24");
pub const DRM_FORMAT_ARGB8888: u32 = fourcc("AR24");
pub const DRM_FORMAT_XBGR8888: u32 = fourcc("XB24");
pub const DRM_FORMAT_ABGR8888: u32 = fourcc("AB24");

// 10-bit formats
pub const DRM_FORMAT_XRGB2101010: u32 = fourcc("XR30");
pub const DRM_FORMAT_ARGB2101010: u32 = fourcc("AR30");

// 16-bit formats
pub const DRM_FORMAT_RGB565: u32 = fourcc("RG16");
pub const DRM_FORMAT_BGR565: u32 = fourcc("BG16");

// Planar YUV formats (bytes-per-pixel is undefined for planar, bytesPerPixel returns null)
pub const DRM_FORMAT_NV12: u32 = fourcc("NV12");
pub const DRM_FORMAT_YUV420: u32 = fourcc("YU12");

// Modifier constants
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

// Modifier vendor IDs (top byte of the 56-bit modifier field)
pub const DRM_FORMAT_MOD_VENDOR_NONE: u8 = 0;
pub const DRM_FORMAT_MOD_VENDOR_INTEL: u8 = 0x01;
pub const DRM_FORMAT_MOD_VENDOR_AMD: u8 = 0x02;
pub const DRM_FORMAT_MOD_VENDOR_NVIDIA: u8 = 0x03;
pub const DRM_FORMAT_MOD_VENDOR_SAMSUNG: u8 = 0x04;
pub const DRM_FORMAT_MOD_VENDOR_QCOM: u8 = 0x05;
pub const DRM_FORMAT_MOD_VENDOR_VIVANTE: u8 = 0x06;
pub const DRM_FORMAT_MOD_VENDOR_BROADCOM: u8 = 0x07;
pub const DRM_FORMAT_MOD_VENDOR_ARM: u8 = 0x08;
pub const DRM_FORMAT_MOD_VENDOR_ALLWINNER: u8 = 0x09;
pub const DRM_FORMAT_MOD_VENDOR_AMLOGIC: u8 = 0x0a;

/// Extract the vendor field from a DRM format modifier.
/// The top 8 bits of the modifier encode the vendor.
pub fn modifierVendor(mod: u64) u8 {
    return @intCast((mod >> 56) & 0xff);
}

pub fn modifierIsLinear(mod: u64) bool {
    return mod == DRM_FORMAT_MOD_LINEAR;
}

pub fn modifierIsValid(mod: u64) bool {
    return mod != DRM_FORMAT_MOD_INVALID;
}

pub fn bytesPerPixel(fmt: u32) ?u8 {
    return switch (fmt) {
        DRM_FORMAT_XRGB8888,
        DRM_FORMAT_ARGB8888,
        DRM_FORMAT_XBGR8888,
        DRM_FORMAT_ABGR8888,
        DRM_FORMAT_XRGB2101010,
        DRM_FORMAT_ARGB2101010,
        => 4,
        DRM_FORMAT_RGB565,
        DRM_FORMAT_BGR565,
        => 2,
        // Planar formats: no single bpp value
        else => null,
    };
}

test "fourcc: known hex values" {
    try std.testing.expectEqual(@as(u32, 0x34325258), DRM_FORMAT_XRGB8888);
    try std.testing.expectEqual(@as(u32, 0x34325241), DRM_FORMAT_ARGB8888);
    try std.testing.expectEqual(@as(u32, 0x34324258), DRM_FORMAT_XBGR8888);
    try std.testing.expectEqual(@as(u32, 0x34324241), DRM_FORMAT_ABGR8888);
}

test "fourcc: modifier constants" {
    try std.testing.expectEqual(@as(u64, 0), DRM_FORMAT_MOD_LINEAR);
    try std.testing.expectEqual(@as(u64, 0x00ffffffffffffff), DRM_FORMAT_MOD_INVALID);
}

test "bytesPerPixel: known formats" {
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_XRGB8888));
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_ARGB8888));
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_XBGR8888));
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_ABGR8888));
    try std.testing.expectEqual(@as(?u8, null), bytesPerPixel(0xdeadbeef));
}

test "bytesPerPixel: RGB565 is 2" {
    try std.testing.expectEqual(@as(?u8, 2), bytesPerPixel(DRM_FORMAT_RGB565));
    try std.testing.expectEqual(@as(?u8, 2), bytesPerPixel(DRM_FORMAT_BGR565));
}

test "bytesPerPixel: 10-bit formats are 4" {
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_XRGB2101010));
    try std.testing.expectEqual(@as(?u8, 4), bytesPerPixel(DRM_FORMAT_ARGB2101010));
}

test "bytesPerPixel: planar formats are null" {
    try std.testing.expectEqual(@as(?u8, null), bytesPerPixel(DRM_FORMAT_NV12));
    try std.testing.expectEqual(@as(?u8, null), bytesPerPixel(DRM_FORMAT_YUV420));
}

test "modifierVendor: LINEAR has vendor NONE" {
    try std.testing.expectEqual(@as(u8, DRM_FORMAT_MOD_VENDOR_NONE), modifierVendor(DRM_FORMAT_MOD_LINEAR));
}

test "modifierVendor: AMD vendor encoding" {
    // Construct a modifier with vendor AMD in top byte
    const amd_mod: u64 = (@as(u64, DRM_FORMAT_MOD_VENDOR_AMD) << 56) | 0x1;
    try std.testing.expectEqual(@as(u8, DRM_FORMAT_MOD_VENDOR_AMD), modifierVendor(amd_mod));
}

test "modifierIsLinear: linear is true, invalid is false" {
    try std.testing.expect(modifierIsLinear(DRM_FORMAT_MOD_LINEAR));
    try std.testing.expect(!modifierIsLinear(DRM_FORMAT_MOD_INVALID));
}

test "modifierIsValid: linear is valid, invalid is not" {
    try std.testing.expect(modifierIsValid(DRM_FORMAT_MOD_LINEAR));
    try std.testing.expect(!modifierIsValid(DRM_FORMAT_MOD_INVALID));
}
