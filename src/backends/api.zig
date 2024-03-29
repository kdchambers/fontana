// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

pub const OverridableTypes = struct {
    // x, y, width, height in pixel units
    Extent2DPixel: type = geometry.Extent2D(u32),
    // x, y, width, height in screen units
    Extent2DNative: type = geometry.Extent2D(f32),
    // x, y in screen units
    Coordinates2DNative: type = geometry.Coordinates2D(f32),
    // horizontal, vertical scaler value to convert pixel to screen units
    Scale2D: type = geometry.Scale2D(f64),
    Dimensions2DNative: type = geometry.Dimensions2D(f32),
};

pub const FontOptions = struct {
    type_overrides: OverridableTypes = .{},
};

pub const SupportedPixelFormat = enum {
    r8,
    r32,
    r8g8b8,
    r8g8b8a8,
    r32g32b32a32,
};

pub const PenOptions = struct {
    pixel_format: SupportedPixelFormat,
    PixelType: ?type = null,
};

pub const PenConfigOptionsInternal = struct {
    const Types = struct {
        //
        // No defaults as we expect this to be populated by FontConfig
        //
        Extent2DPixel: type,
        Extent2DNative: type,
        Coordinates2DNative: type,
        Scale2D: type,
        Pixel: type,
        Dimensions2DNative: type,
    };
    BackendType: type,
    type_overrides: Types,
    pixel_format: SupportedPixelFormat,
};

pub fn validatePixelFormat(comptime PixelType: anytype, comptime pixel_format: SupportedPixelFormat) bool {
    _ = PixelType;
    _ = pixel_format;
    return true;
}
