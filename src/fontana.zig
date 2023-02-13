// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const freetype = @import("freetype.zig");
const harfbuzz = @import("harfbuzz.zig");

pub const Atlas = @import("Atlas.zig");

pub const ScaledGlyphMetric = struct {
    advance_x: f64,
    leftside_bearing: f64,
    descent: f64,
    height: f64,
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
    const HbFontSetFuncsFn = *const fn (font: *harfbuzz.Font) callconv(.C) void;
    const HbFontChangedFn = *const fn (font: *harfbuzz.Font) callconv(.C) void;
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
    hbFontSetFuncs: HbFontSetFuncsFn,
    hbFontChanged: HbFontChangedFn,
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

        _ = impl.setCharSizeFn(
            impl.face,
            0,
            @floatToInt(i32, 16 * 64),
            @floatToInt(u32, 96),
            @floatToInt(u32, 96),
        );

        impl.hbFontCreateFn = harfbuzz_handle.lookup(Self.HbFontCreateFn, "hb_ft_font_create_referenced") orelse
            return error.LookupFailed;
        impl.hbFontSetFuncs = harfbuzz_handle.lookup(Self.HbFontSetFuncsFn, "hb_ft_font_set_funcs") orelse
            return error.LookupFailed;
        impl.hbFontChanged = harfbuzz_handle.lookup(Self.HbFontChangedFn, "hb_ft_font_changed") orelse
            return error.LookupFailed;

        impl.harfbuzz_font = impl.hbFontCreateFn(impl.face, null);
        // impl.hbFontSetFuncs(impl.harfbuzz_font);

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
    const Self = @This();

    const InitFn = *const fn (*freetype.Library) callconv(.C) void;
    const DoneFn = *const fn (freetype.Library) callconv(.C) i32;
    const NewFaceFn = *const fn (freetype.Library, [*:0]const u8, i64, *freetype.Face) callconv(.C) i32;
    const GetCharIndexFn = *const fn (freetype.Face, u64) callconv(.C) u32;
    const LoadCharFn = *const fn (freetype.Face, u64, freetype.LoadFlags) callconv(.C) i32;
    const LoadGlyphFn = *const fn (freetype.Face, u32, freetype.LoadFlags) callconv(.C) i32;
    const SetCharSizeFn = *const fn (freetype.Face, freetype.F26Dot6, freetype.F26Dot6, u32, u32) callconv(.C) i32;

    initFn: InitFn,
    doneFn: DoneFn,
    newFaceFn: NewFaceFn,
    getCharIndexFn: GetCharIndexFn,
    loadCharFn: LoadCharFn,
    loadGlyphFn: LoadGlyphFn,
    setCharSizeFn: SetCharSizeFn,

    library: freetype.Library,
    face: freetype.Face,

    pub fn initFromFile(allocator: std.mem.Allocator, font_path: []const u8) !FreetypeImplementation {
        var freetype_handle = DynLib.open("libfreetype.so") catch return error.LinkFreetypeFailed;

        var impl: FreetypeImplementation = undefined;

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

        return impl;
    }

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        _ = self.doneFn(self.library);
    }
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
        metrics.height = @intToFloat(f64, bounding_box.y1 - bounding_box.y0) * self.font_scale;
        std.debug.assert(metrics.height >= 0);
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

pub const Types = struct {
    Extent2DPixel: type,
    Extent2DNative: type,
    Coordinates2DNative: type,
    Scale2D: type,
};

pub fn Font(comptime backend: Backend, comptime types: Types) type {
    return struct {
        pub const Pen = struct {
            font: *BackendImplementation,
            atlas: *Atlas,
            codepoints: []const u8,
            atlas_entries: []types.Extent2DPixel,
            atlas_entries_count: u32,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.atlas_entries);
                self.font = undefined;
                self.atlas_entries_count = 0;
            }

            inline fn textureExtentFromCodepoint(self: *@This(), codepoint: u8) types.Extent2DPixel {
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
                placement: types.Coordinates2DNative,
                screen_scale: types.Scale2D,
                writer_interface: anytype,
            ) !void {
                switch (comptime backend) {
                    .freetype => return self.writeFreetype(
                        codepoints,
                        placement,
                        screen_scale,
                        writer_interface,
                    ),
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
                }
            }

            pub fn writeCentered(
                self: *@This(),
                codepoints: []const u8,
                placement_extent: types.Extent2DNative,
                screen_scale: types.Scale2D,
                writer_interface: anytype,
            ) !void {
                switch (comptime backend) {
                    .freetype_harfbuzz => return self.writeCenteredFreetypeHarfbuzz(
                        codepoints,
                        placement_extent,
                        screen_scale,
                        writer_interface,
                    ),
                    .fontana => return self.writeCenteredFontana(
                        codepoints,
                        placement_extent,
                        screen_scale,
                        writer_interface,
                    ),
                    else => unreachable,
                }
            }

            pub fn writeCenteredFontana(
                self: *@This(),
                codepoints: []const u8,
                placement_extent: types.Extent2DNative,
                screen_scale: types.Scale2D,
                writer_interface: anytype,
            ) !void {
                var impl = self.font;
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
                var i: usize = 0;
                var right_codepoint_opt: ?u8 = null;
                var descent_max: f64 = 0;
                var ascender_max: f64 = 0;
                var total_width: f64 = 0;
                while (i < codepoints.len) : (i += 1) {
                    const codepoint = codepoints[i];
                    if (codepoint == ' ') {
                        total_width += impl.font.space_advance * impl.font_scale;
                        continue;
                    }
                    const glyph_metrics = self.font.glyphMetricsFromCodepoint(codepoint);
                    descent_max = @max(descent_max, glyph_metrics.descent);
                    ascender_max = @max(ascender_max, glyph_metrics.height - glyph_metrics.descent);
                    const advance_x: f64 = blk: {
                        if (right_codepoint_opt) |right_codepoint| {
                            break :blk self.font.kernPairAdvance(codepoint, right_codepoint) orelse glyph_metrics.advance_x;
                        }
                        break :blk glyph_metrics.advance_x;
                    };
                    total_width += advance_x;
                }
                //
                // On the last codepoint, we want to calculate the width of the glyph, NOT
                // the x_advance (Which includes the spacing to the next codepoint)
                //
                const width_overshoot = blk: {
                    const last_codepoint = codepoints[codepoints.len - 1];
                    const glyph_width_pixels = @intToFloat(f32, self.textureExtentFromCodepoint(last_codepoint).width);
                    const advance_x = self.font.glyphMetricsFromCodepoint(last_codepoint).advance_x;
                    std.debug.assert(advance_x >= glyph_width_pixels);
                    break :blk advance_x - glyph_width_pixels;
                };
                total_width -= width_overshoot;

                const total_height = (descent_max + ascender_max) * screen_scale.vertical;
                if (total_height > placement_extent.height)
                    return error.InsufficientVerticalSpace;

                total_width *= screen_scale.horizontal;
                if (total_width > placement_extent.width)
                    return error.InsufficientHorizontalSpace;

                const vertical_margin: f64 = (placement_extent.height - total_height) / 2.0;
                const horizontal_margin = (placement_extent.width - total_width) / 2.0;
                var cursor = types.Coordinates2DNative{
                    .x = placement_extent.x + @floatCast(f32, horizontal_margin),
                    .y = @floatCast(f32, placement_extent.y - (vertical_margin + (descent_max * screen_scale.vertical))),
                };

                i = 0;
                while (i < codepoints.len) : (i += 1) {
                    const codepoint = codepoints[i];
                    if (codepoint == ' ') {
                        cursor.x += @floatCast(f32, impl.font.space_advance * impl.font_scale * screen_scale.horizontal);
                        continue;
                    }
                    const glyph_metrics = self.font.glyphMetricsFromCodepoint(codepoint);
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };

                    const screen_extent = types.Extent2DNative{
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

            pub fn writeCenteredFreetypeHarfbuzz(
                self: *@This(),
                codepoints: []const u8,
                placement_extent: types.Extent2DNative,
                screen_scale: types.Scale2D,
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

                var max_descent: f64 = 0;
                var max_height: f64 = 0;

                var rendered_text_width: f64 = 0;
                var i: usize = 0;
                while (i < buffer_length) : (i += 1) {
                    rendered_text_width += (@intToFloat(f64, position_list[i].x_advance) / 64.0) * screen_scale.horizontal;

                    const codepoint = codepoints[i];
                    const glyph_index: u32 = impl.getCharIndexFn(impl.face, codepoint);
                    std.debug.assert(glyph_index != 0);

                    if (impl.loadGlyphFn(impl.face, glyph_index, .{}) != 0) {
                        std.log.warn("Failed to load '{c}'", .{codepoint});
                        continue;
                    }

                    const glyph = impl.face.glyph;
                    const height_above_baseline = @intToFloat(f64, glyph.metrics.hori_bearing_y) / 64;
                    const total_height = @intToFloat(f64, glyph.metrics.height) / 64;
                    const descent = total_height - height_above_baseline;

                    max_descent = @max(max_descent, descent);
                    max_height = @max(max_height, height_above_baseline);
                }

                const line_height = (max_descent + max_height) * screen_scale.vertical;

                if (line_height > placement_extent.height)
                    return error.TextTooTall;

                const margin_vertical = -((placement_extent.height - line_height) / 2.0);

                if (rendered_text_width > placement_extent.width)
                    return error.TextTooWide;

                const margin_horizontal = (placement_extent.width - rendered_text_width) / 2.0;

                var cursor = types.Coordinates2DNative{
                    .x = placement_extent.x,
                    .y = placement_extent.y,
                };
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);

                i = 0;
                while (i < buffer_length) : (i += 1) {
                    const x_advance = @intToFloat(f64, position_list[i].x_advance) / 64.0;
                    const y_advance = @intToFloat(f64, position_list[i].y_advance) / 64.0;
                    const x_offset = @intToFloat(f32, position_list[i].x_offset) / 64.0;
                    const y_offset = @intToFloat(f32, position_list[i].y_offset) / 64.0;

                    const codepoint = codepoints[i];
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
                        const texture_extent = types.Extent2DNative{
                            .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                            .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                            .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                            .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                        };
                        const screen_extent = types.Extent2DNative{
                            .x = @floatCast(f32, margin_horizontal + cursor.x + (x_offset * screen_scale.horizontal)),
                            .y = @floatCast(f32, margin_vertical + cursor.y + ((y_offset + descent) * screen_scale.vertical)),
                            .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                            .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                        };
                        try writer_interface.write(screen_extent, texture_extent);
                    }
                    cursor.x += @floatCast(f32, x_advance * screen_scale.horizontal);
                    cursor.y += @floatCast(f32, y_advance * screen_scale.vertical);
                }
            }

            inline fn writeFreetypeHarfbuzz(
                self: *@This(),
                codepoints: []const u8,
                placement: types.Coordinates2DNative,
                screen_scale: types.Scale2D,
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
                        const texture_extent = types.Extent2DNative{
                            .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                            .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                            .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                            .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                        };
                        const screen_extent = types.Extent2DNative{
                            .x = @floatCast(f32, cursor.x + (x_offset * screen_scale.horizontal)),
                            .y = @floatCast(f32, cursor.y + ((y_offset + descent) * screen_scale.vertical)),
                            .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                            .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                        };
                        try writer_interface.write(screen_extent, texture_extent);
                    }
                    cursor.x += @floatCast(f32, x_advance * screen_scale.horizontal);
                    cursor.y += @floatCast(f32, y_advance * screen_scale.vertical);
                }
            }

            inline fn writeFreetype(
                self: *@This(),
                codepoints: []const u8,
                placement: types.Coordinates2DNative,
                screen_scale: types.Scale2D,
                writer_interface: anytype,
            ) !void {
                var impl = self.font;
                var cursor = placement;
                const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
                var face = impl.*.face;
                for (codepoints) |codepoint| {
                    const err_code = impl.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                    std.debug.assert(err_code == 0);
                    const glyph_height = @intToFloat(f32, face.glyph.metrics.height) / 64;
                    const glyph_width = @intToFloat(f32, face.glyph.metrics.width) / 64;
                    const advance = @intToFloat(f32, face.glyph.metrics.hori_advance) / 64;
                    const x_offset: f32 = (advance - glyph_width) / 2.0;
                    const y_offset: f32 = glyph_height - (@intToFloat(f32, face.glyph.metrics.hori_bearing_y) / 64);
                    if (codepoint != ' ') {
                        const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                        const texture_extent = types.Extent2DNative{
                            .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                            .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                            .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                            .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                        };
                        const screen_extent = types.Extent2DNative{
                            .x = @floatCast(f32, cursor.x + (x_offset * screen_scale.horizontal)),
                            .y = @floatCast(f32, cursor.y + (y_offset * screen_scale.vertical)),
                            .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                            .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                        };
                        try writer_interface.write(screen_extent, texture_extent);
                    }
                    cursor.x += @floatCast(f32, advance * screen_scale.horizontal);
                }
            }

            inline fn writeFontana(
                self: *@This(),
                codepoints: []const u8,
                placement: types.Coordinates2DNative,
                screen_scale: types.Scale2D,
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
                        cursor.x += @floatCast(f32, impl.font.space_advance * impl.font_scale * screen_scale.horizontal);
                        continue;
                    }
                    const glyph_metrics = self.font.glyphMetricsFromCodepoint(codepoint);
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };

                    const screen_extent = types.Extent2DNative{
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
            atlas_ref: *Atlas,
        ) !Pen {
            const font: *otf.FontInfo = &self.internal.font;
            self.internal.font_scale = otf.fUnitToPixelScale(size_point, points_per_pixel, font.units_per_em);
            var pen: Pen = undefined;
            pen.font = &self.internal;
            pen.atlas = atlas_ref;
            pen.atlas_entries = try allocator.alloc(types.Extent2DPixel, 64);
            pen.codepoints = codepoints;
            const funit_to_pixel = otf.fUnitToPixelScale(size_point, points_per_pixel, font.units_per_em);
            for (codepoints) |codepoint, codepoint_i| {
                const required_dimensions = try otf.getRequiredDimensions(font, codepoint, funit_to_pixel);
                // TODO: Implement spacing in Atlas
                pen.atlas_entries[codepoint_i] = try pen.atlas.reserve(
                    types.Extent2DPixel,
                    allocator,
                    required_dimensions.width + 2,
                    required_dimensions.height + 2,
                );
                pen.atlas_entries[codepoint_i].x += 1;
                pen.atlas_entries[codepoint_i].y += 1;
                pen.atlas_entries[codepoint_i].width -= 2;
                pen.atlas_entries[codepoint_i].height -= 2;
                var pixel_writer = rasterizer.SubTexturePixelWriter(PixelType, types.Extent2DPixel){
                    .texture_width = texture_size,
                    .pixels = texture_pixels,
                    .write_extent = pen.atlas_entries[codepoint_i],
                };
                try otf.rasterizeGlyph(allocator, pixel_writer, font, @floatCast(f32, funit_to_pixel), codepoint);
            }
            return pen;
        }

        inline fn createPenFreetype(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size_point: f64,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
            atlas_ref: *Atlas,
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
            pen.atlas = atlas_ref;
            pen.atlas_entries = try allocator.alloc(types.Extent2DPixel, 128);
            pen.codepoints = codepoints;
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.internal.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                std.debug.assert(err_code == 0);
                const bitmap = face.glyph.bitmap;
                const bitmap_height = bitmap.rows;
                const bitmap_width = bitmap.width;
                // TODO: Implement spacing in Atlas
                pen.atlas_entries[codepoint_i] = try pen.atlas.reserve(
                    types.Extent2DPixel,
                    allocator,
                    bitmap_width + 2,
                    bitmap_height + 2,
                );
                pen.atlas_entries[codepoint_i].x += 1;
                pen.atlas_entries[codepoint_i].y += 1;
                pen.atlas_entries[codepoint_i].width -= 2;
                pen.atlas_entries[codepoint_i].height -= 2;
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

        inline fn createPenFreetypeHarfbuzz(
            self: *@This(),
            comptime PixelType: type,
            allocator: std.mem.Allocator,
            size_point: f64,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelType,
            atlas_ref: *Atlas,
        ) !Pen {
            const face = self.internal.face;
            _ = self.internal.setCharSizeFn(
                self.internal.face,
                0,
                @floatToInt(i32, size_point * 64),
                @floatToInt(u32, points_per_pixel),
                @floatToInt(u32, points_per_pixel),
            );
            self.internal.hbFontChanged(self.internal.harfbuzz_font);
            var pen: Pen = undefined;
            pen.font = &self.internal;
            pen.atlas = atlas_ref;
            pen.atlas_entries = try allocator.alloc(types.Extent2DPixel, 128);
            pen.codepoints = codepoints;
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.internal.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                std.debug.assert(err_code == 0);
                const bitmap = face.glyph.bitmap;
                const bitmap_height = bitmap.rows;
                const bitmap_width = bitmap.width;
                // TODO: Implement spacing in Atlas
                pen.atlas_entries[codepoint_i] = try pen.atlas.reserve(
                    types.Extent2DPixel,
                    allocator,
                    bitmap_width + 2,
                    bitmap_height + 2,
                );
                pen.atlas_entries[codepoint_i].x += 1;
                pen.atlas_entries[codepoint_i].y += 1;
                pen.atlas_entries[codepoint_i].width -= 2;
                pen.atlas_entries[codepoint_i].height -= 2;
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
            atlas_ref: *Atlas,
        ) !Pen {
            // TODO: Convert point to pixel, etc
            return switch (comptime backend) {
                .fontana => self.createPenFontana(
                    PixelType,
                    allocator,
                    size.point,
                    points_per_pixel,
                    codepoints,
                    texture_size,
                    texture_pixels,
                    atlas_ref,
                ),
                .freetype_harfbuzz => self.createPenFreetypeHarfbuzz(
                    PixelType,
                    allocator,
                    size.point,
                    points_per_pixel,
                    codepoints,
                    texture_size,
                    texture_pixels,
                    atlas_ref,
                ),
                .freetype => self.createPenFreetype(
                    PixelType,
                    allocator,
                    size.point,
                    points_per_pixel,
                    codepoints,
                    texture_size,
                    texture_pixels,
                    atlas_ref,
                ),
            };
        }
    };
}
