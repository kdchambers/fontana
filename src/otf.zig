// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const toNative = std.mem.toNative;
const bigToNative = std.mem.bigToNative;
const eql = std.mem.eql;
const assert = std.debug.assert;

const graphics = @import("graphics.zig");

const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []graphics.RGBA(f32),
};

pub const FontType = enum {
    none,
    truetype_1,
    truetype_2,
    opentype_cff,
    opentype_1,
    apple,
};

const FWORD = i16;
const UFWORD = u16;

const GlyhHeader = extern struct {
    // See: https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
    //
    //  If the number of contours is greater than or equal to zero, this is a simple glyph.
    //  If negative, this is a composite glyph — the value -1 should be used for composite glyphs.
    contour_count: i16,
    x_minimum: i16,
    y_minimum: i16,
    x_maximum: i16,
    y_maximum: i16,
};

pub const TableHHEA = struct {
    const index = struct {
        const major_version = 0;
        const minor_version = 2;
        const ascender = 4;
        const descender = 6;
        const line_gap = 8;
        const advance_width_max = 10;
        const min_leftside_bearing = 12;
        const min_rightside_bearing = 14;
        const x_max_extent = 16;
        const caret_slope_rise = 18;
        const caret_slope_run = 20;
        const caret_offset = 22;
        const reserved_1 = 24;
        const reserved_2 = 26;
        const reserved_3 = 28;
        const reserved_4 = 30;
        const metric_data_format = 32;
        const number_of_hmetics = 34;
    };
};

pub const OffsetSubtable = struct {
    scaler_type: u32,
    tables_count: u16,
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,

    pub fn fromBigEndianBytes(bytes: *align(4) [@sizeOf(OffsetSubtable)]u8) @This() {
        var result = @ptrCast(*OffsetSubtable, bytes).*;

        result.scaler_type = toNative(u32, result.scaler_type, .Big);
        result.tables_count = toNative(u16, result.tables_count, .Big);
        result.search_range = toNative(u16, result.search_range, .Big);
        result.entry_selector = toNative(u16, result.entry_selector, .Big);
        result.range_shift = toNative(u16, result.range_shift, .Big);

        return result;
    }
};

pub const TableDirectory = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,

    pub fn isChecksumValid(self: @This()) bool {
        std.debug.assert(@sizeOf(@This()) == 16);

        var sum: u32 = 0;
        var iteractions_count: u32 = @sizeOf(@This()) / 4;

        var bytes = @ptrCast(*const u32, &self);
        while (iteractions_count > 0) : (iteractions_count -= 1) {
            _ = @addWithOverflow(u32, sum, bytes.*, &sum);
            bytes = @intToPtr(*const u32, @ptrToInt(bytes) + @sizeOf(u32));
        }
        const checksum = self.checksum;
        return (sum == checksum);
    }

    pub fn fromBigEndianBytes(bytes: *align(4) [@sizeOf(TableDirectory)]u8) ?TableDirectory {
        var result: TableDirectory = @ptrCast(*align(4) TableDirectory, bytes).*;

        // TODO: Disabled as not working
        // if (!result.isChecksumValid()) {
        // return null;
        // }

        result.length = toNative(u32, result.length, .Big);
        result.offset = toNative(u32, result.offset, .Big);

        return result;
    }
};

pub const Head = struct {
    version_major: i16,
    version_minor: i16,
    font_revision_major: i16,
    font_revision_minor: i16,
    checksum_adjustment: u32,
    magic_number: u32, // 0x5F0F3CF5
    flags: Flags,
    units_per_em: u16,
    created_timestamp: i64,
    modified_timestamp: i64,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    mac_style: MacStyle,
    lowest_rec_ppem: u16,
    font_direction_hint: i16,
    index_to_loc_format: i16,
    glyph_data_format: i16,

    const Flags = packed struct(u16) {
        y0_specifies_baseline: bool,
        left_blackbit_is_lsb: bool,
        scaled_point_size_differs: bool,
        use_integer_scaling: bool,
        reserved_microsoft: bool,
        layout_vertically: bool,
        reserved_0: bool,
        requires_layout_for_ling_rendering: bool,
        aat_font_with_metamorphosis_effects: bool,
        strong_right_to_left: bool,
        indic_style_effects: bool,
        reserved_adobe_0: bool,
        reserved_adobe_1: bool,
        reserved_adobe_2: bool,
        reserved_adobe_3: bool,
        simple_generic_symbols: bool,
    };

    const MacStyle = packed struct(u16) {
        bold: bool,
        italic: bool,
        underline: bool,
        outline: bool,
        shadow: bool,
        extended: bool,
        unused_bit_6: bool,
        unused_bit_7: bool,
        unused_bit_8: bool,
        unused_bit_9: bool,
        unused_bit_10: bool,
        unused_bit_11: bool,
        unused_bit_12: bool,
        unused_bit_13: bool,
        unused_bit_14: bool,
        unused_bit_15: bool,
    };
};

pub const cff_magic_number: u32 = 0x5F0F3CF5;

pub const PlatformID = enum(u8) { unicode = 0, max = 1, iso = 2, microsoft = 3 };

pub const CmapIndex = struct {
    version: u16,
    subtables_count: u16,
};

pub const CMAPPlatformID = enum(u16) {
    unicode = 0,
    macintosh = 1,
    reserved = 2,
    microsoft = 3,
};

pub const CMAPPlatformSpecificID = packed union {
    const Unicode = enum(u16) {
        version1_0,
        version1_1,
        iso_10646,
        unicode2_0_bmp_only,
        unicode2_0,
        unicode_variation_sequences,
        last_resort,
        other, // This value is allowed but shall be ignored
    };

    const Macintosh = enum(u16) {
        roman,
        japanese,
        traditional_chinese,
        // etc: https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6name.html
    };

    const Microsoft = enum(u16) {
        symbol,
        unicode_bmp_only,
        shift_jis,
        prc,
        big_five,
        johab,
        unicode_ucs_4,
    };

    unicode: Unicode,
    microsoft: Microsoft,
    macintosh: Macintosh,
};

pub const CMAPSubtable = extern struct {
    pub fn fromBigEndianBytes(bytes: []u8) ?CMAPSubtable {
        var table: CMAPSubtable = undefined;

        const platform_id_u16 = toNative(u16, @ptrCast(*u16, @alignCast(2, bytes.ptr)).*, .Big);

        if (platform_id_u16 > @enumToInt(CMAPPlatformID.microsoft)) {
            std.log.warn("Invalid platform ID '{d}' parsed from CMAP subtable", .{platform_id_u16});
            return null;
        }

        table.platform_id = @intToEnum(CMAPPlatformID, platform_id_u16);

        table.offset = toNative(u32, @ptrCast(*u32, @alignCast(4, &bytes.ptr[4])).*, .Big);

        const platform_specific_id_u16 = toNative(u16, @ptrCast(*u16, @alignCast(2, &bytes.ptr[2])).*, .Big);

        switch (table.platform_id) {
            .unicode => {
                if (platform_specific_id_u16 < @enumToInt(CMAPPlatformSpecificID.Unicode.last_resort)) {
                    table.platform_specific_id = .{ .unicode = @intToEnum(CMAPPlatformSpecificID.Unicode, platform_specific_id_u16) };
                } else {
                    table.platform_specific_id = .{ .unicode = .other };
                }
                std.log.info("Platform specific ID for '{}' => '{}'", .{ table.platform_id, table.platform_specific_id.unicode });
            },
            .microsoft => {
                unreachable;
            },
            .macintosh => {
                unreachable;
            },
            .reserved => {
                unreachable;
            },
        }

        return table;
    }

    platform_id: CMAPPlatformID,
    platform_specific_id: CMAPPlatformSpecificID,
    offset: u32,
};

pub const CMAPFormat2 = struct {
    format: u16,
    length: u16,
    language: u16,
};

pub const SectionRange = struct {
    offset: u32 = 0,
    length: u32 = 0,

    pub fn isNull(self: @This()) bool {
        return self.offset == 0;
    }
};

pub const DataSections = struct {
    dsig: SectionRange = .{},
    loca: SectionRange = .{},
    head: SectionRange = .{},
    glyf: SectionRange = .{},
    hhea: SectionRange = .{},
    hmtx: SectionRange = .{},
    hvar: SectionRange = .{},
    kern: SectionRange = .{},
    gpos: SectionRange = .{},
    svg: SectionRange = .{},
    maxp: SectionRange = .{},
    cmap: SectionRange = .{},
    name: SectionRange = .{},
};

const TableType = enum { cmap, loca, head, glyf, hhea, hmtx, kern, gpos, maxp };

const TableTypeList: [9]*const [4:0]u8 = .{
    "cmap",
    "loca",
    "head",
    "glyf",
    "hhea",
    "hmtx",
    "kern",
    "GPOS",
    "maxp",
};

//
// https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
//
pub const GlyphFlags = struct {
    const none: u8 = 0x00;
    const on_curve_point: u8 = 0x01;
    const x_short_vector: u8 = 0x02;
    const y_short_vector: u8 = 0x04;
    const repeat_flag: u8 = 0x08;
    const positive_x_short_vector: u8 = 0x10;
    const same_x: u8 = 0x10;
    const positive_y_short_vector: u8 = 0x20;
    const same_y: u8 = 0x20;
    const overlap_simple: u8 = 0x40;

    pub fn isFlagSet(value: u8, flag: u8) bool {
        return (value & flag) != 0;
    }
};

pub const FontInfo = struct {
    // zig fmt: off
    data: []u8,
    glyph_count: i32 = 0,
    loca: SectionRange = .{},
    head: SectionRange = .{},
    glyf: SectionRange = .{},
    hhea: SectionRange = .{},
    hmtx: SectionRange = .{},
    kern: SectionRange = .{},
    gpos: SectionRange = .{},
    svg: SectionRange = .{},
    maxp: SectionRange = .{},
    cff: Buffer = .{},
    index_map: i32 = 0,
    index_to_loc_format: i32 = 0,
    cmap_encoding_table_offset: u32 = 0,
// zig fmt: on
};

pub fn parseOTF(font_data: []u8) !FontInfo {
    var data_sections = DataSections{};
    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = 0 };
        var reader = fixed_buffer_stream.reader();

        const scaler_type = try reader.readIntBig(u32);
        const tables_count = try reader.readIntBig(u16);
        const search_range = try reader.readIntBig(u16);
        const entry_selector = try reader.readIntBig(u16);
        const range_shift = try reader.readIntBig(u16);

        _ = scaler_type;
        _ = search_range;
        _ = entry_selector;
        _ = range_shift;

        var i: usize = 0;
        while (i < tables_count) : (i += 1) {
            var tag_buffer: [4]u8 = undefined;
            var tag = tag_buffer[0..];
            _ = try reader.readAll(tag[0..]);
            const checksum = try reader.readIntBig(u32);
            // TODO: Use checksum
            _ = checksum;
            const offset = try reader.readIntBig(u32);
            const length = try reader.readIntBig(u32);

            std.debug.print("{d:2}.    {s}\n", .{ i + 1, tag });

            if (std.mem.eql(u8, "cmap", tag)) {
                data_sections.cmap.offset = offset;
                data_sections.cmap.length = length;
                continue;
            }

            if (std.mem.eql(u8, "DSIG", tag)) {
                data_sections.dsig.offset = offset;
                data_sections.dsig.length = length;
                continue;
            }

            if (std.mem.eql(u8, "loca", tag)) {
                data_sections.loca.offset = offset;
                data_sections.loca.length = length;
                continue;
            }

            if (std.mem.eql(u8, "head", tag)) {
                data_sections.head.offset = offset;
                data_sections.head.length = length;
                continue;
            }

            if (std.mem.eql(u8, "hvar", tag)) {
                data_sections.hvar.offset = offset;
                data_sections.hvar.length = length;
                continue;
            }

            if (std.mem.eql(u8, "glyf", tag)) {
                data_sections.glyf.offset = offset;
                data_sections.glyf.length = length;
                continue;
            }

            if (std.mem.eql(u8, "hhea", tag)) {
                data_sections.hhea.offset = offset;
                data_sections.hhea.length = length;
                continue;
            }

            if (std.mem.eql(u8, "hmtx", tag)) {
                data_sections.hmtx.offset = offset;
                data_sections.hmtx.length = length;
                continue;
            }

            if (std.mem.eql(u8, "kern", tag)) {
                data_sections.kern.offset = offset;
                data_sections.kern.length = length;
                continue;
            }

            if (std.mem.eql(u8, "GPOS", tag)) {
                data_sections.gpos.offset = offset;
                data_sections.gpos.length = length;
                continue;
            }

            if (std.mem.eql(u8, "maxp", tag)) {
                data_sections.maxp.offset = offset;
                data_sections.maxp.length = length;
                continue;
            }

            if (std.mem.eql(u8, "name", tag)) {
                data_sections.name.offset = offset;
                data_sections.name.length = length;
                continue;
            }
        }
    }

    var font_info = FontInfo{
        .data = font_data,
        .hhea = data_sections.hhea,
        .loca = data_sections.loca,
        .glyf = data_sections.glyf,
    };

    {
        std.debug.assert(!data_sections.maxp.isNull());

        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = data_sections.maxp.offset };
        var reader = fixed_buffer_stream.reader();
        const version_major = try reader.readIntBig(i16);
        const version_minor = try reader.readIntBig(i16);
        _ = version_major;
        _ = version_minor;
        font_info.glyph_count = try reader.readIntBig(u16);
        std.log.info("Glyphs found: {d}", .{font_info.glyph_count});
    }

    var head: Head = undefined;
    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = data_sections.head.offset };
        var reader = fixed_buffer_stream.reader();

        head.version_major = try reader.readIntBig(i16);
        head.version_minor = try reader.readIntBig(i16);
        head.font_revision_major = try reader.readIntBig(i16);
        head.font_revision_minor = try reader.readIntBig(i16);
        head.checksum_adjustment = try reader.readIntBig(u32);
        head.magic_number = try reader.readIntBig(u32);

        if (head.magic_number != 0x5F0F3CF5) {
            std.log.warn("Magic number not set to 0x5F0F3CF5. File might be corrupt", .{});
        }

        head.flags = try reader.readStruct(Head.Flags);

        head.units_per_em = try reader.readIntBig(u16);
        head.created_timestamp = try reader.readIntBig(i64);
        head.modified_timestamp = try reader.readIntBig(i64);

        head.x_min = try reader.readIntBig(i16);
        head.y_min = try reader.readIntBig(i16);
        head.x_max = try reader.readIntBig(i16);
        head.y_max = try reader.readIntBig(i16);

        std.debug.assert(head.x_min <= head.x_max);
        std.debug.assert(head.y_min <= head.y_max);

        head.mac_style = try reader.readStruct(Head.MacStyle);

        head.lowest_rec_ppem = try reader.readIntBig(u16);

        head.font_direction_hint = try reader.readIntBig(i16);
        head.index_to_loc_format = try reader.readIntBig(i16);
        head.glyph_data_format = try reader.readIntBig(i16);

        font_info.index_to_loc_format = head.index_to_loc_format;

        std.debug.assert(font_info.index_to_loc_format == 0 or font_info.index_to_loc_format == 1);
    }

    font_info.cmap_encoding_table_offset = outer: {
        std.debug.assert(!data_sections.cmap.isNull());

        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = data_sections.cmap.offset };
        var reader = fixed_buffer_stream.reader();

        const version = try reader.readIntBig(u16);
        const subtable_count = try reader.readIntBig(u16);

        _ = version;

        var i: usize = 0;
        while (i < subtable_count) : (i += 1) {
            comptime {
                std.debug.assert(@sizeOf(CMAPPlatformID) == 2);
                std.debug.assert(@sizeOf(CMAPPlatformSpecificID) == 2);
            }
            const platform_id = try reader.readEnum(CMAPPlatformID, .Big);
            const platform_specific_id = blk: {
                switch (platform_id) {
                    .unicode => break :blk CMAPPlatformSpecificID{ .unicode = try reader.readEnum(CMAPPlatformSpecificID.Unicode, .Big) },
                    else => return error.InvalidSpecificPlatformID,
                }
            };
            _ = platform_specific_id;
            const offset = try reader.readIntBig(u32);
            std.log.info("Platform: {}", .{platform_id});
            if (platform_id == .unicode) break :outer data_sections.cmap.offset + offset;
        }
        return error.InvalidPlatform;
    };

    return font_info;
}

fn fontType(font: []const u8) FontType {
    const TrueType1Tag: [4]u8 = .{ 49, 0, 0, 0 };
    const OpenTypeTag: [4]u8 = .{ 0, 1, 0, 0 };

    if (eql(u8, font, TrueType1Tag[0..])) return .truetype_1; // TrueType 1
    if (eql(u8, font, "typ1")) return .truetype_2; // TrueType with type 1 font -- we don't support this!
    if (eql(u8, font, "OTTO")) return .opentype_cff; // OpenType with CFF
    if (eql(u8, font, OpenTypeTag[0..])) return .opentype_1; // OpenType 1.0
    if (eql(u8, font, "true")) return .apple; // Apple specification for TrueType fonts

    return .none;
}

pub fn getFontOffsetForIndex(font_collection: []u8, index: i32) i32 {
    const font_type = fontType(font_collection);
    if (font_type == .none) {
        return if (index == 0) 0 else -1;
    }
    return -1;
}

fn findGlyphIndex(font_info: FontInfo, unicode_codepoint: i32) u32 {
    const data = font_info.data;
    const encoding_offset = font_info.cmap_encoding_table_offset;

    if (unicode_codepoint > 0xffff) {
        std.log.info("Invalid codepoint", .{});
        return 0;
    }

    const base_index: usize = @ptrToInt(data.ptr) + encoding_offset;
    const format: u16 = bigToNative(u16, @intToPtr(*u16, base_index).*);

    // TODO:
    std.debug.assert(format == 4);

    const segcount = toNative(u16, @intToPtr(*u16, base_index + 6).*, .Big) >> 1;
    var search_range = toNative(u16, @intToPtr(*u16, base_index + 8).*, .Big) >> 1;
    var entry_selector = toNative(u16, @intToPtr(*u16, base_index + 10).*, .Big);
    const range_shift = toNative(u16, @intToPtr(*u16, base_index + 12).*, .Big) >> 1;

    const end_count: u32 = encoding_offset + 14;
    var search: u32 = end_count;

    if (unicode_codepoint >= toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + search + (range_shift * 2)).*, .Big)) {
        search += range_shift * 2;
    }

    search -= 2;

    while (entry_selector != 0) {
        var end: u16 = undefined;
        search_range = search_range >> 1;

        end = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + search + (search_range * 2)).*, .Big);

        if (unicode_codepoint > end) {
            search += search_range * 2;
        }
        entry_selector -= 1;
    }

    search += 2;

    {
        var offset: u16 = undefined;
        var start: u16 = undefined;
        const item: u32 = (search - end_count) >> 1;

        assert(unicode_codepoint <= toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + end_count + (item * 2)).*, .Big));
        start = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + encoding_offset + 14 + (segcount * 2) + 2 + (2 * item)).*, .Big);

        if (unicode_codepoint < start) {
            // TODO: return error
            return 0;
        }

        offset = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + encoding_offset + 14 + (segcount * 6) + 2 + (item * 2)).*, .Big);
        if (offset == 0) {
            const base = bigToNative(i16, @intToPtr(*i16, base_index + 14 + (segcount * 4) + 2 + (2 * item)).*);
            return @intCast(u32, unicode_codepoint + base);
        }

        const result_addr_index = @ptrToInt(data.ptr) + offset + @intCast(usize, unicode_codepoint - start) * 2 + encoding_offset + 14 + (segcount * 6) + 2 + (2 * item);

        const result_addr = @intToPtr(*u8, result_addr_index);
        const result_addr_aligned = @ptrCast(*u16, @alignCast(2, result_addr));

        return @intCast(u32, toNative(u16, result_addr_aligned.*, .Big));
    }
}

fn createGlyphBitmap(allocator: Allocator, info: FontInfo, scale: f32, glyph_index: i32) !Bitmap {
    const vertices = try getGlyphShape(allocator, info, glyph_index);
    defer allocator.free(vertices);

    const bounding_box = try getGlyphBoundingBox(info, glyph_index);
    const bounding_box_scaled = BoundingBox(i32){
        .x0 = @floatToInt(i32, @floor(@intToFloat(f64, bounding_box.x0) * scale)),
        .y0 = @floatToInt(i32, @floor(@intToFloat(f64, bounding_box.y0) * scale)),
        .x1 = @floatToInt(i32, @ceil(@intToFloat(f64, bounding_box.x1) * scale)),
        .y1 = @floatToInt(i32, @ceil(@intToFloat(f64, bounding_box.y1) * scale)),
    };

    std.debug.assert(bounding_box.y1 >= bounding_box.y0);
    for (vertices) |*vertex| {
        vertex.x -= @intCast(i16, bounding_box.x0);
        vertex.y -= @intCast(i16, bounding_box.y0);
        if (@intToEnum(VMove, vertex.kind) == .curve) {
            vertex.control1_x -= @intCast(i16, bounding_box.x0);
            vertex.control1_y -= @intCast(i16, bounding_box.y0);
        }
    }
    const dimensions = Dimensions2D(u32){
        .width = @intCast(u32, bounding_box_scaled.x1 - bounding_box_scaled.x0),
        .height = @intCast(u32, bounding_box_scaled.y1 - bounding_box_scaled.y0),
    };

    var bitmap = Bitmap{
        .width = dimensions.width,
        .height = dimensions.height,
        .pixels = undefined,
    };

    // TODO: Implement rasterizer
    // bitmap.pixels = try rasterize(allocator, dimensions, vertices, scale.x);
    return bitmap;
}
