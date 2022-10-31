// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const toNative = std.mem.toNative;
const bigToNative = std.mem.bigToNative;
const eql = std.mem.eql;
const assert = std.debug.assert;

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
