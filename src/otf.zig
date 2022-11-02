// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const toNative = std.mem.toNative;
const bigToNative = std.mem.bigToNative;
const eql = std.mem.eql;
const assert = std.debug.assert;

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const rasterizer = @import("rasterizer.zig");

const Outline = rasterizer.Outline;
const OutlineSegment = rasterizer.OutlineSegment;
const Point = geometry.Point;

pub const Bitmap = extern struct {
    width: u32,
    height: u32,
    pixels: [*]graphics.RGBA(f32),
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

pub const SectionRange = extern struct {
    offset: u32 = 0,
    length: u32 = 0,

    pub fn isNull(self: @This()) bool {
        return self.offset == 0;
    }
};

pub const DataSections = extern struct {
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

pub const FontInfo = extern struct {
    data: [*]u8,
    data_len: u32,
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
    index_map: i32 = 0,
    index_to_loc_format: i32 = 0,
    cmap_encoding_table_offset: u32 = 0,
};

const Buffer = extern struct {
    ptr: [*]u8 = undefined,
    len: u32,
    cursor: u32 = 0,
    size: u32 = 0,
};

pub fn parseFromBytes(font_data: []u8) !FontInfo {
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
        .data = font_data.ptr,
        .data_len = @intCast(u32, font_data.len),
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

const Vertex = packed struct {
    x: i16,
    y: i16,
    // Refer to control points for bezier curves
    control1_x: i16,
    control1_y: i16,
    kind: u8,
    is_active: u8 = 0,
};

fn findGlyphIndex(font_info: FontInfo, unicode_codepoint: i32) u32 {
    const data = font_info.data[0..font_info.data_len];
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

inline fn readBigEndian(comptime T: type, index: usize) T {
    return bigToNative(T, @intToPtr(*T, index).*);
}

pub fn getAscent(font: FontInfo) i16 {
    const offset = font.hhea.offset + TableHHEA.index.ascender;
    return readBigEndian(i16, @ptrToInt(font.data.ptr) + offset);
}

pub fn getDescent(font: FontInfo) i16 {
    const offset = font.hhea.offset + TableHHEA.index.descender;
    return readBigEndian(i16, @ptrToInt(font.data.ptr) + offset);
}

fn parseGlyfTableIndexForGlyph(font: FontInfo, glyph_index: i32) !usize {
    if (glyph_index >= font.glyph_count) return error.InvalidGlyphIndex;

    const font_data_start_index = @ptrToInt(&font.data[0]);
    if (font.index_to_loc_format != 0 and font.index_to_loc_format != 1) return error.InvalidIndexToLocationFormat;
    const loca_start = font_data_start_index + font.loca.offset;
    const glyf_offset = @intCast(usize, font.glyf.offset);

    var glyph_data_offset: usize = 0;
    var next_glyph_data_offset: usize = 0;

    // Use 16 or 32 bit offsets based on index_to_loc_format
    // https://docs.microsoft.com/en-us/typography/opentype/spec/head
    if (font.index_to_loc_format == 0) {
        // Location values are stored as half the actual value.
        // https://docs.microsoft.com/en-us/typography/opentype/spec/loca#short-version
        const loca_table_offset: usize = loca_start + (@intCast(usize, glyph_index) * 2);
        glyph_data_offset = glyf_offset + @intCast(u32, readBigEndian(u16, loca_table_offset + 0)) * 2;
        next_glyph_data_offset = glyf_offset + @intCast(u32, readBigEndian(u16, loca_table_offset + 2)) * 2;
    } else {
        glyph_data_offset = glyf_offset + readBigEndian(u32, loca_start + (@intCast(usize, glyph_index) * 4) + 0);
        next_glyph_data_offset = glyf_offset + readBigEndian(u32, loca_start + (@intCast(usize, glyph_index) * 4) + 4);
    }

    if (glyph_data_offset == next_glyph_data_offset) {
        // https://docs.microsoft.com/en-us/typography/opentype/spec/loca
        // If loca[n] == loca[n + 1], that means the glyph has no outline (E.g space character)
        return error.GlyphHasNoOutline;
    }

    return glyph_data_offset;
}

fn calculateGlyphBoundingBox(font: FontInfo, glyph_index: i32) !geometry.BoundingBox(i32) {
    const section_index: usize = try parseGlyfTableIndexForGlyph(font, glyph_index);
    const font_data_start_index = @ptrToInt(&font.data[0]);
    const base_index: usize = font_data_start_index + section_index;
    return geometry.BoundingBox(i32){
        .x0 = bigToNative(i16, @intToPtr(*i16, base_index + 2).*), // min_x
        .y0 = bigToNative(i16, @intToPtr(*i16, base_index + 4).*), // min_y
        .x1 = bigToNative(i16, @intToPtr(*i16, base_index + 6).*), // max_x
        .y1 = bigToNative(i16, @intToPtr(*i16, base_index + 8).*), // max_y
    };
}

fn calculateGlyphBoundingBoxScaled(font: FontInfo, glyph_index: i32, scale: f64) !geometry.BoundingBox(i32) {
    const unscaled = try calculateGlyphBoundingBox(font, glyph_index);
    return geometry.BoundingBox(i32){
        .x0 = @floatToInt(i32, @floor(@intToFloat(f64, unscaled.x0) * scale)),
        .y0 = @floatToInt(i32, @floor(@intToFloat(f64, unscaled.y0) * scale)),
        .x1 = @floatToInt(i32, @ceil(@intToFloat(f64, unscaled.x1) * scale)),
        .y1 = @floatToInt(i32, @ceil(@intToFloat(f64, unscaled.y1) * scale)),
    };
}

pub fn rasterizeGlyph(allocator: std.mem.Allocator, font: FontInfo, scale: f32, codepoint: i32) !Bitmap {
    const glyph_index: i32 = @intCast(i32, findGlyphIndex(font, codepoint));
    const vertices: []Vertex = try loadGlyphVertices(allocator, font, glyph_index);
    defer allocator.free(vertices);

    const bounding_box = try calculateGlyphBoundingBox(font, glyph_index);
    const bounding_box_scaled = geometry.BoundingBox(i32){
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
    const dimensions = geometry.Dimensions2D(u32){
        .width = @intCast(u32, bounding_box_scaled.x1 - bounding_box_scaled.x0),
        .height = @intCast(u32, bounding_box_scaled.y1 - bounding_box_scaled.y0),
    };

    var bitmap = Bitmap{
        .width = dimensions.width,
        .height = dimensions.height,
        .pixels = undefined,
    };

    const outlines = try createOutlines(allocator, vertices, @intToFloat(f64, dimensions.height), scale);
    defer allocator.free(outlines);

    bitmap.pixels = try rasterizer.rasterize(allocator, dimensions, outlines);
    return bitmap;
}

fn closeShape(
    vertices: []Vertex,
    vertices_count: u32,
    was_off: bool,
    start_off: bool,
    sx: i32,
    sy: i32,
    scx: i32,
    scy: i32,
    control1_x: i32,
    control1_y: i32,
) u32 {
    var vertices_count_local: u32 = vertices_count;

    if (start_off) {
        if (was_off) {
            setVertex(&vertices[vertices_count_local], .curve, @divFloor(control1_x + scx, 2), @divFloor(control1_y + scy, 2), control1_x, control1_y);
            vertices_count_local += 1;
        }
        setVertex(&vertices[vertices_count_local], .curve, sx, sy, scx, scy);
        vertices_count_local += 1;
    } else {
        if (was_off) {
            setVertex(&vertices[vertices_count_local], .curve, sx, sy, control1_x, control1_y);
            vertices_count_local += 1;
        } else {
            setVertex(&vertices[vertices_count_local], .line, sx, sy, 0, 0);
            vertices_count_local += 1;
        }
    }

    return vertices_count_local;
}

fn setVertex(vertex: *Vertex, kind: VMove, x: i32, y: i32, control1_x: i32, control1_y: i32) void {
    vertex.kind = @enumToInt(kind);
    vertex.x = @intCast(i16, x);
    vertex.y = @intCast(i16, y);
    vertex.control1_x = @intCast(i16, control1_x);
    vertex.control1_y = @intCast(i16, control1_y);
}

const VMove = enum(u8) {
    none,
    move = 1,
    line,
    curve,
    cubic,
};

fn isFlagSet(value: u8, bit_mask: u8) bool {
    return (value & bit_mask) != 0;
}

pub fn scaleForPixelHeight(font: FontInfo, height: f32) f32 {
    const font_data_start_index = @ptrToInt(&font.data[0]);
    assert(font.hhea.offset != 0);
    const base_index: usize = font_data_start_index + font.hhea.offset;
    const first = bigToNative(i16, @intToPtr(*i16, (base_index + 4)).*); //ascender
    const second = bigToNative(i16, @intToPtr(*i16, (base_index + 6)).*); // descender
    const fheight = @intToFloat(f32, first - second);
    return height / fheight;
}

pub fn getRequiredDimensions(font: FontInfo, codepoint: i32, scale: f64) !geometry.Dimensions2D(u32) {
    const glyph_index = @intCast(i32, findGlyphIndex(font, codepoint));
    const bounding_box = try calculateGlyphBoundingBoxScaled(font, glyph_index, scale);
    std.debug.assert(bounding_box.x1 >= bounding_box.x0);
    std.debug.assert(bounding_box.y1 >= bounding_box.y0);
    return geometry.Dimensions2D(u32){
        .width = @intCast(u32, bounding_box.x1 - bounding_box.x0),
        .height = @intCast(u32, bounding_box.y1 - bounding_box.y0),
    };
}

fn loadGlyphVertices(allocator: std.mem.Allocator, font: FontInfo, glyph_index: i32) ![]Vertex {
    const data = font.data;
    var vertices: []Vertex = undefined;
    var vertices_count: u32 = 0;

    var min_x: i16 = undefined;
    var min_y: i16 = undefined;
    var max_x: i16 = undefined;
    var max_y: i16 = undefined;
    var glyph_dimensions: geometry.Dimensions2D(u32) = undefined;

    // Find the byte offset of the glyh table
    const glyph_offset = try parseGlyfTableIndexForGlyph(font, glyph_index);
    const font_data_start_index = @ptrToInt(&data[0]);
    const glyph_offset_index: usize = font_data_start_index + glyph_offset;

    if (glyph_offset < 0) {
        return error.InvalidGlypOffset;
    }

    // Beginning of the glyf table
    // See: https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
    const contour_count_signed = readBigEndian(i16, glyph_offset_index);

    min_x = readBigEndian(i16, glyph_offset_index + 2);
    min_y = readBigEndian(i16, glyph_offset_index + 4);
    max_x = readBigEndian(i16, glyph_offset_index + 6);
    max_y = readBigEndian(i16, glyph_offset_index + 8);

    glyph_dimensions.width = @intCast(u32, max_x - min_x + 1);
    glyph_dimensions.height = @intCast(u32, max_y - min_y + 1);

    if (contour_count_signed > 0) {
        const contour_count: u32 = @intCast(u16, contour_count_signed);

        var j: i32 = 0;
        var m: u32 = 0;
        var n: u16 = 0;

        // Index of the next point that begins a new contour
        // This will correspond to value after end_points_of_contours
        var next_move: i32 = 0;

        var off: usize = 0;

        // end_points_of_contours is located directly after GlyphHeader in the glyf table
        const end_points_of_contours = @intToPtr([*]u16, glyph_offset_index + @sizeOf(GlyhHeader));
        const end_points_of_contours_size = @intCast(usize, contour_count * @sizeOf(u16));

        const simple_glyph_table_index = glyph_offset_index + @sizeOf(GlyhHeader);

        // Get the size of the instructions so we can skip past them
        const instructions_size_bytes = readBigEndian(i16, simple_glyph_table_index + end_points_of_contours_size);

        var glyph_flags: [*]u8 = @intToPtr([*]u8, glyph_offset_index + @sizeOf(GlyhHeader) + (@intCast(usize, contour_count) * 2) + 2 + @intCast(usize, instructions_size_bytes));

        // NOTE: The number of flags is determined by the last entry in the endPtsOfContours array
        n = 1 + readBigEndian(u16, @ptrToInt(end_points_of_contours) + (@intCast(usize, contour_count - 1) * 2));

        // What is m here?
        // Size of contours
        {
            // Allocate space for all the flags, and vertices
            m = n + (2 * contour_count);
            vertices = try allocator.alloc(Vertex, @intCast(usize, m) * @sizeOf(Vertex));

            assert((m - n) > 0);
            off = (2 * contour_count);
        }

        var flags: u8 = GlyphFlags.none;
        var flags_len: u32 = 0;
        {
            var i: usize = 0;
            var flag_count: u8 = 0;
            while (i < n) : (i += 1) {
                if (flag_count == 0) {
                    flags = glyph_flags[0];
                    glyph_flags = glyph_flags + 1;
                    if (isFlagSet(flags, GlyphFlags.repeat_flag)) {
                        // If `repeat_flag` is set, the next flag is the number of times to repeat
                        flag_count = glyph_flags[0];
                        glyph_flags = glyph_flags + 1;
                    }
                } else {
                    flag_count -= 1;
                }
                vertices[@intCast(usize, off) + @intCast(usize, i)].kind = flags;
                flags_len += 1;
            }
        }

        {
            var x: i16 = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                flags = vertices[@intCast(usize, off) + @intCast(usize, i)].kind;
                if (isFlagSet(flags, GlyphFlags.x_short_vector)) {
                    const dx: i16 = glyph_flags[0];
                    glyph_flags += 1;
                    x += if (isFlagSet(flags, GlyphFlags.positive_x_short_vector)) dx else -dx;
                } else {
                    if (!isFlagSet(flags, GlyphFlags.same_x)) {

                        // The current x-coordinate is a signed 16-bit delta vector
                        const abs_x = (@intCast(i16, glyph_flags[0]) << 8) + glyph_flags[1];

                        x += abs_x;
                        glyph_flags += 2;
                    }
                }
                // If: `!x_short_vector` and `same_x` then the same `x` value shall be appended
                vertices[off + i].x = x;
            }
        }

        {
            var y: i16 = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                flags = vertices[off + i].kind;
                if (isFlagSet(flags, GlyphFlags.y_short_vector)) {
                    const dy: i16 = glyph_flags[0];
                    glyph_flags += 1;
                    y += if (isFlagSet(flags, GlyphFlags.positive_y_short_vector)) dy else -dy;
                } else {
                    if (!isFlagSet(flags, GlyphFlags.same_y)) {
                        // The current y-coordinate is a signed 16-bit delta vector
                        const abs_y = (@intCast(i16, glyph_flags[0]) << 8) + glyph_flags[1];
                        y += abs_y;
                        glyph_flags += 2;
                    }
                }
                // If: `!y_short_vector` and `same_y` then the same `y` value shall be appended
                vertices[off + i].y = y;
            }
        }
        assert(vertices_count == 0);

        var i: usize = 0;
        var x: i16 = 0;
        var y: i16 = 0;

        var control1_x: i32 = 0;
        var control1_y: i32 = 0;
        var start_x: i32 = 0;
        var start_y: i32 = 0;

        var scx: i32 = 0; // start_control_point_x
        var scy: i32 = 0; // start_control_point_y

        var was_off: bool = false;
        var first_point_off_curve: bool = false;

        next_move = 0;
        while (i < n) : (i += 1) {
            const current_vertex = vertices[off + i];
            if (next_move == i) { // End of contour
                if (i != 0) {
                    vertices_count = closeShape(vertices, vertices_count, was_off, first_point_off_curve, start_x, start_y, scx, scy, control1_x, control1_y);
                }

                first_point_off_curve = ((current_vertex.kind & GlyphFlags.on_curve_point) == 0);
                if (first_point_off_curve) {
                    scx = current_vertex.x;
                    scy = current_vertex.y;
                    if (!isFlagSet(vertices[off + i + 1].kind, GlyphFlags.on_curve_point)) {
                        start_x = x + (vertices[off + i + 1].x >> 1);
                        start_y = y + (vertices[off + i + 1].y >> 1);
                    } else {
                        start_x = current_vertex.x + (vertices[off + i + 1].x);
                        start_y = current_vertex.y + (vertices[off + i + 1].y);
                        i += 1;
                    }
                } else {
                    start_x = current_vertex.x;
                    start_y = current_vertex.y;
                }
                setVertex(&vertices[vertices_count], .move, start_x, start_y, 0, 0);
                vertices_count += 1;
                was_off = false;
                next_move = 1 + readBigEndian(i16, @ptrToInt(end_points_of_contours) + (@intCast(usize, j) * 2));
                j += 1;
            } else {
                // Continue current contour
                if (0 == (current_vertex.kind & GlyphFlags.on_curve_point)) {
                    if (was_off) {
                        // Even though we've encountered 2 control points in a row, this is still a simple
                        // quadradic bezier (I.e 1 control point, 2 real points)
                        // We can calculate the real point that lies between them by taking the average
                        // of the two control points (It's omitted because it's redundant information)
                        // https://stackoverflow.com/questions/20733790/
                        const average_x = @divFloor(control1_x + current_vertex.x, 2);
                        const average_y = @divFloor(control1_y + current_vertex.y, 2);
                        setVertex(&vertices[vertices_count], .curve, average_x, average_y, control1_x, control1_y);
                        vertices_count += 1;
                    }
                    control1_x = current_vertex.x;
                    control1_y = current_vertex.y;
                    was_off = true;
                } else {
                    if (was_off) {
                        setVertex(&vertices[vertices_count], .curve, current_vertex.x, current_vertex.y, control1_x, control1_y);
                    } else {
                        setVertex(&vertices[vertices_count], .line, current_vertex.x, current_vertex.y, 0, 0);
                    }
                    vertices_count += 1;
                    was_off = false;
                }
            }
        }
        vertices_count = closeShape(vertices, vertices_count, was_off, first_point_off_curve, start_x, start_y, scx, scy, control1_x, control1_y);
    } else if (contour_count_signed < 0) {
        // Glyph is composite
        // TODO: Implement
        return error.InvalidContourCount;
    } else {
        unreachable;
    }

    return allocator.shrink(vertices, vertices_count);
}

/// Converts array of Vertex into array of Outline (Our own format)
/// Applies Y flip and scaling
fn createOutlines(allocator: std.mem.Allocator, vertices: []Vertex, height: f64, scale: f32) ![]Outline {
    // TODO:
    std.debug.assert(@intToEnum(VMove, vertices[0].kind) == .move);

    var outline_segment_lengths = [1]u32{0} ** 32;
    const outline_count: u32 = blk: {
        var count: u32 = 0;
        for (vertices[1..]) |vertex| {
            if (@intToEnum(VMove, vertex.kind) == .move) {
                count += 1;
                continue;
            }
            outline_segment_lengths[count] += 1;
        }
        break :blk count + 1;
    };

    var outlines = try allocator.alloc(Outline, outline_count);
    {
        var i: u32 = 0;
        while (i < outline_count) : (i += 1) {
            outlines[i].segments = try allocator.alloc(OutlineSegment, outline_segment_lengths[i]);
        }
    }

    {
        var vertex_index: u32 = 1;
        var outline_index: u32 = 0;
        var outline_segment_index: u32 = 0;
        while (vertex_index < vertices.len) {
            switch (@intToEnum(VMove, vertices[vertex_index].kind)) {
                .move => {
                    vertex_index += 1;
                    outline_index += 1;
                    outline_segment_index = 0;
                },
                .line => {
                    const from = vertices[vertex_index - 1];
                    const to = vertices[vertex_index];
                    const point_from = Point(f64){ .x = @intToFloat(f64, from.x) * scale, .y = height - (@intToFloat(f64, from.y) * scale) };
                    const point_to = Point(f64){ .x = @intToFloat(f64, to.x) * scale, .y = height - (@intToFloat(f64, to.y) * scale) };
                    const dist = geometry.distanceBetweenPoints(point_from, point_to);
                    outlines[outline_index].segments[outline_segment_index] = OutlineSegment{
                        .from = point_from,
                        .to = point_to,
                        .t_per_pixel = 1.0 / dist,
                    };
                    vertex_index += 1;
                    outline_segment_index += 1;
                },
                .curve => {
                    const from = vertices[vertex_index - 1];
                    const to = vertices[vertex_index];
                    const point_from = Point(f64){ .x = @intToFloat(f64, from.x) * scale, .y = height - (@intToFloat(f64, from.y) * scale) };
                    const point_to = Point(f64){ .x = @intToFloat(f64, to.x) * scale, .y = height - (@intToFloat(f64, to.y) * scale) };
                    var segment_ptr: *OutlineSegment = &outlines[outline_index].segments[outline_segment_index];
                    segment_ptr.* = OutlineSegment{
                        .from = point_from,
                        .to = point_to,
                        .t_per_pixel = undefined,
                        .control_opt = Point(f64){
                            .x = @intToFloat(f64, to.control1_x) * scale,
                            .y = height - (@intToFloat(f64, to.control1_y) * scale),
                        },
                    };
                    const outline_length_pixels: f64 = blk: {
                        //
                        // Approximate length of bezier curve
                        //
                        var i: usize = 1;
                        var accumulator: f64 = 0;
                        var point_previous = point_from;
                        while (i <= 10) : (i += 1) {
                            const point_sampled = segment_ptr.sample(@intToFloat(f64, i) * 0.1);
                            accumulator += geometry.distanceBetweenPoints(point_previous, point_sampled);
                        }
                        break :blk accumulator;
                    };
                    segment_ptr.t_per_pixel = (1.0 / outline_length_pixels);
                    vertex_index += 1;
                    outline_segment_index += 1;
                },
                // TODO:
                else => unreachable,
            }
        }
    }
    return outlines;
}
