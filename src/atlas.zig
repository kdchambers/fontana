// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");

const AtlasConfiguration = struct {
    const SupportedPixelFormat = enum {
        rgba_f32,
        rgb_f32,
        greyscale_u8,
    };

    const SupportedEncoding = enum {
        ascii,
        utf_8,
    };

    pixel_format: SupportedPixelFormat,
    encoding: SupportedEncoding,

    /// Default is use u8 for ascii and u16 for utf-8.
    override_glyph_index_type: ?type = null,
};

pub fn Atlas(comptime config: AtlasConfiguration) type {
    return struct {
        pub const PixelType: type = switch (config.pixel_format) {
            .rgba_f32 => graphics.RGBA(f32),
            .rgb_f32 => graphics.RGB(f32),
            .greyscale_u8 => u8,
        };

        pub const CodepointType = switch (config.encoding) {
            .utf_8 => u32,
            .ascii => u8,
        };

        const GlyphIndex = blk: {
            if (config.override_glyph_index_type) |override_glyph_index_type| {
                break :blk override_glyph_index_type;
            }
            break :blk switch (config.encoding) {
                .ascii => u8,
                .utf_8 => u16,
            };
        };

        pub const FontAdapter = struct {
            pub const Internal = opaque {};

            internal: *align(8) Internal,

            //
            // VTable
            //
            scaleForPixelHeight: *const fn (self: *const FontAdapter, height_pixels: f32) f32,
            advanceHorizontalList: *const fn (self: *const FontAdapter, codepoints: []const CodepointType, out_advance_list: []u16) void,

            kernPairList: *const fn (
                self: *const FontAdapter,
                allocator: std.mem.Allocator,
                codepoints: []const CodepointType,
            ) error{ InvalidFont, InvalidCodepoint, OutOfMemory }![]otf.KernPair,

            glyphBoundingBox: *const fn (
                self: *const FontAdapter,
                codepoint: CodepointType,
            ) error{Unknown}!geometry.BoundingBox(i32),

            rasterizeGlyph: *const fn (
                self: *const FontAdapter,
                allocator: std.mem.Allocator,
                codepoint: CodepointType,
                scale: f32,
                texture_pixels: [*]PixelType,
                texture_dimensions: geometry.Dimensions2D(u32),
                extent: geometry.Extent2D(u32),
            ) error{ Unknown, OutOfMemory, InvalidInput }!void,
        };

        texture_buffer: [*]PixelType,
        texture_dimensions: geometry.Dimensions2D(u32),

        font_adapter: *const FontAdapter,

        /// List of vertical offsets needed to render
        /// Index corresponds to same index in character_list
        vertical_offset_list: []f32,
        /// Dimensions in texture of each glyph
        dimension_list: []geometry.Dimensions2D(u32),
        kerning_pairs: []otf.KernPair,
        advances: []u16,

        row_cell_count: u16,
        cell_dimensions: geometry.Dimensions2D(u16),
        space_advance_scaled: f32,
        size_scale: f32,

        /// List of charactors contained in the atlas
        codepoint_list: []CodepointType,

        pub fn atlasDimensions(self: @This()) geometry.Dimensions2D(u16) {
            const column_count: usize = @divFloor(self.codepoint_list.len, self.row_cell_count);
            return .{
                .width = self.cell_dimensions.width * self.row_cell_count,
                .height = self.cell_dimensions.height * column_count,
            };
        }

        inline fn indexForCodepoint(self: @This(), codepoint: CodepointType) ?GlyphIndex {
            for (self.codepoint_list) |cp, cp_i| {
                if (cp == codepoint) {
                    return @intCast(GlyphIndex, cp_i);
                }
            }
            return null;
        }

        fn advanceForGlyphPair(self: @This(), codepoint_a: CodepointType, codepoint_b: CodepointType) !f32 {
            const codepoint_index = try indexForCodepoint(codepoint_a);
            const pair_count = self.kerning_jump_array[codepoint_index];
            for (self.kerning_indices[codepoint_index .. codepoint_index + pair_count]) |kerning_entry| {
                if (kerning_entry.next_glyph_index == codepoint_b) {
                    return kerning_entry.advance;
                }
            }
            return error.KerningEntryMatchNotFound;
        }

        pub fn drawText(
            self: @This(),
            writer_interface: anytype,
            codepoint_list: []const CodepointType,
            placement: geometry.Coordinates2D(f32),
            scale_factor: geometry.Scale2D(f32),
        ) !void {
            var cursor = geometry.Coordinates2D(f32){ .x = 0, .y = 0 };
            var i: usize = 0;
            outer: while (i < codepoint_list.len) : (i += 1) {
                const codepoint = codepoint_list[i];
                if (codepoint == '\n') {
                    cursor.y += 1;
                    cursor.x = 0;
                    continue;
                }

                if (codepoint == 0 or codepoint == 255 or codepoint == 254) {
                    continue;
                }

                if (codepoint == ' ') {
                    cursor.x += self.space_advance_scaled * scale_factor.horizontal;
                    continue;
                }

                const line_height: f32 = 0.01;
                if (self.indexForCodepoint(codepoint)) |glyph_index| {
                    const texture_extent = self.textureExtentForGlyph(glyph_index);
                    const glyph_dimensions = self.dimension_list[glyph_index];
                    const y_offset = self.vertical_offset_list[glyph_index] * scale_factor.vertical;
                    const screen_extent = geometry.Extent2D(f32){
                        .x = placement.x + cursor.x,
                        .y = placement.y - y_offset + (line_height * cursor.y),
                        .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                        .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
                    };
                    try writer_interface.write(screen_extent, texture_extent);
                    //
                    // Apply kerning
                    //
                    if (i != codepoint_list.len - 1) {
                        const right_codepoint = codepoint_list[i + 1];
                        for (self.kerning_pairs) |kern_pair| {
                            const left = kern_pair.left_codepoint;
                            const right = kern_pair.right_codepoint;
                            if (left == codepoint and right == right_codepoint) {
                                const kern_advance = @intToFloat(f32, kern_pair.advance_x);
                                std.log.info("applying kern '{c}' -> '{c}' : {d} {d}", .{
                                    codepoint,
                                    right_codepoint,
                                    kern_advance,
                                    kern_advance * self.size_scale,
                                });
                                cursor.x += kern_advance * self.size_scale * scale_factor.horizontal;
                                continue :outer;
                            }
                        }
                    }
                    const base_advance = @intToFloat(f32, self.advances[glyph_index]) * self.size_scale;
                    cursor.x += base_advance * scale_factor.horizontal;
                } else {
                    std.log.warn("Codepoint not in atlas: '{c}'", .{codepoint});
                    std.debug.assert(false);
                }
            }
        }

        fn textureExtentForGlyph(self: @This(), glyph_index: GlyphIndex) geometry.Extent2D(f32) {
            const codepoint_dimensions = self.dimension_list[glyph_index];
            const altas_coordinates = geometry.Coordinates2D(usize){
                .x = (glyph_index % self.row_cell_count) * self.cell_dimensions.width,
                .y = @divFloor(glyph_index, self.row_cell_count) * self.cell_dimensions.height,
            };
            const texture_dimensions = geometry.Dimensions2D(f32){
                .width = @intToFloat(f32, self.texture_dimensions.width),
                .height = @intToFloat(f32, self.texture_dimensions.height),
            };
            return geometry.Extent2D(f32){
                .width = @intToFloat(f32, codepoint_dimensions.width) / texture_dimensions.width,
                .height = @intToFloat(f32, codepoint_dimensions.height) / texture_dimensions.height,
                .x = @intToFloat(f32, altas_coordinates.x) / texture_dimensions.width,
                .y = @intToFloat(f32, altas_coordinates.y) / texture_dimensions.height,
            };
        }

        fn textureExtentForCodepoint(self: @This(), codepoint: CodepointType) ?geometry.Extent2D(f32) {
            if (self.indexForCodepoint(codepoint)) |glyph_index| {
                return self.textureExtentForGlyph(glyph_index);
            }
            return null;
        }

        /// Rasterizes glyphs for all characters in char_list into texture_buffer
        /// Creates and returns an Atlas which stores meta data and exposes an interface for
        /// calculating draw positions for glyphs using kerning, etc
        pub fn init(
            self: *@This(),
            allocator: std.mem.Allocator,
            font_adapter: *const FontAdapter,
            codepoint_list: []const CodepointType,
            size_pixels: f32,
            space_advance: f32,
            texture_buffer: [*]PixelType,
            texture_dimensions: geometry.Dimensions2D(u32),
        ) !void {
            self.font_adapter = font_adapter;
            self.size_scale = font_adapter.scaleForPixelHeight(font_adapter, size_pixels);
            self.space_advance_scaled = space_advance;
            self.texture_buffer = texture_buffer;
            self.texture_dimensions = texture_dimensions;

            self.vertical_offset_list = try allocator.alloc(f32, codepoint_list.len);
            errdefer allocator.free(self.vertical_offset_list);

            self.dimension_list = try allocator.alloc(geometry.Dimensions2D(u32), codepoint_list.len);
            errdefer allocator.free(self.dimension_list);

            self.codepoint_list = try allocator.alloc(CodepointType, codepoint_list.len);
            errdefer allocator.free(self.codepoint_list);

            std.mem.copy(CodepointType, self.codepoint_list, codepoint_list);

            self.kerning_pairs = try font_adapter.kernPairList(font_adapter, allocator, codepoint_list);
            errdefer allocator.free(self.kerning_pairs);

            self.advances = try allocator.alloc(u16, codepoint_list.len);
            errdefer allocator.free(self.advances);
            font_adapter.advanceHorizontalList(font_adapter, codepoint_list, self.advances);

            {
                var max_width: u32 = 0;
                var max_height: u32 = 0;
                for (self.codepoint_list) |codepoint, codepoint_i| {
                    var dimension = &self.dimension_list[codepoint_i];
                    const bounding_box = try font_adapter.glyphBoundingBox(font_adapter, codepoint);
                    const bounding_box_scaled = geometry.BoundingBox(f64){
                        .x0 = @intToFloat(f64, bounding_box.x0) * self.size_scale,
                        .y0 = @intToFloat(f64, bounding_box.y0) * self.size_scale,
                        .x1 = @intToFloat(f64, bounding_box.x1) * self.size_scale,
                        .y1 = @intToFloat(f64, bounding_box.y1) * self.size_scale,
                    };
                    dimension.* = .{
                        .width = @floatToInt(u32, @ceil(bounding_box_scaled.x1) - @floor(bounding_box_scaled.x0)),
                        .height = @floatToInt(u32, @ceil(bounding_box_scaled.y1) - @floor(bounding_box_scaled.y0)),
                    };
                    self.vertical_offset_list[codepoint_i] = @intToFloat(f32, -bounding_box.y0) * self.size_scale;
                    max_width = @max(max_width, dimension.width);
                    max_height = @max(max_height, dimension.height);
                }
                self.cell_dimensions = .{
                    .width = @intCast(u16, max_width),
                    .height = @intCast(u16, max_height),
                };
            }
            self.row_cell_count = @floatToInt(u16, @sqrt(@intToFloat(f64, codepoint_list.len)));
            for (codepoint_list) |codepoint, codepoint_i| {
                const extent = geometry.Extent2D(u32){
                    .x = self.cell_dimensions.width * @intCast(u32, codepoint_i % self.row_cell_count),
                    .y = self.cell_dimensions.height * @intCast(u32, @divFloor(codepoint_i, self.row_cell_count)),
                    .width = self.cell_dimensions.width,
                    .height = self.cell_dimensions.height,
                };
                try font_adapter.rasterizeGlyph(
                    font_adapter,
                    allocator,
                    codepoint,
                    self.size_scale,
                    texture_buffer,
                    texture_dimensions,
                    extent,
                );
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.vertical_offset_list);
            allocator.free(self.dimension_list);
            allocator.free(self.kerning_pairs);
            allocator.free(self.codepoint_list);
            allocator.free(self.advances);
        }
    };
}
