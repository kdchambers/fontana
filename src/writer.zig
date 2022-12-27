// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const otf = @import("otf.zig");
const geometry = @import("geometry.zig");

pub fn drawText(
    codepoints: []const u8,
    placement: geometry.Coordinates2D(f64),
    scale_factor: geometry.Scale2D(f64),
    point_size: f64,
    writer_interface: anytype,
    font_interface: anytype,
) !void {
    var cursor = placement;

    font_interface.setSizePoint(point_size);
    const texture_dimensions = font_interface.textureDimensions();
    const texture_width = @intToFloat(f32, texture_dimensions.width);
    const texture_height = @intToFloat(f32, texture_dimensions.height);
    var i: usize = 0;
    while (i < codepoints.len) : (i += 1) {
        const codepoint = codepoints[i];
        if (codepoint == 0 or codepoint == 255 or codepoint == 254) {
            continue;
        }

        if (codepoint == ' ') {
            cursor.x += 0.1 * scale_factor.horizontal;
            continue;
        }

        const glyph_texture_extent = font_interface.textureExtentFromIndex(codepoint);
        const glyph_info = font_interface.glyphMetricsFromCodepoint(codepoint);
        const texture_extent = geometry.Extent2D(f32){
            .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width,
            .y = @intToFloat(f32, glyph_texture_extent.y) / texture_height,
            .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width,
            .height = @intToFloat(f32, glyph_texture_extent.height) / texture_height,
        };

        std.debug.assert(texture_extent.x >= 0.0);
        std.debug.assert(texture_extent.x <= 1.0);
        std.debug.assert(texture_extent.y >= 0.0);
        std.debug.assert(texture_extent.y <= 1.0);
        std.debug.assert(texture_extent.width <= 1.0);
        std.debug.assert(texture_extent.height <= 1.0);

        cursor.x += glyph_info.leftside_bearing * scale_factor.horizontal;
        const screen_extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, cursor.x),
            .y = @floatCast(f32, cursor.y + (@floatCast(f32, glyph_info.decent) * scale_factor.vertical)),
            .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * scale_factor.horizontal),
            .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * scale_factor.vertical),
        };
        try writer_interface.write(screen_extent, texture_extent);
        const advance_x: f64 = font_interface.kernPairAdvance() orelse glyph_info.advance_x;
        cursor.x += @floatCast(f32, advance_x * scale_factor.horizontal);

        std.debug.assert(cursor.x >= -1.0);
        std.debug.assert(cursor.x <= 1.0);
        std.debug.assert(cursor.y <= 1.0);
        std.debug.assert(cursor.y >= -1.0);
    }
}
