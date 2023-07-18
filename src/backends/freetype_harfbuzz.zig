// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const freetype = @import("../freetype.zig");
const harfbuzz = @import("../harfbuzz.zig");
const graphics = @import("../graphics.zig");
const geometry = @import("../geometry.zig");
const Atlas = @import("../Atlas.zig");

const api = @import("api.zig");

//
// Freetype Functions
//
const InitFn = *const fn (*freetype.Library) callconv(.C) void;
const DoneFn = *const fn (freetype.Library) callconv(.C) i32;
const NewMemoryFaceFn = *const fn (
    freetype.Library,
    file_base: [*]const u8,
    file_size: u64,
    face_index: u64,
    out_face: *freetype.Face,
) callconv(.C) i32;

const GetCharIndexFn = *const fn (freetype.Face, u64) callconv(.C) u32;
const LoadCharFn = *const fn (freetype.Face, u64, freetype.LoadFlags) callconv(.C) i32;
const LoadGlyphFn = *const fn (freetype.Face, u32, freetype.LoadFlags) callconv(.C) i32;
const SetCharSizeFn = *const fn (freetype.Face, freetype.F26Dot6, freetype.F26Dot6, u32, u32) callconv(.C) i32;
const GetKerningFn = *const fn (
    freetype.Face,
    left_glyph: u32,
    right_glyph: u32,
    kern_mode: u32,
    kern_value: *freetype.Vector,
) callconv(.C) i32;

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

pub fn PenConfigInternal(comptime options: api.PenConfigOptionsInternal) type {
    const types = options.type_overrides;

    return struct {
        backend_ref: *const options.BackendType,
        atlas_ref: *Atlas,
        codepoints: []const u8,
        atlas_entries: []types.Extent2DPixel,
        atlas_entries_count: u32,
        points_per_pixel: u32,
        size_point: i32,

        inline fn init(
            self: *@This(),
            allocator: std.mem.Allocator,
            backend_ref: *const options.BackendType,
            codepoints: []const u8,
            size_point: f64,
            points_per_pixel: f64,
            texture_size: u32,
            texture_pixels: [*]types.Pixel,
            atlas_ref: *Atlas,
        ) !void {
            self.backend_ref = backend_ref;
            self.atlas_ref = atlas_ref;
            self.atlas_entries = try allocator.alloc(types.Extent2DPixel, 128);
            self.codepoints = codepoints;
            self.points_per_pixel = @as(u32, @intFromFloat(points_per_pixel));
            self.size_point = @as(i32, @intFromFloat(size_point * 64));
            const face = self.backend_ref.face;
            _ = self.backend_ref.setCharSizeFn(
                self.backend_ref.face,
                0,
                self.size_point,
                self.points_per_pixel,
                self.points_per_pixel,
            );
            self.backend_ref.hbFontChanged(self.backend_ref.harfbuzz_font);

            for (codepoints, 0..) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @as(u32, @intCast(codepoint)), .{ .render = true });
                std.debug.assert(err_code == 0);
                const bitmap = face.glyph.bitmap;
                const bitmap_height = bitmap.rows;
                const bitmap_width = bitmap.width;
                // TODO: Implement spacing in Atlas
                self.atlas_entries[codepoint_i] = try self.atlas_ref.reserve(
                    types.Extent2DPixel,
                    allocator,
                    bitmap_width + 2,
                    bitmap_height + 2,
                );
                self.atlas_entries[codepoint_i].x += 1;
                self.atlas_entries[codepoint_i].y += 1;
                self.atlas_entries[codepoint_i].width -= 2;
                self.atlas_entries[codepoint_i].height -= 2;
                const placement = self.atlas_entries[codepoint_i];
                const bitmap_pixels: [*]const u8 = bitmap.buffer;
                var y: usize = 0;
                while (y < bitmap_height) : (y += 1) {
                    var x: usize = 0;
                    while (x < bitmap_width) : (x += 1) {
                        const value: u8 = bitmap_pixels[x + (y * bitmap_width)];
                        const index: usize = (placement.x + x) + ((y + placement.y) * texture_size);
                        switch (comptime options.pixel_format) {
                            .r8 => texture_pixels[index] = value,
                            .r32g32b32a32 => {
                                texture_pixels[index].r = 0.8;
                                texture_pixels[index].g = 0.8;
                                texture_pixels[index].b = 0.8;
                                texture_pixels[index].a = @as(f32, @floatFromInt(value)) / 255.0;
                            },
                            else => unreachable,
                        }
                    }
                }
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.atlas_entries);
            self.atlas_entries_count = 0;
        }

        pub fn writeCentered(
            self: *@This(),
            codepoints: []const u8,
            placement_extent: types.Extent2DNative,
            screen_scale: types.Scale2D,
            writer_interface: anytype,
        ) !void {
            _ = self.backend_ref.setCharSizeFn(
                self.backend_ref.face,
                0,
                self.size_point,
                self.points_per_pixel,
                self.points_per_pixel,
            );
            self.backend_ref.hbFontChanged(self.backend_ref.harfbuzz_font);

            var buffer = self.backend_ref.hbBufferCreateFn();
            defer self.backend_ref.hbBufferDestroyFn(buffer);

            self.backend_ref.hbBufferAddUTF8Fn(buffer, codepoints.ptr, @as(i32, @intCast(codepoints.len)), 0, -1);
            self.backend_ref.hbBufferSetDirectionFn(buffer, .left_to_right);
            self.backend_ref.hbBufferSetScriptFn(buffer, .latin);
            const language = self.backend_ref.hbLanguageFromStringFn("en", 2);
            self.backend_ref.hbBufferSetLanguageFn(buffer, language);
            self.backend_ref.hbBufferGuessSegmentPropertiesFn(buffer);

            self.backend_ref.hbShapeFn(self.backend_ref.harfbuzz_font, buffer, null, 0);
            const buffer_length = self.backend_ref.hbBufferGetLengthFn(buffer);

            var position_count: u32 = 0;
            const position_list: [*]harfbuzz.GlyphPosition = self.backend_ref.hbBufferGetGlyphPositionsFn(buffer, &position_count);
            std.debug.assert(position_count > 0);

            var max_descent: f64 = 0;
            var max_height: f64 = 0;

            var rendered_text_width: f64 = 0;
            var i: usize = 0;
            while (i < buffer_length) : (i += 1) {
                rendered_text_width += (@as(f64, @floatFromInt(position_list[i].x_advance)) / 64.0) * screen_scale.horizontal;

                const codepoint = codepoints[i];
                const glyph_index: u32 = self.backend_ref.getCharIndexFn(self.backend_ref.face, codepoint);
                std.debug.assert(glyph_index != 0);

                if (self.backend_ref.loadGlyphFn(self.backend_ref.face, glyph_index, .{}) != 0) {
                    std.log.warn("Failed to load '{c}'", .{codepoint});
                    continue;
                }

                const glyph = self.backend_ref.face.glyph;
                const height_above_baseline = @as(f64, @floatFromInt(glyph.metrics.hori_bearing_y)) / 64;
                const total_height = @as(f64, @floatFromInt(glyph.metrics.height)) / 64;
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
            // const texture_width_height: f32 = @intToFloat(f32, self.atlas_ref.size);

            i = 0;
            while (i < buffer_length) : (i += 1) {
                const x_advance = @as(f64, @floatFromInt(position_list[i].x_advance)) / 64.0;
                const y_advance = @as(f64, @floatFromInt(position_list[i].y_advance)) / 64.0;
                const x_offset = @as(f32, @floatFromInt(position_list[i].x_offset)) / 64.0;
                const y_offset = @as(f32, @floatFromInt(position_list[i].y_offset)) / 64.0;

                const codepoint = codepoints[i];
                const glyph_index: u32 = self.backend_ref.getCharIndexFn(self.backend_ref.face, codepoint);
                std.debug.assert(glyph_index != 0);

                if (self.backend_ref.loadGlyphFn(self.backend_ref.face, glyph_index, .{}) != 0) {
                    std.log.warn("Failed to write '{c}'", .{codepoint});
                    continue;
                }

                const glyph = self.backend_ref.face.glyph;
                const descent = (@as(f64, @floatFromInt(glyph.metrics.height - glyph.metrics.hori_bearing_y)) / 64);
                const leftside_bearing = @as(f32, @floatCast((@as(f32, @floatFromInt(glyph.metrics.hori_bearing_x)) / 64) * screen_scale.horizontal));
                if (codepoint != ' ') {
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @as(f32, @floatFromInt(glyph_texture_extent.x)),
                        .y = @as(f32, @floatFromInt(glyph_texture_extent.y)),
                        .width = @as(f32, @floatFromInt(glyph_texture_extent.width)),
                        .height = @as(f32, @floatFromInt(glyph_texture_extent.height)),
                    };
                    const screen_extent = types.Extent2DNative{
                        .x = @as(f32, @floatCast(margin_horizontal + cursor.x + (x_offset * screen_scale.horizontal))) + leftside_bearing,
                        .y = @as(f32, @floatCast(margin_vertical + cursor.y + ((y_offset + descent) * screen_scale.vertical))),
                        .width = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.width)) * screen_scale.horizontal)),
                        .height = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.height)) * screen_scale.vertical)),
                    };
                    const x_correction = writer_interface.write(screen_extent, texture_extent);
                    cursor.x += x_correction;
                }
                cursor.x += @as(f32, @floatCast(x_advance * screen_scale.horizontal));
                cursor.y += @as(f32, @floatCast(y_advance * screen_scale.vertical));
            }
        }

        pub inline fn write(
            self: *@This(),
            codepoints: []const u8,
            placement: types.Coordinates2DNative,
            screen_scale: types.Scale2D,
            writer_interface: anytype,
        ) !types.Extent2DNative {
            _ = self.backend_ref.setCharSizeFn(
                self.backend_ref.face,
                0,
                self.size_point,
                self.points_per_pixel,
                self.points_per_pixel,
            );
            self.backend_ref.hbFontChanged(self.backend_ref.harfbuzz_font);

            var buffer = self.backend_ref.hbBufferCreateFn();
            defer self.backend_ref.hbBufferDestroyFn(buffer);
            self.backend_ref.hbBufferAddUTF8Fn(buffer, codepoints.ptr, @as(i32, @intCast(codepoints.len)), 0, -1);
            self.backend_ref.hbBufferSetDirectionFn(buffer, .left_to_right);
            self.backend_ref.hbBufferSetScriptFn(buffer, .latin);
            const language = self.backend_ref.hbLanguageFromStringFn("en", 2);
            self.backend_ref.hbBufferSetLanguageFn(buffer, language);
            self.backend_ref.hbBufferGuessSegmentPropertiesFn(buffer);
            self.backend_ref.hbShapeFn(self.backend_ref.harfbuzz_font, buffer, null, 0);
            const buffer_length = self.backend_ref.hbBufferGetLengthFn(buffer);
            var position_count: u32 = 0;
            const position_list: [*]harfbuzz.GlyphPosition = self.backend_ref.hbBufferGetGlyphPositionsFn(buffer, &position_count);
            std.debug.assert(position_count > 0);

            var max_descent: f64 = 0;
            var max_height: f64 = 0;
            var cursor = placement;
            var i: usize = 0;
            while (i < buffer_length) : (i += 1) {
                const codepoint = codepoints[i];
                const x_advance = @as(f64, @floatFromInt(position_list[i].x_advance)) / 64.0;
                const y_advance = @as(f64, @floatFromInt(position_list[i].y_advance)) / 64.0;
                const x_offset = @as(f32, @floatFromInt(position_list[i].x_offset)) / 64.0;
                const y_offset = @as(f32, @floatFromInt(position_list[i].y_offset)) / 64.0;
                const glyph_index: u32 = self.backend_ref.getCharIndexFn(self.backend_ref.face, codepoint);
                std.debug.assert(glyph_index != 0);

                if (self.backend_ref.loadGlyphFn(self.backend_ref.face, glyph_index, .{}) != 0) {
                    std.log.warn("Failed to write '{c}'", .{codepoint});
                    continue;
                }

                const glyph = self.backend_ref.face.glyph;
                const leftside_bearing = @as(f32, @floatCast((@as(f32, @floatFromInt(glyph.metrics.hori_bearing_x)) / 64) * screen_scale.horizontal));

                const height_above_baseline = @as(f64, @floatFromInt(glyph.metrics.hori_bearing_y)) / 64;
                const total_height = @as(f64, @floatFromInt(glyph.metrics.height)) / 64;

                max_descent = @max(max_descent, total_height - height_above_baseline);
                max_height = @max(max_height, height_above_baseline);

                // std.log.info("cp {c} x_advance: {d}, x_offset: {d} lsb: {d}", .{
                //     codepoint,
                //     x_advance,
                //     x_offset,
                //     leftside_bearing,
                // });
                const descent = (@as(f64, @floatFromInt(glyph.metrics.height - glyph.metrics.hori_bearing_y)) / 64);
                if (codepoint != ' ') {
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @as(f32, @floatFromInt(glyph_texture_extent.x)),
                        .y = @as(f32, @floatFromInt(glyph_texture_extent.y)),
                        .width = @as(f32, @floatFromInt(glyph_texture_extent.width)),
                        .height = @as(f32, @floatFromInt(glyph_texture_extent.height)),
                    };
                    const screen_extent = types.Extent2DNative{
                        .x = @as(f32, @floatCast(cursor.x + (x_offset * screen_scale.horizontal))) + leftside_bearing,
                        .y = @as(f32, @floatCast(cursor.y + ((y_offset + descent) * screen_scale.vertical))),
                        .width = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.width)) * screen_scale.horizontal)),
                        .height = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.height)) * screen_scale.vertical)),
                    };
                    const x_correction = writer_interface.write(screen_extent, texture_extent);
                    cursor.x += x_correction;
                }
                cursor.x += @as(f32, @floatCast(x_advance * screen_scale.horizontal));
                cursor.y += @as(f32, @floatCast(y_advance * screen_scale.vertical));
            }
            return .{
                .x = placement.x,
                .y = placement.y,
                .width = cursor.x - placement.x,
                .height = @as(f32, @floatCast(max_descent + max_height)) * screen_scale.vertical,
            };
        }

        pub fn calculateRenderDimensions(self: *@This(), codepoints: []const u8) types.Dimensions2DNative {
            _ = self.backend_ref.setCharSizeFn(
                self.backend_ref.face,
                0,
                self.size_point,
                self.points_per_pixel,
                self.points_per_pixel,
            );
            self.backend_ref.hbFontChanged(self.backend_ref.harfbuzz_font);

            var buffer = self.backend_ref.hbBufferCreateFn();
            defer self.backend_ref.hbBufferDestroyFn(buffer);

            self.backend_ref.hbBufferAddUTF8Fn(buffer, codepoints.ptr, @as(i32, @intCast(codepoints.len)), 0, -1);
            self.backend_ref.hbBufferSetDirectionFn(buffer, .left_to_right);
            self.backend_ref.hbBufferSetScriptFn(buffer, .latin);
            const language = self.backend_ref.hbLanguageFromStringFn("en", 2);
            self.backend_ref.hbBufferSetLanguageFn(buffer, language);
            self.backend_ref.hbBufferGuessSegmentPropertiesFn(buffer);

            self.backend_ref.hbShapeFn(self.backend_ref.harfbuzz_font, buffer, null, 0);
            const buffer_length = self.backend_ref.hbBufferGetLengthFn(buffer);

            var position_count: u32 = 0;
            const position_list: [*]harfbuzz.GlyphPosition = self.backend_ref.hbBufferGetGlyphPositionsFn(buffer, &position_count);
            std.debug.assert(position_count > 0);

            var max_descent: f64 = 0;
            var max_height: f64 = 0;

            var rendered_text_width: f64 = 0;
            var i: usize = 0;
            while (i < buffer_length) : (i += 1) {
                rendered_text_width += (@as(f64, @floatFromInt(position_list[i].x_advance)) / 64.0);

                const codepoint = codepoints[i];
                const glyph_index: u32 = self.backend_ref.getCharIndexFn(self.backend_ref.face, codepoint);
                std.debug.assert(glyph_index != 0);

                if (self.backend_ref.loadGlyphFn(self.backend_ref.face, glyph_index, .{}) != 0) {
                    std.log.warn("Failed to load '{c}'", .{codepoint});
                    continue;
                }

                const glyph = self.backend_ref.face.glyph;
                const height_above_baseline = @as(f64, @floatFromInt(glyph.metrics.hori_bearing_y)) / 64;
                const total_height = @as(f64, @floatFromInt(glyph.metrics.height)) / 64;
                const descent = total_height - height_above_baseline;

                max_descent = @max(max_descent, descent);
                max_height = @max(max_height, height_above_baseline);
            }

            return .{
                .width = @as(f32, @floatCast(rendered_text_width)),
                .height = @as(f32, @floatCast(max_descent + max_height)),
            };
        }

        //
        // Private Interface
        //

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
    };
}

pub fn FontConfig(comptime options: api.FontOptions) type {
    return struct {
        const FontType = @This();

        pub fn PenConfig(comptime pen_options: api.PenOptions) type {
            const PixelType = pen_options.PixelType orelse switch (pen_options.pixel_format) {
                .r8g8b8a8 => graphics.RGBA(u8),
                .r32g32b32a32 => graphics.RGBA(f32),
                else => @compileError("Pixel format not yet implemented"),
            };

            if (comptime !api.validatePixelFormat(PixelType, pen_options.pixel_format))
                @compileError("Unable to validate pixel_format and PixelType pair ");

            return PenConfigInternal(.{
                .type_overrides = .{
                    .Extent2DPixel = options.type_overrides.Extent2DPixel,
                    .Extent2DNative = options.type_overrides.Extent2DNative,
                    .Coordinates2DNative = options.type_overrides.Coordinates2DNative,
                    .Dimensions2DNative = options.type_overrides.Dimensions2DNative,
                    .Scale2D = options.type_overrides.Scale2D,
                    .Pixel = PixelType,
                },
                .BackendType = FontType,
                .pixel_format = pen_options.pixel_format,
            });
        }

        initFn: InitFn,
        doneFn: DoneFn,
        newMemoryFaceFn: NewMemoryFaceFn,
        getCharIndexFn: GetCharIndexFn,
        loadCharFn: LoadCharFn,
        loadGlyphFn: LoadGlyphFn,
        setCharSizeFn: SetCharSizeFn,
        getKerningFn: GetKerningFn,

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

        font_bytes: []const u8,

        pub inline fn construct(bytes: []const u8) !@This() {
            var self: @This() = undefined;
            try self.init(bytes);
            return self;
        }

        pub inline fn init(self: *@This(), bytes: []const u8) !void {
            var freetype_handle = DynLib.open("libfreetype.so.6") catch return error.LinkFreetypeFailed;
            var harfbuzz_handle = DynLib.open("libharfbuzz.so.0") catch return error.LinkHarfbuzzFailed;

            self.initFn = freetype_handle.lookup(InitFn, "FT_Init_FreeType") orelse return error.LookupFailed;
            self.doneFn = freetype_handle.lookup(DoneFn, "FT_Done_FreeType") orelse return error.LookupFailed;
            self.newMemoryFaceFn = freetype_handle.lookup(NewMemoryFaceFn, "FT_New_Memory_Face") orelse return error.LookupFailed;

            _ = self.initFn(&self.library);
            _ = self.newMemoryFaceFn(self.library, bytes.ptr, bytes.len, 0, &self.face);

            self.loadCharFn = freetype_handle.lookup(LoadCharFn, "FT_Load_Char") orelse
                return error.LookupFailed;
            self.loadGlyphFn = freetype_handle.lookup(LoadGlyphFn, "FT_Load_Glyph") orelse
                return error.LookupFailed;
            self.getCharIndexFn = freetype_handle.lookup(GetCharIndexFn, "FT_Get_Char_Index") orelse
                return error.LookupFailed;
            self.setCharSizeFn = freetype_handle.lookup(SetCharSizeFn, "FT_Set_Char_Size") orelse
                return error.LookupFailed;
            self.getKerningFn = freetype_handle.lookup(GetKerningFn, "FT_Get_Kerning") orelse
                return error.LookupFailed;

            self.hbFontCreateFn = harfbuzz_handle.lookup(HbFontCreateFn, "hb_ft_font_create_referenced") orelse
                return error.LookupFailed;
            self.hbFontSetFuncs = harfbuzz_handle.lookup(HbFontSetFuncsFn, "hb_ft_font_set_funcs") orelse
                return error.LookupFailed;
            self.hbFontChanged = harfbuzz_handle.lookup(HbFontChangedFn, "hb_ft_font_changed") orelse
                return error.LookupFailed;

            self.harfbuzz_font = self.hbFontCreateFn(self.face, null);

            self.hbBufferCreateFn = harfbuzz_handle.lookup(HbBufferCreateFn, "hb_buffer_create") orelse
                return error.LookupFailed;
            self.hbBufferDestroyFn = harfbuzz_handle.lookup(HbBufferDestroyFn, "hb_buffer_destroy") orelse
                return error.LookupFailed;
            self.hbBufferAddUTF8Fn = harfbuzz_handle.lookup(HbBufferAddUTF8Fn, "hb_buffer_add_utf8") orelse
                return error.LookupFailed;
            self.hbShapeFn = harfbuzz_handle.lookup(HbShapeFn, "hb_shape") orelse
                return error.LookupFailed;
            self.hbBufferGetLengthFn = harfbuzz_handle.lookup(HbBufferGetLengthFn, "hb_buffer_get_length") orelse
                return error.LookupFailed;
            self.hbBufferSetDirectionFn = harfbuzz_handle.lookup(HbBufferSetDirectionFn, "hb_buffer_set_direction") orelse
                return error.LookupFailed;
            self.hbBufferSetScriptFn = harfbuzz_handle.lookup(HbBufferSetScriptFn, "hb_buffer_set_script") orelse
                return error.LookupFailed;
            self.hbBufferSetLanguageFn = harfbuzz_handle.lookup(HbBufferSetLanguageFn, "hb_buffer_set_language") orelse
                return error.LookupFailed;
            self.hbLanguageFromStringFn = harfbuzz_handle.lookup(HbLanguageFromStringFn, "hb_language_from_string") orelse
                return error.LookupFailed;

            self.hbBufferGetGlyphInfosFn = harfbuzz_handle.lookup(
                HbBufferGetGlyphInfosFn,
                "hb_buffer_get_glyph_infos",
            ) orelse
                return error.LookupFailed;

            self.hbBufferGetGlyphPositionsFn = harfbuzz_handle.lookup(
                HbBufferGetGlyphPositionsFn,
                "hb_buffer_get_glyph_positions",
            ) orelse
                return error.LookupFailed;

            self.hbBufferGuessSegmentPropertiesFn = harfbuzz_handle.lookup(
                HbBufferGuessSegmentPropertiesFn,
                "hb_buffer_guess_segment_properties",
            ) orelse
                return error.LookupFailed;

            self.font_bytes = bytes;
        }

        pub inline fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self.doneFn(self.library);
            allocator.free(self.font_bytes);
        }

        pub fn PixelTypeInferred(comptime pen_options: api.PenOptions) type {
            return pen_options.PixelType orelse switch (pen_options.pixel_format) {
                .r8g8b8a8 => graphics.RGBA(u8),
                .r32g32b32a32 => graphics.RGBA(f32),
                else => @compileError("Pixel format not yet implemented"),
            };
        }

        pub inline fn createPen(
            self: *@This(),
            comptime pen_options: api.PenOptions,
            allocator: std.mem.Allocator,
            size_point: f64,
            points_per_pixel: f64,
            codepoints: []const u8,
            texture_size: u32,
            texture_pixels: [*]PixelTypeInferred(pen_options),
            atlas_ref: *Atlas,
        ) !PenConfig(pen_options) {
            var pen: PenConfig(pen_options) = undefined;
            try pen.init(
                allocator,
                self,
                codepoints,
                size_point,
                points_per_pixel,
                texture_size,
                texture_pixels,
                atlas_ref,
            );
            return pen;
        }
    };
}
