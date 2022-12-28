// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers
const std = @import("std");

const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");

pub const geometry = @import("geometry.zig");
pub const Atlas = @import("Atlas.zig");

pub const ScaledGlyphMetric = struct {
    advance_x: f64,
    leftside_bearing: f64,
    descent: f64,
};

const FreetypeHarfbuzzImplementation = struct {
    library: freetype.Library,
    face: freetype.Face,
    hardbuzz_font: harfbuzz.Font,
};

const FreetypeImplementation = struct {
    library: freetype.Library,
    face: freetype.Face,
};

const FontanaImplementation = struct {
    font: otf.FontInfo,
    font_scale: f64,

    pub fn loadFromFile(allocator: std.mem.Allocator, font_path: []const u8) !FontanaImplementation {
        return FontanaImplementation{
            .font = try otf.loadFromFile(allocator, font_path),
            .font_scale = undefined,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.font.deinit(allocator);
    }

    pub inline fn glyphMetricsFromCodepoint(self: *@This(), codepoint: u8) ScaledGlyphMetric {
        const font = &self.font;
        const glyph_index = otf.findGlyphIndex(font, codepoint);
        var glyph_info: ScaledGlyphMetric = undefined;
        const bounding_box = otf.calculateGlyphBoundingBox(font, glyph_index) catch unreachable;
        glyph_info.leftside_bearing = @intToFloat(f64, otf.leftBearingForGlyph(font, glyph_index)) * self.font_scale;
        glyph_info.advance_x = @intToFloat(f64, otf.advanceXForGlyph(font, glyph_index)) * self.font_scale;
        glyph_info.descent = -@intToFloat(f64, bounding_box.y0) * self.font_scale;
        return glyph_info;
    }

    pub inline fn kernPairAdvance(self: *@This()) ?f64 {
        // TODO: Implement
        _ = self;
        return null;
    }
};

const Backend = enum {
    freetype,
    freetype_harfbuzz,
    fontana,
};

const SizeTag = enum {
    point,
    pixel,
};

const Size = union(SizeTag) {
    point: f64,
    pixel: f64,
};

pub fn Font(comptime backend: Backend) type {
    return struct {
        pub const Pen = struct {
            font: *BackendImplementation,
            atlas: Atlas,
            codepoints: []const u8,
            atlas_entries: []geometry.Extent2D(u32),
            atlas_entries_count: u32,

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.atlas.deinit(allocator);
                allocator.free(self.atlas_entries);
            }

            inline fn textureExtentFromCodepoint(self: *@This(), codepoint: u8) geometry.Extent2D(u32) {
                const atlas_index = blk: {
                    var i: usize = 0;
                    while (i < self.atlas_entries_count) : (i += 1) {
                        const current_codepoint = self.codepoints[i];
                        if (current_codepoint == codepoint) break :blk i;
                    }
                    unreachable;
                };
                return self.atlas_entries[atlas_index];
            }

            pub fn write(
                self: *@This(),
                codepoints: []const u8,
                placement: geometry.Coordinates2D(f64),
                screen_scale: geometry.Scale2D(f64),
                writer_interface: anytype,
            ) !void {
                var cursor = placement;
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
                var i: usize = 0;
                while (i < codepoints.len) : (i += 1) {
                    const codepoint = codepoints[i];
                    if (codepoint == ' ') {
                        cursor.x += 0.1 * screen_scale.horizontal;
                        continue;
                    }

                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const glyph_info = self.font.glyphMetricsFromCodepoint(codepoint);

                    const texture_extent = geometry.Extent2D(f32){
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };

                    std.debug.assert(texture_extent.x >= 0.0);
                    std.debug.assert(texture_extent.x <= 1.0);
                    std.debug.assert(texture_extent.y >= 0.0);
                    std.debug.assert(texture_extent.y <= 1.0);
                    std.debug.assert(texture_extent.width <= 1.0);
                    std.debug.assert(texture_extent.height <= 1.0);

                    cursor.x += glyph_info.leftside_bearing * screen_scale.horizontal;
                    const screen_extent = geometry.Extent2D(f32){
                        .x = @floatCast(f32, cursor.x),
                        .y = @floatCast(f32, cursor.y + (@floatCast(f32, glyph_info.descent) * screen_scale.vertical)),
                        .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                        .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                    const advance_x: f64 = self.font.kernPairAdvance() orelse glyph_info.advance_x;
                    cursor.x += @floatCast(f32, advance_x * screen_scale.horizontal);

                    std.debug.assert(cursor.x >= -1.0);
                    std.debug.assert(cursor.x <= 1.0);
                    std.debug.assert(cursor.y <= 1.0);
                    std.debug.assert(cursor.y >= -1.0);
                }
            }
        };

        const BackendImplementation = switch (backend) {
            .freetype_harfbuzz => FreetypeHarfbuzzImplementation,
            .freetype => FreetypeImplementation,
            .fontana => FontanaImplementation,
        };

        internal: BackendImplementation,

        pub fn loadFromFile(allocator: std.mem.Allocator, font_path: []const u8) !@This() {
            return @This(){
                .internal = try BackendImplementation.loadFromFile(allocator, font_path),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.deinit(allocator);
        }

        inline fn createPenFontana(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size: Size,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
        ) !Pen {
            // TODO: Convert point to pixel, etc
            const font: *otf.FontInfo = &self.internal.font;
            self.internal.font_scale = otf.fUnitToPixelScale(size.point, points_per_pixel, font.units_per_em);
            var pen: Pen = undefined;
            pen.font = &self.internal;
            pen.atlas = try Atlas.init(allocator, texture_size);
            pen.atlas_entries = try allocator.alloc(geometry.Extent2D(u32), 64);
            pen.codepoints = codepoints;
            const funit_to_pixel = otf.fUnitToPixelScale(size.point, points_per_pixel, font.units_per_em);
            for (codepoints) |codepoint, codepoint_i| {
                const required_dimensions = try otf.getRequiredDimensions(font, codepoint, funit_to_pixel);
                pen.atlas_entries[codepoint_i] = try pen.atlas.reserve(
                    allocator,
                    required_dimensions.width,
                    required_dimensions.height,
                );
                var pixel_writer = rasterizer.SubTexturePixelWriter(PixelType){
                    .texture_width = texture_size,
                    .pixels = texture_pixels,
                    .write_extent = pen.atlas_entries[codepoint_i],
                };
                try otf.rasterizeGlyph(allocator, pixel_writer, font, @floatCast(f32, funit_to_pixel), codepoint);
            }
            return pen;
        }

        pub fn createPen(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size: Size,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
        ) !Pen {
            return switch (backend) {
                .fontana => self.createPenFontana(
                    PixelType,
                    allocator,
                    size,
                    points_per_pixel,
                    codepoints,
                    texture_size,
                    texture_pixels,
                ),
                else => unreachable,
            };
        }
    };
}
