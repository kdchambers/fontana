// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const freetype = @import("../freetype.zig");
const graphics = @import("../graphics.zig");
const geometry = @import("../geometry.zig");
const Atlas = @import("../Atlas.zig");

const api = @import("api.zig");

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
            self.points_per_pixel = @floatToInt(u32, points_per_pixel);
            self.size_point = @floatToInt(i32, size_point * 64);
            const face = self.backend_ref.face;
            _ = self.backend_ref.setCharSizeFn(
                self.backend_ref.face,
                0,
                self.size_point,
                self.points_per_pixel,
                self.points_per_pixel,
            );
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
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
                        const value = @intToFloat(f32, bitmap_pixels[x + (y * bitmap_width)]) / 255;
                        const index: usize = (placement.x + x) + ((y + placement.y) * texture_size);
                        // TODO: Detect type using comptime
                        const use_transparency: bool = @hasField(types.Pixel, "a");
                        if (@hasField(types.Pixel, "r"))
                            texture_pixels[index].r = if (use_transparency) 0.8 else value;

                        if (@hasField(types.Pixel, "g"))
                            texture_pixels[index].g = if (use_transparency) 0.8 else value;

                        if (@hasField(types.Pixel, "b"))
                            texture_pixels[index].b = if (use_transparency) 0.8 else value;

                        if (use_transparency) {
                            texture_pixels[index].a = value;
                        }
                    }
                }
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.atlas_entries);
            self.atlas_entries_count = 0;
        }

        pub inline fn write(
            self: *@This(),
            codepoints: []const u8,
            placement: types.Coordinates2DNative,
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
            var cursor = placement;
            const texture_width_height: f32 = @intToFloat(f32, self.atlas_ref.size);
            var face = self.backend_ref.face;

            const has_kerning = face.face_flags.kerning;

            var previous_codepoint: u8 = 0;
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                std.debug.assert(err_code == 0);
                const glyph_height = @intToFloat(f32, face.glyph.metrics.height) / 64;
                const glyph_width = @intToFloat(f32, face.glyph.metrics.width) / 64;
                const advance = @intToFloat(f32, face.glyph.metrics.hori_advance) / 64;
                const x_offset: f32 = blk: {
                    if (codepoint_i == 0 or !has_kerning) {
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    var kerning: freetype.Vector = undefined;
                    const ret = self.backend_ref.getKerningFn(
                        face,
                        @intCast(u32, previous_codepoint),
                        @intCast(u32, codepoint),
                        0, // Default kerning
                        &kerning,
                    );
                    if (ret != 0) {
                        std.log.warn("FT_Get_Kerning failed for {c} and {c}", .{
                            previous_codepoint,
                            codepoint,
                        });
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    // std.log.info("Kern {c} -> {c}: {d}", .{
                    //     previous_codepoint,
                    //     codepoint,
                    //     kerning.x,
                    // });
                    break :blk (@intToFloat(f32, kerning.x) / 64) + (advance - glyph_width) / 2.0;
                };

                const y_offset: f32 = glyph_height - (@intToFloat(f32, face.glyph.metrics.hori_bearing_y) / 64);
                const leftside_bearing = @floatCast(f32, (@intToFloat(f32, face.glyph.metrics.hori_bearing_x) / 64) * screen_scale.horizontal);

                if (codepoint != ' ') {
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };
                    const screen_extent = types.Extent2DNative{
                        .x = @floatCast(f32, cursor.x + (x_offset * screen_scale.horizontal)) + leftside_bearing,
                        .y = @floatCast(f32, cursor.y + (y_offset * screen_scale.vertical)),
                        .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                        .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                }
                cursor.x += @floatCast(f32, advance * screen_scale.horizontal);
                previous_codepoint = codepoint;
            }
        }

        pub inline fn writeCentered(
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
            const texture_width_height: f32 = @intToFloat(f32, self.atlas_ref.size);
            var face = self.backend_ref.face;

            const RenderedTextMetrics = struct {
                max_ascender: f64,
                max_descender: f64,
                width: f64,
            };
            const rendered_text_metrics: RenderedTextMetrics = blk: {
                var max_descender: f64 = 0;
                var max_height: f64 = 0;
                var rendered_text_width: f64 = 0;
                for (codepoints) |codepoint| {
                    const err_code = self.backend_ref.loadCharFn(face, @intCast(u32, codepoint), .{});
                    std.debug.assert(err_code == 0);
                    const glyph_height = @intToFloat(f32, face.glyph.metrics.height) / 64;
                    const glyph_width = @intToFloat(f32, face.glyph.metrics.width) / 64;
                    const descender: f32 = glyph_height - (@intToFloat(f32, face.glyph.metrics.hori_bearing_y) / 64);
                    rendered_text_width += glyph_width;
                    max_height = @max(max_height, glyph_height - descender);
                    max_descender = @max(max_descender, descender);
                }
                break :blk .{
                    .max_ascender = max_height * screen_scale.vertical,
                    .max_descender = max_descender * screen_scale.vertical,
                    .width = rendered_text_width * screen_scale.horizontal,
                };
            };

            if (rendered_text_metrics.width > placement_extent.width)
                return error.InsufficientHorizontalSpace;

            const total_height = rendered_text_metrics.max_ascender + rendered_text_metrics.max_descender;

            if (total_height > placement_extent.height)
                return error.InsufficientVerticalSpace;

            const margin_horizontal: f64 = ((placement_extent.width - rendered_text_metrics.width) / 2.0);
            const margin_vertical: f64 = ((placement_extent.height - total_height) / 2.0);

            var cursor = types.Coordinates2DNative{
                .x = @floatCast(f32, placement_extent.x + margin_horizontal),
                .y = @floatCast(f32, placement_extent.y - margin_vertical),
            };

            const has_kerning = face.face_flags.kerning;
            var previous_codepoint: u8 = 0;
            for (codepoints) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @intCast(u32, codepoint), .{ .render = true });
                std.debug.assert(err_code == 0);
                const glyph_height = @intToFloat(f32, face.glyph.metrics.height) / 64;
                const glyph_width = @intToFloat(f32, face.glyph.metrics.width) / 64;
                const advance = @intToFloat(f32, face.glyph.metrics.hori_advance) / 64;
                const x_offset: f32 = blk: {
                    if (codepoint_i == 0 or !has_kerning) {
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    var kerning: freetype.Vector = undefined;
                    const ret = self.backend_ref.getKerningFn(
                        face,
                        @intCast(u32, previous_codepoint),
                        @intCast(u32, codepoint),
                        0, // Default kerning
                        &kerning,
                    );
                    if (ret != 0) {
                        std.log.warn("FT_Get_Kerning failed for {c} and {c}", .{
                            previous_codepoint,
                            codepoint,
                        });
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    // std.log.info("Kern {c} -> {c}: {d}", .{
                    //     previous_codepoint,
                    //     codepoint,
                    //     kerning.x,
                    // });
                    break :blk (@intToFloat(f32, kerning.x) / 64) + (advance - glyph_width) / 2.0;
                };

                const y_offset: f32 = glyph_height - (@intToFloat(f32, face.glyph.metrics.hori_bearing_y) / 64);
                const leftside_bearing = @floatCast(f32, (@intToFloat(f32, face.glyph.metrics.hori_bearing_x) / 64) * screen_scale.horizontal);

                if (codepoint != ' ') {
                    const glyph_texture_extent = self.textureExtentFromCodepoint(codepoint);
                    const texture_extent = types.Extent2DNative{
                        .x = @intToFloat(f32, glyph_texture_extent.x) / texture_width_height,
                        .y = @intToFloat(f32, glyph_texture_extent.y) / texture_width_height,
                        .width = @intToFloat(f32, glyph_texture_extent.width) / texture_width_height,
                        .height = @intToFloat(f32, glyph_texture_extent.height) / texture_width_height,
                    };
                    const screen_extent = types.Extent2DNative{
                        .x = @floatCast(f32, cursor.x + (x_offset * screen_scale.horizontal)) + leftside_bearing,
                        .y = @floatCast(f32, cursor.y + (y_offset * screen_scale.vertical)),
                        .width = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.width) * screen_scale.horizontal),
                        .height = @floatCast(f32, @intToFloat(f64, glyph_texture_extent.height) * screen_scale.vertical),
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                }
                cursor.x += @floatCast(f32, advance * screen_scale.horizontal);
                previous_codepoint = codepoint;
            }
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

        library: freetype.Library,
        face: freetype.Face,

        font_bytes: []const u8,

        pub inline fn construct(bytes: []const u8) !@This() {
            var self: @This() = undefined;
            try self.init(bytes);
            return self;
        }

        pub inline fn init(self: *@This(), bytes: []const u8) !void {
            var freetype_handle = DynLib.open("libfreetype.so") catch return error.LinkFreetypeFailed;
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
