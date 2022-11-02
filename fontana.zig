// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers
const std = @import("std");

pub const otf = @import("src/otf.zig");
pub const rasterizer = @import("src/rasterizer.zig");
pub const geometry = @import("src/geometry.zig");
pub const graphics = @import("src/graphics.zig");

//
// Exported C API
//

pub export fn otfParseFromBytes(byte_array: [*]u8, len: u32, out_font: *otf.FontInfo) i32 {
    out_font.* = otf.parseFromBytes(byte_array[0..len]) catch return -1;
    return 0;
}

pub export fn otfRasterizeGlyph(font: *otf.FontInfo, scale: f32, codepoint: i32, out_bitmap: *otf.Bitmap) i32 {
    out_bitmap.* = otf.rasterizeGlyph(std.heap.c_allocator, font.*, scale, codepoint) catch return -1;
    return 0;
}

pub export fn otfScaleForPixelHeight(font: otf.FontInfo, height: f32) f32 {
    return otf.scaleForPixelHeight(font, height);
}
