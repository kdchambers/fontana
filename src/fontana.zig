// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const freetype = @import("freetype.zig");
const harfbuzz = @import("harfbuzz.zig");

pub const geometry = @import("geometry.zig");
pub const Atlas = @import("Atlas.zig");

pub const ScaledGlyphMetric = struct {
    advance_x: f64,
    leftside_bearing: f64,
    descent: f64,
};

const FreetypeHarfbuzzImplementation = struct {
    const Self = @This();

    //
    // Freetype Functions
    //
    const InitFn = *const fn (*freetype.Library) callconv(.C) void;
    const DoneFn = *const fn (freetype.Library) callconv(.C) i32;
    const NewFaceFn = *const fn (freetype.Library, [*:0]const u8, i64, *freetype.Face) callconv(.C) i32;
    const GetCharIndexFn = *const fn (freetype.Face, u64) callconv(.C) u32;
    const LoadCharFn = *const fn (freetype.Face, u64, freetype.LoadFlags) callconv(.C) i32;
    const LoadGlyphFn = *const fn (freetype.Face, u32, freetype.LoadFlags) callconv(.C) i32;
    const SetCharSizeFn = *const fn (freetype.Face, freetype.F26Dot6, freetype.F26Dot6, u32, u32) callconv(.C) i32;

    //
    // Harfbuzz Functions
    //
    const HbDestroyFn = *const fn (?*void) callconv(.C) void;
    const HbFontCreateFn = *const fn (freetype.Face, ?HbDestroyFn) callconv(.C) *harfbuzz.Font;
    const HbFaceCreateFn = *const fn (freetype.Face, ?HbDestroyFn) callconv(.C) *harfbuzz.Face;
    const HbLanguageFromStringFn = *const fn ([*]const u8, i32) callconv(.C) harfbuzz.Language;
    const HbShapeFn = *const fn (*harfbuzz.Font, *harfbuzz.Buffer, ?[*]const harfbuzz.Feature, u32) callconv(.C) void;

    const HbBufferCreateFn = *const fn () callconv(.C) *harfbuzz.Buffer;
    const HbBufferGuessSegmentPropertiesFn = *const fn (*harfbuzz.Buffer) callconv(.C) void;
    const HbBufferAddUTF8Fn = *const fn (*harfbuzz.Buffer, [*]const u8, i32, u32, i32) callconv(.C) void;
    const HbBufferGetLengthFn = *const fn (*harfbuzz.Buffer) callconv(.C) u32;
    const HbBufferGetGlyphInfosFn = *const fn (*harfbuzz.Buffer, ?*u32) callconv(.C) [*]harfbuzz.GlyphInfo;
    const HbBufferGetGlyphPositionsFn = *const fn (*harfbuzz.Buffer, ?*u32) callconv(.C) [*]harfbuzz.GlyphPosition;
    const HbBufferSetDirectionFn = *const fn (*harfbuzz.Buffer, harfbuzz.Direction) callconv(.C) void;
    const HbBufferSetScriptFn = *const fn (*harfbuzz.Buffer, harfbuzz.Script) callconv(.C) void;
    const HbBufferSetLanguageFn = *const fn (*harfbuzz.Buffer, harfbuzz.Language) callconv(.C) void;
    const HbBufferDestroyFn = *const fn (*harfbuzz.Buffer) callconv(.C) void;

    initFn: InitFn,
    doneFn: DoneFn,
    newFaceFn: NewFaceFn,
    getCharIndexFn: GetCharIndexFn,
    loadCharFn: LoadCharFn,
    loadGlyphFn: LoadGlyphFn,
    setCharSizeFn: SetCharSizeFn,

    hbFontCreateFn: HbFontCreateFn,
    hbFaceCreateFn: HbFaceCreateFn,
    hbShapeFn: HbShapeFn,
    hbLanguageFromStringFn: HbLanguageFromStringFn,

    hbBufferCreateFn: HbBufferCreateFn,
    hbBufferDestroyFn: HbBufferDestroyFn,
    hbBufferAddUTF8Fn: HbBufferAddUTF8Fn,
    hbBufferGuessSegmentPropertiesFn: HbBufferGuessSegmentPropertiesFn,
    hbBufferGetLengthFn: HbBufferGetLengthFn,
    hbBufferGetGlyphInfosFn: HbBufferGetGlyphInfosFn,
    hbBufferGetGlyphPositionsFn: HbBufferGetGlyphPositionsFn,
    hbBufferSetDirectionFn: HbBufferSetDirectionFn,
    hbBufferSetScriptFn: HbBufferSetScriptFn,
    hbBufferSetLanguageFn: HbBufferSetLanguageFn,

    library: freetype.Library,
    face: freetype.Face,
    harfbuzz_font: *harfbuzz.Font,

    pub fn initFromFile(allocator: std.mem.Allocator, font_path: []const u8) !FreetypeHarfbuzzImplementation {
        var freetype_handle = DynLib.open("libfreetype.so") catch return error.LinkFreetypeFailed;
        var harfbuzz_handle = DynLib.open("libharfbuzz.so") catch return error.LinkHarfbuzzFailed;

        var impl: FreetypeHarfbuzzImplementation = undefined;

        impl.initFn = freetype_handle.lookup(Self.InitFn, "FT_Init_FreeType") orelse return error.LookupFailed;
        impl.doneFn = freetype_handle.lookup(Self.DoneFn, "FT_Done_FreeType") orelse return error.LookupFailed;
        impl.newFaceFn = freetype_handle.lookup(Self.NewFaceFn, "FT_New_Face") orelse return error.LookupFailed;

        _ = impl.initFn(&impl.library);

        const c_font_path = try allocator.dupeZ(u8, font_path);
        defer allocator.free(c_font_path);

        _ = impl.newFaceFn(impl.library, c_font_path, 0, &impl.face);

        impl.loadCharFn = freetype_handle.lookup(Self.LoadCharFn, "FT_Load_Char") orelse
            return error.LookupFailed;
        impl.loadGlyphFn = freetype_handle.lookup(Self.LoadGlyphFn, "FT_Load_Glyph") orelse
            return error.LookupFailed;
        impl.getCharIndexFn = freetype_handle.lookup(Self.GetCharIndexFn, "FT_Get_Char_Index") orelse
            return error.LookupFailed;
        impl.setCharSizeFn = freetype_handle.lookup(Self.SetCharSizeFn, "FT_Set_Char_Size") orelse
            return error.LookupFailed;
        impl.hbFontCreateFn = harfbuzz_handle.lookup(Self.HbFontCreateFn, "hb_ft_font_create") orelse
            return error.LookupFailed;

        impl.harfbuzz_font = impl.hbFontCreateFn(impl.face, null);

        impl.hbBufferCreateFn = harfbuzz_handle.lookup(Self.HbBufferCreateFn, "hb_buffer_create") orelse
            return error.LookupFailed;
        impl.hbBufferDestroyFn = harfbuzz_handle.lookup(Self.HbBufferDestroyFn, "hb_buffer_destroy") orelse
            return error.LookupFailed;
        impl.hbBufferAddUTF8Fn = harfbuzz_handle.lookup(Self.HbBufferAddUTF8Fn, "hb_buffer_add_utf8") orelse
            return error.LookupFailed;
        impl.hbShapeFn = harfbuzz_handle.lookup(Self.HbShapeFn, "hb_shape") orelse
            return error.LookupFailed;
        impl.hbBufferGetLengthFn = harfbuzz_handle.lookup(Self.HbBufferGetLengthFn, "hb_buffer_get_length") orelse
            return error.LookupFailed;
        impl.hbBufferSetDirectionFn = harfbuzz_handle.lookup(Self.HbBufferSetDirectionFn, "hb_buffer_set_direction") orelse
            return error.LookupFailed;
        impl.hbBufferSetScriptFn = harfbuzz_handle.lookup(Self.HbBufferSetScriptFn, "hb_buffer_set_script") orelse
            return error.LookupFailed;
        impl.hbBufferSetLanguageFn = harfbuzz_handle.lookup(Self.HbBufferSetLanguageFn, "hb_buffer_set_language") orelse
            return error.LookupFailed;
        impl.hbLanguageFromStringFn = harfbuzz_handle.lookup(Self.HbLanguageFromStringFn, "hb_language_from_string") orelse
            return error.LookupFailed;

        impl.hbBufferGetGlyphInfosFn = harfbuzz_handle.lookup(
            Self.HbBufferGetGlyphInfosFn,
            "hb_buffer_get_glyph_infos",
        ) orelse
            return error.LookupFailed;

        impl.hbBufferGetGlyphPositionsFn = harfbuzz_handle.lookup(
            Self.HbBufferGetGlyphPositionsFn,
            "hb_buffer_get_glyph_positions",
        ) orelse
            return error.LookupFailed;

        impl.hbBufferGuessSegmentPropertiesFn = harfbuzz_handle.lookup(
            Self.HbBufferGuessSegmentPropertiesFn,
            "hb_buffer_guess_segment_properties",
        ) orelse
            return error.LookupFailed;

        return impl;
    }

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        _ = self.doneFn(self.library);
    }
};

const FreetypeImplementation = struct {
    library: freetype.Library,
    face: freetype.Face,
};

const FontanaImplementation = struct {
    font: otf.FontInfo,
    font_scale: f64,

    pub fn initFromFile(allocator: std.mem.Allocator, font_path: []const u8) !FontanaImplementation {
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

    pub inline fn kernPairAdvance(self: *@This(), left_codepoint: u8, right_codepoint: u8) ?f64 {
        const unscaled_opt = otf.kernAdvanceGpos(&self.font, left_codepoint, right_codepoint) catch unreachable;
        if (unscaled_opt) |unscaled| {
            return @intToFloat(f64, unscaled) * self.font_scale;
        }
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
                switch (comptime backend) {
                    .freetype_harfbuzz => return self.writeFreetypeHarfbuzz(
                        codepoints,
                        placement,
                        screen_scale,
                        writer_interface,
                    ),
                    .fontana => return self.writeFontana(
                        codepoints,
                        placement,
                        screen_scale,
                        writer_interface,
                    ),
                    else => unreachable,
                }
            }

            inline fn writeFreetypeHarfbuzz(
                self: *@This(),
                codepoints: []const u8,
                placement: geometry.Coordinates2D(f64),
                screen_scale: geometry.Scale2D(f64),
                writer_interface: anytype,
            ) !void {
                var impl = self.font;
                var buffer = impl.hbBufferCreateFn();
                defer impl.hbBufferDestroyFn(buffer);
                impl.hbBufferAddUTF8Fn(buffer, codepoints.ptr, @intCast(i32, codepoints.len), 0, -1);
                impl.hbBufferSetDirectionFn(buffer, .left_to_right);
                impl.hbBufferSetScriptFn(buffer, .latin);
                const language = impl.hbLanguageFromStringFn("en", 2);
                impl.hbBufferSetLanguageFn(buffer, language);
                impl.hbBufferGuessSegmentPropertiesFn(buffer);
                impl.hbShapeFn(impl.harfbuzz_font, buffer, null, 0);
                const buffer_length = impl.hbBufferGetLengthFn(buffer);
                var position_count: u32 = 0;
                const position_list: [*]harfbuzz.GlyphPosition = impl.hbBufferGetGlyphPositionsFn(buffer, &position_count);
                std.debug.assert(position_count > 0);
                var cursor = placement;
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
                var i: usize = 0;
                while (i < buffer_length) : (i += 1) {
                    const codepoint = codepoints[i];
                    const x_advance = @intToFloat(f64, position_list[i].x_advance) / 64.0;
                    const y_advance = @intToFloat(f64, position_list[i].y_advance) / 64.0;
                    const x_offset = @intToFloat(f32, position_list[i].x_offset) / 64.0;
                    const y_offset = @intToFloat(f32, position_list[i].y_offset) / 64.0;

                    const glyph_index: u32 = impl.getCharIndexFn(impl.face, codepoint);
                    std.debug.assert(glyph_index != 0);

                    if (impl.loadGlyphFn(impl.face, glyph_index, .{}) != 0) {
                        std.log.warn("Failed to write '{c}'", .{codepoint});
                        continue;
                    }

                    const glyph = impl.face.glyph;
                    const descent = (@intToFloat(f64, glyph.metrics.height - glyph.metrics.hori_bearing_y) / 64);
                    if (codepoint != ' ') {
                        const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                        const texture_extent = geometry.Extent2D(f32){
                            .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                            .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                            .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                            .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                        };
                        const screen_extent = geometry.Extent2D(f32){
                            .x = @floatCast(f32, cursor.x + (x_offset * screen_scale.horizontal)),
                            .y = @floatCast(f32, cursor.y + ((y_offset + descent) * screen_scale.vertical)),
                            .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                            .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                        };
                        try writer_interface.write(screen_extent, texture_extent);
                    }
                    cursor.x += x_advance * screen_scale.horizontal;
                    cursor.y += y_advance * screen_scale.vertical;
                }
            }

            inline fn writeFontana(
                self: *@This(),
                codepoints: []const u8,
                placement: geometry.Coordinates2D(f64),
                screen_scale: geometry.Scale2D(f64),
                writer_interface: anytype,
            ) !void {
                var impl = self.font;
                var cursor = placement;
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
                var i: usize = 0;
                var right_codepoint_opt: ?u8 = null;
                while (i < codepoints.len) : (i += 1) {
                    const codepoint = codepoints[i];
                    if (codepoint == ' ') {
                        cursor.x += impl.font.space_advance * impl.font_scale * screen_scale.horizontal;
                        continue;
                    }
                    const glyph_metrics = self.font.glyphMetricsFromCodepoint(codepoint);
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = geometry.Extent2D(f32){
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };

                    const screen_extent = geometry.Extent2D(f32){
                        .x = @floatCast(f32, cursor.x),
                        .y = @floatCast(f32, cursor.y + (@floatCast(f32, glyph_metrics.descent) * screen_scale.vertical)),
                        .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                        .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                    const advance_x: f64 = blk: {
                        if (right_codepoint_opt) |right_codepoint| {
                            break :blk self.font.kernPairAdvance(codepoint, right_codepoint) orelse glyph_metrics.advance_x;
                        }
                        break :blk glyph_metrics.advance_x;
                    };
                    cursor.x += @floatCast(f32, advance_x * screen_scale.horizontal);
                }
            }
        };

        const BackendImplementation = switch (backend) {
            .freetype_harfbuzz => FreetypeHarfbuzzImplementation,
            .freetype => FreetypeImplementation,
            .fontana => FontanaImplementation,
        };

        internal: BackendImplementation,

        pub fn initFromFile(allocator: std.mem.Allocator, font_path: []const u8) !@This() {
            return @This(){
                .internal = try BackendImplementation.initFromFile(allocator, font_path),
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
