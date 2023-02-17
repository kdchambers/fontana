// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const otf = @import("../otf.zig");
const Atlas = @import("../Atlas.zig");
const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");
const rasterizer = @import("../rasterizer.zig");
const api = @import("api.zig");

// Font type with default options
pub const Font = FontConfig(.{});

const ScaledGlyphMetric = struct {
    advance_x: f64,
    leftside_bearing: f64,
    descent: f64,
    height: f64,
};

pub fn PenConfigInternal(comptime options: api.PenConfigOptionsInternal) type {
    return struct {
        const types = options.type_overrides;

        backend_ref: *options.BackendType,
        atlas_ref: *Atlas,
        codepoints: []const u8,
        atlas_entries: []types.Extent2DPixel,
        atlas_entries_count: u32,
        font_scale: f64,

        pub fn init(
            self: *@This(),
            allocator: std.mem.Allocator,
            backend_ref: *options.BackendType,
            codepoints: []const u8,
            size_point: f64,
            points_per_pixel: f64,
            texture_size: u32,
            texture_pixels: [*]types.Pixel,
            atlas_ref: *Atlas,
        ) !void {
            self.backend_ref = backend_ref;
            self.codepoints = codepoints;
            self.font_scale = otf.fUnitToPixelScale(size_point, points_per_pixel, backend_ref.units_per_em);
            self.atlas_ref = atlas_ref;
            //
            // TODO: Don't hardcode max size
            //
            self.atlas_entries = try allocator.alloc(types.Extent2DPixel, 128);
            for (codepoints) |codepoint, codepoint_i| {
                const required_dimensions = try otf.getRequiredDimensions(backend_ref, codepoint, self.font_scale);
                // TODO: Implement spacing in Atlas
                self.atlas_entries[codepoint_i] = try self.atlas_ref.reserve(
                    types.Extent2DPixel,
                    allocator,
                    required_dimensions.width + 2,
                    required_dimensions.height + 2,
                );
                self.atlas_entries[codepoint_i].x += 1;
                self.atlas_entries[codepoint_i].y += 1;
                self.atlas_entries[codepoint_i].width -= 2;
                self.atlas_entries[codepoint_i].height -= 2;
                var pixel_writer = rasterizer.SubTexturePixelWriter(types.Pixel, types.Extent2DPixel){
                    .texture_width = texture_size,
                    .pixels = texture_pixels,
                    .write_extent = self.atlas_entries[codepoint_i],
                };
                try otf.rasterizeGlyph(allocator, pixel_writer, backend_ref, @floatCast(f32, self.font_scale), codepoint);
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.atlas_entries);
            self.atlas_entries_count = 0;
        }

        pub fn write(
            self: *@This(),
            codepoints: []const u8,
            placement: types.Coordinates2DNative,
            screen_scale: types.Scale2D,
            writer_interface: anytype,
        ) !void {
            var cursor = placement;
            const texture_width_height: f32 = @intToFloat(f32, self.atlas.size);
            var i: usize = 0;
            var right_codepoint_opt: ?u8 = null;
            while (i < codepoints.len) : (i += 1) {
                const codepoint = codepoints[i];
                if (codepoint == ' ') {
                    cursor.x += @floatCast(f32, self.backend_ref.space_advance * self.font_scale * screen_scale.horizontal);
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
                    .x = @floatCast(f32, cursor.x + (glyph_metrics.leftside_bearing * screen_scale.horizontal)),
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

        pub fn writeCentered(
            self: *@This(),
            codepoints: []const u8,
            placement_extent: types.Extent2DNative,
            screen_scale: types.Scale2D,
            writer_interface: anytype,
        ) !void {
            const texture_width_height: f32 = @intToFloat(f32, self.atlas_ref.size);
            var i: usize = 0;
            var right_codepoint_opt: ?u8 = null;
            var descent_max: f64 = 0;
            var ascender_max: f64 = 0;
            var total_width: f64 = 0;
            while (i < codepoints.len) : (i += 1) {
                const codepoint = codepoints[i];
                if (codepoint == ' ') {
                    total_width += self.backend_ref.space_advance * self.font_scale;
                    continue;
                }
                const glyph_metrics = self.glyphMetricsFromCodepoint(codepoint);
                descent_max = @max(descent_max, glyph_metrics.descent);
                ascender_max = @max(ascender_max, glyph_metrics.height - glyph_metrics.descent);
                const advance_x: f64 = blk: {
                    if (right_codepoint_opt) |right_codepoint| {
                        break :blk self.kernPairAdvance(codepoint, right_codepoint) orelse glyph_metrics.advance_x;
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
                const advance_x = self.glyphMetricsFromCodepoint(last_codepoint).advance_x;
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
                    cursor.x += @floatCast(f32, self.backend_ref.space_advance * self.font_scale * screen_scale.horizontal);
                    continue;
                }
                const glyph_metrics = self.glyphMetricsFromCodepoint(codepoint);
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
                        break :blk self.kernPairAdvance(codepoint, right_codepoint) orelse glyph_metrics.advance_x;
                    }
                    break :blk glyph_metrics.advance_x;
                };
                cursor.x += @floatCast(f32, advance_x * screen_scale.horizontal);
            }
        }

        //
        // Private interface
        //

        inline fn glyphMetricsFromCodepoint(self: *@This(), codepoint: u8) ScaledGlyphMetric {
            const glyph_index = otf.findGlyphIndex(self.backend_ref, codepoint);
            var metrics: ScaledGlyphMetric = undefined;
            const bounding_box = otf.calculateGlyphBoundingBox(self.backend_ref, glyph_index) catch unreachable;
            metrics.height = @intToFloat(f64, bounding_box.y1 - bounding_box.y0) * self.font_scale;
            std.debug.assert(metrics.height >= 0);
            metrics.leftside_bearing = @intToFloat(f64, otf.leftBearingForGlyph(self.backend_ref, glyph_index)) * self.font_scale;
            metrics.advance_x = @intToFloat(f64, otf.advanceXForGlyph(self.backend_ref, glyph_index)) * self.font_scale;
            metrics.descent = -@intToFloat(f64, bounding_box.y0) * self.font_scale;
            return metrics;
        }

        inline fn kernPairAdvance(self: *@This(), left_codepoint: u8, right_codepoint: u8) ?f64 {
            const unscaled_opt = otf.kernAdvanceGpos(self.backend_ref, left_codepoint, right_codepoint) catch unreachable;
            if (unscaled_opt) |unscaled| {
                return @intToFloat(f64, unscaled) * self.font_scale;
            }
            return null;
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
    };
}

pub fn FontConfig(comptime options: api.FontOptions) type {
    return struct {
        pub const PenOptions = struct {
            pixel_format: api.SupportedPixelFormat,
            PixelType: ?type = null,
        };

        pub fn PenConfig(comptime pen_options: PenOptions) type {
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
                .BackendType = otf.FontInfo,
                .pixel_format = pen_options.pixel_format,
            });
        }

        font: otf.FontInfo,

        pub inline fn construct(bytes: []const u8) !@This() {
            return .{ .font = try otf.parseFromBytes(bytes) };
        }

        pub inline fn init(self: *@This(), bytes: []const u8) !void {
            self.font = try otf.parseFromBytes(bytes);
        }

        pub inline fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.font.deinit(allocator);
        }

        pub fn PixelTypeInferred(comptime pen_options: PenOptions) type {
            return pen_options.PixelType orelse switch (pen_options.pixel_format) {
                .r8g8b8a8 => graphics.RGBA(u8),
                .r32g32b32a32 => graphics.RGBA(f32),
                else => @compileError("Pixel format not yet implemented"),
            };
        }

        pub inline fn createPen(
            self: *@This(),
            comptime pen_options: PenOptions,
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
                &self.font,
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
