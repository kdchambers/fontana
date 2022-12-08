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
    const PixelType: type = switch (config.pixel_format) {
        .rgba_f32 => graphics.RGBA(f32),
        .rgb_f32 => graphics.RGB(f32),
        .greyscale_u8 => u8,
    };

    const CodepointType = switch (config.encoding) {
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

    const KerningIndex = packed struct {
        next_glyph_index: GlyphIndex,
        advance: f32,
    };

    return struct {
        texture_buffer: [*]PixelType,
        texture_dimensions: geometry.Dimensions2D(u16),

        /// List of vertical offsets needed to render
        /// Index corresponds to same index in character_list
        vertical_offset_list: []f32,
        /// Dimensions in texture of each glyph
        dimension_list: []geometry.Dimensions2D(u32),
        kerning_jump_array: []GlyphIndex,
        kerning_indices: []KerningIndex,

        row_cell_count: u16,
        cell_dimensions: geometry.Dimensions2D(u16),
        space_advance_scaled: f32,

        /// List of charactors contained in the atlas
        codepoint_list: []CodepointType,

        inline fn indexForCodepoint(self: @This(), codepoint: CodepointType) ?GlyphIndex {
            for (self.codepoint_list) |cp, cp_i| {
                if (cp == codepoint) {
                    return @intCast(GlyphIndex, cp_i);
                }
            }
            return null;
        }

        /// Memory required for Atlas itself (Not Texure)
        pub fn requiredMemory(character_count: u32) u32 {
            // NOTE: bp = bytes_per
            const bp_vertical_offset = @sizeOf(i16);
            const bp_dimension = @sizeOf(u32);
            const bp_kerning_jump = @sizeOf(GlyphIndex);
            const bp_kerning_index = @sizeOf(KerningIndex);
            const bp_codepoint = @sizeOf(CodepointType);

            const bytes_per_character = bp_vertical_offset + bp_dimension + bp_kerning_jump + bp_kerning_index + bp_codepoint;
            // +1 to cover padding required for alignment
            return bytes_per_character * (character_count + 1);
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
            for (codepoint_list) |codepoint| {
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
                    cursor.x += @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal;
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
        /// NOTE: codepoint_list referenced but not owned
        pub fn init(
            self: *@This(),
            allocator: std.mem.Allocator,
            font: otf.FontInfo,
            codepoint_list: []const CodepointType,
            size_pixels: f32,
            texture_buffer: [*]PixelType,
            texture_dimensions: geometry.Dimensions2D(u16),
        ) !void {
            self.texture_buffer = texture_buffer;
            self.texture_dimensions = texture_dimensions;

            self.vertical_offset_list = try allocator.alloc(f32, codepoint_list.len);
            self.dimension_list = try allocator.alloc(geometry.Dimensions2D(u32), codepoint_list.len);
            self.kerning_jump_array = try allocator.alloc(GlyphIndex, codepoint_list.len);
            self.kerning_indices = try allocator.alloc(KerningIndex, codepoint_list.len);
            self.codepoint_list = try allocator.alloc(CodepointType, codepoint_list.len);
            std.mem.copy(CodepointType, self.codepoint_list, codepoint_list);

            const scale = otf.scaleForPixelHeight(font, size_pixels);
            self.space_advance_scaled = font.space_advance * scale;

            {
                var max_width: u32 = 0;
                var max_height: u32 = 0;
                for (self.codepoint_list) |codepoint, codepoint_i| {
                    var dimension = &self.dimension_list[codepoint_i];
                    dimension.* = try otf.getRequiredDimensions(font, codepoint, scale);
                    const bounding_box = try otf.calculateGlyphBoundingBoxScaled(font, otf.findGlyphIndex(font, codepoint), scale);
                    self.vertical_offset_list[codepoint_i] = @floatCast(f32, bounding_box.y0);
                    max_width = @max(max_width, dimension.width);
                    max_height = @max(max_height, dimension.height);
                }
                self.cell_dimensions = .{
                    .width = @intCast(u16, max_width),
                    .height = @intCast(u16, max_height),
                };
            }
            self.row_cell_count = @floatToInt(u16, @sqrt(@intToFloat(f64, codepoint_list.len)));
            var pixel_writer = rasterizer.SubTexturePixelWriter(graphics.RGBA(f32)){
                .texture_width = texture_dimensions.width,
                .pixels = texture_buffer,
                .write_extent = .{
                    .width = self.cell_dimensions.width,
                    .height = self.cell_dimensions.height,
                    .x = undefined,
                    .y = undefined,
                },
            };
            for (codepoint_list) |codepoint, codepoint_i| {
                pixel_writer.write_extent.x = self.cell_dimensions.width * @intCast(u32, codepoint_i % self.row_cell_count);
                pixel_writer.write_extent.y = self.cell_dimensions.height * @intCast(u32, @divFloor(codepoint_i, self.row_cell_count));
                _ = try otf.rasterizeGlyph(allocator, pixel_writer, font, scale, codepoint);
            }
            //
            // TODO: Kearning
            //
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.vertical_offset_list);
            allocator.free(self.dimension_list);
            allocator.free(self.kerning_jump_array);
            allocator.free(self.kerning_indices);
            allocator.free(self.codepoint_list);
        }
    };
}
