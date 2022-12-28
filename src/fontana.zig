// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers
const std = @import("std");
const DynLib = std.DynLib;

const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const freetype = @import("freetype.zig");

pub const geometry = @import("geometry.zig");
pub const Atlas = @import("Atlas.zig");

pub const ScaledGlyphMetric = struct {
    advance_x: f64,
    leftside_bearing: f64,
    descent: f64,
};

const FreetypeHarfbuzzImplementation = struct {
    const Self = @This();

    const InitFn = *const fn (*freetype.Library) callconv(.C) void;
    const NewFaceFn = *const fn (freetype.Library, [*:0]const u8, i64, *freetype.Face) callconv(.C) i32;
    const GetCharIndexFn = *const fn (freetype.Face, u64) callconv(.C) u32;
    const LoadCharFn = *const fn (freetype.Face, u64, freetype.LoadFlags) callconv(.C) i32;
    const LoadGlyphFn = *const fn (freetype.Face, u32, freetype.LoadFlags) callconv(.C) i32;
    const SetCharSizeFn = *const fn (freetype.Face, freetype.F26Dot6, freetype.F26Dot6, u32, u32) callconv(.C) i32;

    library: freetype.Library,
    face: freetype.Face,
    // harfbuzz_font: harfbuzz.Font,

    initFn: InitFn,
    newFaceFn: NewFaceFn,
    getCharIndexFn: GetCharIndexFn,
    loadCharFn: LoadCharFn,
    loadGlyphFn: LoadGlyphFn,
    setCharSizeFn: SetCharSizeFn,

    pub fn loadFromFile(allocator: std.mem.Allocator, font_path: []const u8) !FreetypeHarfbuzzImplementation {
        var freetype_handle = try DynLib.open("libfreetype.so");
        var impl: FreetypeHarfbuzzImplementation = undefined;

        impl.initFn = freetype_handle.lookup(Self.InitFn, "FT_Init_FreeType") orelse return error.LookupFailed;
        impl.newFaceFn = freetype_handle.lookup(Self.NewFaceFn, "FT_New_Face") orelse return error.LookupFailed;

        _ = impl.initFn(&impl.library);

        const c_font_path = try allocator.dupeZ(u8, font_path);
        defer allocator.free(c_font_path);

        _ = impl.newFaceFn(impl.library, c_font_path, 0, &impl.face);

        impl.loadCharFn = freetype_handle.lookup(Self.LoadCharFn, "FT_Load_Char") orelse return error.LookupFailed;
        impl.loadGlyphFn = freetype_handle.lookup(Self.LoadGlyphFn, "FT_Load_Glyph") orelse return error.LookupFailed;
        impl.getCharIndexFn = freetype_handle.lookup(Self.GetCharIndexFn, "FT_Get_Char_Index") orelse return error.LookupFailed;
        impl.setCharSizeFn = freetype_handle.lookup(Self.SetCharSizeFn, "FT_Set_Char_Size") orelse return error.LookupFailed;

        return impl;
    }

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.library.deinit();
    }

    pub inline fn kernPairAdvance(self: *@This()) ?f64 {
        // TODO: Implement
        _ = self;
        return null;
    }

    pub inline fn glyphMetricsFromCodepoint(self: *@This(), codepoint: u8) ScaledGlyphMetric {
        var metrics: ScaledGlyphMetric = undefined;
        // TODO: Implement Harfbuzz to get advance
        metrics.advance_x = 0.0;

        const glyph_index: u32 = self.getCharIndexFn(self.face, codepoint);
        std.debug.assert(glyph_index != 0);

        const err_code = self.loadGlyphFn(self.face, glyph_index, .{});
        std.debug.assert(err_code == 0);

        const glyph = self.face.glyph;

        metrics.leftside_bearing = @intToFloat(f64, glyph.bitmap_left);
        metrics.descent = (@intToFloat(f64, -glyph.metrics.hori_bearing_y) / 64);
        metrics.descent += @intToFloat(f64, glyph.metrics.height) / 64;

        return metrics;
    }
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
        var metrics: ScaledGlyphMetric = undefined;
        const bounding_box = otf.calculateGlyphBoundingBox(font, glyph_index) catch unreachable;
        metrics.leftside_bearing = @intToFloat(f64, otf.leftBearingForGlyph(font, glyph_index)) * self.font_scale;
        metrics.advance_x = @intToFloat(f64, otf.advanceXForGlyph(font, glyph_index)) * self.font_scale;
        metrics.descent = -@intToFloat(f64, bounding_box.y0) * self.font_scale;
        return metrics;
    }

    pub inline fn kernPairAdvance(self: *@This()) ?f64 {
        // TODO: Implement
        _ = self;
        return null;
    }
};

pub const Backend = enum {
    freetype,
    freetype_harfbuzz,
    fontana,
};

pub const SizeTag = enum {
    point,
    pixel,
};

pub const Size = union(SizeTag) {
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

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.atlas.deinit(allocator);
                allocator.free(self.atlas_entries);
                self.font = undefined;
                self.atlas_entries_count = 0;
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
                    const glyph_metrics = self.font.glyphMetricsFromCodepoint(codepoint);

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

                    cursor.x += glyph_metrics.leftside_bearing * screen_scale.horizontal;
                    const screen_extent = geometry.Extent2D(f32){
                        .x = @floatCast(f32, cursor.x),
                        .y = @floatCast(f32, cursor.y + (@floatCast(f32, glyph_metrics.descent) * screen_scale.vertical)),
                        .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                        .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                    const advance_x: f64 = self.font.kernPairAdvance() orelse glyph_metrics.advance_x;
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
            self.internal.deinit(allocator);
        }

        inline fn createPenFontana(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size_point: f64,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
        ) !Pen {
            const font: *otf.FontInfo = &self.internal.font;
            self.internal.font_scale = otf.fUnitToPixelScale(size_point, points_per_pixel, font.units_per_em);
            var pen: Pen = undefined;
            pen.font = &self.internal;
            pen.atlas = try Atlas.init(allocator, texture_size);
            pen.atlas_entries = try allocator.alloc(geometry.Extent2D(u32), 64);
            pen.codepoints = codepoints;
            const funit_to_pixel = otf.fUnitToPixelScale(size_point, points_per_pixel, font.units_per_em);
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

        inline fn createPenFreetypeHarfbuzz(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size_point: f64,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
        ) !Pen {
            const face = self.internal.face;
            _ = self.internal.setCharSizeFn(
                self.internal.face,
                0,
                @floatToInt(i32, size_point * 64),
                @floatToInt(u32, points_per_pixel),
                @floatToInt(u32, points_per_pixel),
            );
            var pen: Pen = undefined;
            pen.font = &self.internal;
            pen.atlas = try Atlas.init(allocator, texture_size);
            pen.atlas_entries = try allocator.alloc(geometry.Extent2D(u32), 64);
            pen.codepoints = codepoints;
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.internal.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                std.debug.assert(err_code == 0);
                const bitmap = face.glyph.bitmap;
                const bitmap_height = bitmap.rows;
                const bitmap_width = bitmap.width;
                pen.atlas_entries[codepoint_i] = try pen.atlas.reserve(
                    allocator,
                    bitmap_width,
                    bitmap_height,
                );
                const placement = pen.atlas_entries[codepoint_i];
                const bitmap_pixels: [*]const u8 = bitmap.buffer;
                var y: usize = 0;
                while (y < bitmap_height) : (y += 1) {
                    var x: usize = 0;
                    while (x < bitmap_width) : (x += 1) {
                        const value = @intToFloat(f32, bitmap_pixels[x + (y * bitmap_width)]) / 255;
                        const index: usize = (placement.x + x) + ((y + placement.y) * texture_size);
                        // TODO: Detect type using comptime
                        const use_transparency: bool = @hasField(PixelType, "a");
                        if (@hasField(PixelType, "r"))
                            texture_pixels[index].r = if (use_transparency) 0.8 else value;

                        if (@hasField(PixelType, "g"))
                            texture_pixels[index].g = if (use_transparency) 0.8 else value;

                        if (@hasField(PixelType, "b"))
                            texture_pixels[index].b = if (use_transparency) 0.8 else value;

                        if (use_transparency) {
                            texture_pixels[index].a = value;
                        }
                    }
                }
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
            // TODO: Convert point to pixel, etc
            return switch (backend) {
                .fontana => self.createPenFontana(
                    PixelType,
                    allocator,
                    size.point,
                    points_per_pixel,
                    codepoints,
                    texture_size,
                    texture_pixels,
                ),
                .freetype_harfbuzz => self.createPenFreetypeHarfbuzz(
                    PixelType,
                    allocator,
                    size.point,
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
