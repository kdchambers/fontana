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
                            .r8g8b8a8 => {
                                texture_pixels[index].r = 200;
                                texture_pixels[index].g = 200;
                                texture_pixels[index].b = 200;
                                texture_pixels[index].a = value;
                            },
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
            const face = self.backend_ref.face;

            const has_kerning = face.face_flags.kerning;

            var previous_codepoint: u8 = 0;
            for (codepoints, 0..) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @as(u32, @intCast(codepoint)), .{ .render = true });
                std.debug.assert(err_code == 0);
                const glyph_height = @as(f32, @floatFromInt(face.glyph.metrics.height)) / 64;
                const glyph_width = @as(f32, @floatFromInt(face.glyph.metrics.width)) / 64;
                const advance = @as(f32, @floatFromInt(face.glyph.metrics.hori_advance)) / 64;
                const x_offset: f32 = blk: {
                    if (codepoint_i == 0 or !has_kerning) {
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    var kerning: freetype.Vector = undefined;
                    const ret = self.backend_ref.getKerningFn(
                        face,
                        @as(u32, @intCast(previous_codepoint)),
                        @as(u32, @intCast(codepoint)),
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
                    break :blk (@as(f32, @floatFromInt(kerning.x)) / 64) + (advance - glyph_width) / 2.0;
                };

                const y_offset: f32 = glyph_height - (@as(f32, @floatFromInt(face.glyph.metrics.hori_bearing_y)) / 64);
                const leftside_bearing = @as(f32, @floatCast((@as(f32, @floatFromInt(face.glyph.metrics.hori_bearing_x)) / 64) * screen_scale.horizontal));

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
                        .y = @as(f32, @floatCast(cursor.y + (y_offset * screen_scale.vertical))),
                        .width = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.width)) * screen_scale.horizontal)),
                        .height = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.height)) * screen_scale.vertical)),
                    };
                    cursor.x += writer_interface.write(screen_extent, texture_extent);
                }
                cursor.x += @as(f32, @floatCast(advance * screen_scale.horizontal));
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
            const face = self.backend_ref.face;

            const RenderedTextMetrics = struct {
                max_ascender: f64,
                max_descender: f64,
                width: f64,
            };
            const rendered_text_metrics: RenderedTextMetrics = blk: {
                var max_descender: f64 = 0;
                var max_height: f64 = 0;
                var rendered_text_width: f64 = 0;
                var glyph_width: f32 = 0;
                var advance: f32 = 0;
                for (codepoints) |codepoint| {
                    const err_code = self.backend_ref.loadCharFn(face, @as(u32, @intCast(codepoint)), .{});
                    std.debug.assert(err_code == 0);
                    const glyph_height = @as(f32, @floatFromInt(face.glyph.metrics.height)) / 64;
                    glyph_width = @as(f32, @floatFromInt(face.glyph.metrics.width)) / 64;
                    advance = @as(f32, @floatFromInt(face.glyph.metrics.hori_advance)) / 64;
                    const descender: f32 = glyph_height - (@as(f32, @floatFromInt(face.glyph.metrics.hori_bearing_y)) / 64);
                    rendered_text_width += advance;
                    max_height = @max(max_height, glyph_height - descender);
                    max_descender = @max(max_descender, descender);
                }
                const overshoot = @max(0.0, glyph_width - advance);
                rendered_text_width -= overshoot;
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
                .x = @as(f32, @floatCast(placement_extent.x + margin_horizontal)),
                .y = @as(f32, @floatCast(placement_extent.y - margin_vertical)),
            };

            const has_kerning = face.face_flags.kerning;
            var previous_codepoint: u8 = 0;
            for (codepoints, 0..) |codepoint, codepoint_i| {
                const err_code = self.backend_ref.loadCharFn(face, @as(u32, @intCast(codepoint)), .{ .render = true });
                std.debug.assert(err_code == 0);
                const glyph_height = @as(f32, @floatFromInt(face.glyph.metrics.height)) / 64;
                const glyph_width = @as(f32, @floatFromInt(face.glyph.metrics.width)) / 64;
                const advance = @as(f32, @floatFromInt(face.glyph.metrics.hori_advance)) / 64;
                const x_offset: f32 = blk: {
                    if (codepoint_i == 0 or !has_kerning) {
                        break :blk (advance - glyph_width) / 2.0;
                    }
                    var kerning: freetype.Vector = undefined;
                    const ret = self.backend_ref.getKerningFn(
                        face,
                        @as(u32, @intCast(previous_codepoint)),
                        @as(u32, @intCast(codepoint)),
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
                    break :blk (@as(f32, @floatFromInt(kerning.x)) / 64) + (advance - glyph_width) / 2.0;
                };

                const y_offset: f32 = glyph_height - (@as(f32, @floatFromInt(face.glyph.metrics.hori_bearing_y)) / 64);
                const leftside_bearing = @as(f32, @floatCast((@as(f32, @floatFromInt(face.glyph.metrics.hori_bearing_x)) / 64) * screen_scale.horizontal));

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
                        .y = @as(f32, @floatCast(cursor.y + (y_offset * screen_scale.vertical))),
                        .width = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.width)) * screen_scale.horizontal)),
                        .height = @as(f32, @floatCast(@as(f64, @floatFromInt(glyph_texture_extent.height)) * screen_scale.vertical)),
                    };
                    cursor.x += writer_interface.write(screen_extent, texture_extent);
                }
                cursor.x += @as(f32, @floatCast(advance * screen_scale.horizontal));
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
                    .Dimensions2DNative = options.type_overrides.Dimensions2DNative,
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
