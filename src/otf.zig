// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const toNative = std.mem.toNative;
const bigToNative = std.mem.bigToNative;
const eql = std.mem.eql;
const assert = std.debug.assert;

const is_debug = if (builtin.mode == .Debug) true else false;

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const rasterizer = @import("rasterizer.zig");

const Outline = rasterizer.Outline;
const OutlineSegment = rasterizer.OutlineSegment;
const Point = geometry.Point;

const Adjustment = struct {
    x_placement: i16,
    y_placement: i16,
    x_advance: i16,
    y_advance: i16,
};

pub const KernPair = struct {
    left_codepoint: u8,
    right_codepoint: u8,
    advance_x: i16,
};

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
        var result = @as(*OffsetSubtable, @ptrCast(bytes)).*;

        result.scaler_type = toNative(u32, result.scaler_type, .big);
        result.tables_count = toNative(u16, result.tables_count, .big);
        result.search_range = toNative(u16, result.search_range, .big);
        result.entry_selector = toNative(u16, result.entry_selector, .big);
        result.range_shift = toNative(u16, result.range_shift, .big);

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

        var bytes = @as(*const u32, @ptrCast(&self));
        while (iteractions_count > 0) : (iteractions_count -= 1) {
            sum = @addWithOverflow(sum, bytes.*).a;
            bytes = @as(*const u32, @ptrFromInt(@intFromPtr(bytes) + @sizeOf(u32)));
        }
        const checksum = self.checksum;
        return (sum == checksum);
    }

    pub fn fromBigEndianBytes(bytes: *align(4) [@sizeOf(TableDirectory)]u8) ?TableDirectory {
        var result: TableDirectory = @as(*align(4) TableDirectory, @ptrCast(bytes)).*;

        // TODO: Disabled as not working
        // if (!result.isChecksumValid()) {
        // return null;
        // }

        result.length = toNative(u32, result.length, .big);
        result.offset = toNative(u32, result.offset, .big);

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

        const platform_id_u16 = toNative(u16, @as(*u16, @ptrCast(@alignCast(bytes.ptr))).*, .big);

        if (platform_id_u16 > @intFromEnum(CMAPPlatformID.microsoft)) {
            std.log.warn("Invalid platform ID '{d}' parsed from CMAP subtable", .{platform_id_u16});
            return null;
        }

        table.platform_id = @as(CMAPPlatformID, @enumFromInt(platform_id_u16));

        table.offset = toNative(u32, @as(*u32, @ptrCast(@alignCast(&bytes.ptr[4]))).*, .big);

        const platform_specific_id_u16 = toNative(u16, @as(*u16, @ptrCast(@alignCast(&bytes.ptr[2]))).*, .big);

        switch (table.platform_id) {
            .unicode => {
                if (platform_specific_id_u16 < @intFromEnum(CMAPPlatformSpecificID.Unicode.last_resort)) {
                    table.platform_specific_id = .{ .unicode = @as(CMAPPlatformSpecificID.Unicode, @enumFromInt(platform_specific_id_u16)) };
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

    pub inline fn set(self: *@This(), offset: u32, length: u32) void {
        self.* = .{
            .offset = offset,
            .length = length,
        };
        std.debug.assert(!self.isNull());
    }

    pub fn isNull(self: @This()) bool {
        return self.offset == 0;
    }
};

pub const DataSections = extern struct {
    cmap: SectionRange = .{},
    dsig: SectionRange = .{},
    glyf: SectionRange = .{},
    gpos: SectionRange = .{},
    head: SectionRange = .{},
    hhea: SectionRange = .{},
    hmtx: SectionRange = .{},
    kern: SectionRange = .{},
    loca: SectionRange = .{},
    maxp: SectionRange = .{},
    name: SectionRange = .{},
    os2: SectionRange = .{},
    svg: SectionRange = .{},
    vtmx: SectionRange = .{},
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
    //
    // Slices cannot be used in extern structs (Required for C compat)
    //
    data: [*]const u8,
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
    horizonal_metrics_count: u32 = 0,

    scale: f32 = 1.0,
    ascender: i16 = -1,
    descender: i16 = -1,
    line_gap: i16 = -1,
    break_char: u16 = 0,
    default_char: u16 = 0,
    units_per_em: u16 = 0,

    space_advance: f32 = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        const font_buffer = self.data[0..self.data_len];
        allocator.free(font_buffer);
    }
};

const VMetric = extern struct {
    advance_height: u16,
    topside_bearing: i16,
};

const HorizontalMetric = extern struct {
    advance_width: u16,
    leftside_bearing: i16,
};

fn coverageIndexForGlyphID(coverage: []const u8, target_glyph_id: u16) !?u16 {
    var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
        .buffer = coverage,
        .pos = 0,
    };
    var reader = fixed_buffer_stream.reader();
    const coverage_format = try reader.readInt(u16, .big);
    switch (coverage_format) {
        1 => {
            const glyph_count = try reader.readInt(u16, .big);
            var i: usize = 0;
            while (i < glyph_count) : (i += 1) {
                const glyph_id = try reader.readInt(u16, .big);
                if (glyph_id == target_glyph_id) {
                    return @as(u16, @intCast(i));
                }
            }
        },
        2 => {
            std.debug.assert(false);
            const range_count = try reader.readInt(u16, .big);
            var i: usize = 0;
            while (i < range_count) : (i += 1) {
                const glyph_start = try reader.readInt(u16, .big);
                const glyph_end = try reader.readInt(u16, .big);
                const base_coverage_index = try reader.readInt(u16, .big);
                if (target_glyph_id >= glyph_start and target_glyph_id <= glyph_end) {
                    return @as(u16, @intCast(base_coverage_index + (i - glyph_start)));
                }
            }
        },
        else => return null,
    }
    return null;
}

// https://learn.microsoft.com/en-us/typography/opentype/spec/gpos
const GPosLookupType = enum(u16) {
    single_adjustment = 1,
    pair_adjustment = 2,
    cursive_adjustment = 3,
    mark_to_base = 4,
    mark_to_ligature = 5,
    mark_to_mark = 6,
    context = 7,
    chained_context = 8,
    extension = 9,
    _,
};

const ValueRecord = extern struct {
    x_placement: i16,
    y_placement: i16,
    x_advance: i16,
    y_advance: i16,
    x_placement_device_offset: u16,
    y_placement_device_offset: u16,
    x_advance_device_offset: u16,
    y_advance_device_offset: u16,

    pub fn read(reader: anytype) !ValueRecord {
        var value_record: ValueRecord = undefined;
        value_record.x_placement = try reader.readInt(i16, .big);
        value_record.y_placement = try reader.readInt(i16, .big);
        value_record.x_advance = try reader.readInt(i16, .big);
        value_record.y_advance = try reader.readInt(i16, .big);
        value_record.x_placement_device_offset = try reader.readInt(u16, .big);
        value_record.y_placement_device_offset = try reader.readInt(u16, .big);
        value_record.x_advance_device_offset = try reader.readInt(u16, .big);
        value_record.y_advance_device_offset = try reader.readInt(u16, .big);
        return value_record;
    }
};

fn getClassForGlyph(class_table_data: []const u8, glyph_index: u32) !u16 {
    var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
        .buffer = class_table_data,
        .pos = 0,
    };
    var reader = fixed_buffer_stream.reader();

    const pos_format = try reader.readInt(u16);
    std.debug.assert(pos_format == 1 or pos_format == 2);
    switch (pos_format) {
        1 => {
            const start_glyph_id = try reader.readInt(u16, .big);
            const glyph_count = try reader.readInt(u16, .big);
            try reader.skipBytes(start_glyph_id * @sizeOf(u16), .{});
            var x: usize = 0;
            while (x < glyph_count) : (x += 1) {
                const current_glyph_index = try reader.readInt(u16, .big);
                if (current_glyph_index == glyph_index) {
                    return @as(u16, @intCast(x));
                }
            }
        },
        2 => {
            const class_range_count = try reader.readInt(u16, .big);
            var x: usize = 0;
            while (x < class_range_count) : (x += 1) {
                const start_glyph_id = try reader.readInt(u16, .big);
                const end_glyph_id = try reader.readInt(u16, .big);
                const class = try reader.readInt(u16, .big);
                if (glyph_index >= start_glyph_id and glyph_index <= end_glyph_id) {
                    return class;
                }
            }
        },
        else => unreachable,
    }
    return 0;
}

pub fn loadXAdvances(font: *const FontInfo, codepoints: []const u8, out_advance_list: []u16) void {
    std.debug.assert(!font.hmtx.isNull());
    const entries = @as([*]const HorizontalMetric, @ptrCast(@alignCast(&font.data[font.hmtx.offset])));
    comptime std.debug.assert(@sizeOf(HorizontalMetric) == 4);
    for (codepoints, 0..) |codepoint, codepoint_i| {
        const glyph_index = findGlyphIndex(font, codepoint);
        const index = @min(font.horizonal_metrics_count - 1, glyph_index);
        out_advance_list[codepoint_i] = std.mem.bigToNative(u16, entries[index].advance_width);
    }
}

pub fn leftBearingForGlyph(font: *const FontInfo, glyph_index: u32) i16 {
    std.debug.assert(!font.hmtx.isNull());
    const entries = @as([*]const HorizontalMetric, @ptrCast(@alignCast(&font.data[font.hmtx.offset])));
    const index = @min(font.horizonal_metrics_count - 1, glyph_index);
    return std.mem.bigToNative(i16, entries[index].leftside_bearing);
}

pub fn advanceXForGlyph(font: *const FontInfo, glyph_index: u32) u16 {
    std.debug.assert(!font.hmtx.isNull());
    const entries = @as([*]const HorizontalMetric, @ptrCast(@alignCast(&font.data[font.hmtx.offset])));
    const index = @min(font.horizonal_metrics_count - 1, glyph_index);
    return std.mem.bigToNative(u16, entries[index].advance_width);
}

pub fn kernAdvanceGpos(
    font: *const FontInfo,
    left_codepoint: u8,
    right_codepoint: u8,
) !?i16 {
    std.debug.assert(!font.gpos.isNull());
    var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
        .buffer = font.data[0..font.data_len],
        .pos = font.gpos.offset,
    };
    var reader = fixed_buffer_stream.reader();

    const version_major = try reader.readInt(i16, .big);
    const version_minor = try reader.readInt(i16, .big);
    const script_list_offset = (try reader.readInt(u16, .big)) + font.gpos.offset;
    const feature_list_offset = try reader.readInt(u16, .big);
    const lookup_list_offset = try reader.readInt(u16, .big);

    _ = feature_list_offset;

    std.debug.assert(version_major == 1 and (version_minor == 0 or version_minor == 1));

    if (version_minor == 1) {
        _ = try reader.readInt(u32, .big); // feature variation offset
    }

    try fixed_buffer_stream.seekTo(script_list_offset);
    const script_count = try reader.readInt(u16, .big);
    var previous_offset: usize = undefined;
    var selected_lang_offset: u16 = 0;

    var i: usize = 0;
    while (i < script_count) : (i += 1) {
        var tag: [4]u8 = undefined;
        _ = try reader.read(&tag);
        const offset = try reader.readInt(u16, .big);
        previous_offset = try fixed_buffer_stream.getPos();
        try fixed_buffer_stream.seekTo(script_list_offset + offset);

        const default_lang_offset = try reader.readInt(u16, .big);
        const lang_count = try reader.readInt(u16, .big);
        _ = lang_count;
        if (std.mem.eql(u8, "DFLT", &tag)) {
            selected_lang_offset = default_lang_offset + offset;
            break;
        }
        try fixed_buffer_stream.seekTo(previous_offset);
    }

    if (selected_lang_offset == 0) {
        return error.NoDefaultLang;
    }

    try fixed_buffer_stream.seekTo(script_list_offset + selected_lang_offset);
    const lookup_order_offset = try reader.readInt(u16, .big);
    const required_feature_index = try reader.readInt(u16, .big);
    const feature_index_count = try reader.readInt(u16, .big);

    _ = required_feature_index;
    _ = feature_index_count;
    _ = lookup_order_offset;

    //
    // Jump to Lookup List Table
    // https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#lookup-list-table
    //
    try fixed_buffer_stream.seekTo(font.gpos.offset + lookup_list_offset);
    const lookup_entry_count = try reader.readInt(u16, .big);

    i = 0;
    var lookup_table_offset: u32 = 0;
    const subtable_count: u16 = blk: {
        while (i < lookup_entry_count) : (i += 1) {
            const lookup_offset = try reader.readInt(u16, .big);
            lookup_table_offset = font.gpos.offset + lookup_list_offset + lookup_offset;
            const saved_offset = try fixed_buffer_stream.getPos();
            //
            // Jump to Lookup Table
            // https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#lookup-table
            //
            try fixed_buffer_stream.seekTo(lookup_table_offset);
            const lookup_type = try reader.readEnum(GPosLookupType, .big);
            _ = try reader.readInt(u16, .big); // lookup_flag
            const count = try reader.readInt(u16, .big);
            if (lookup_type == .pair_adjustment) {
                break :blk count;
            }
            try fixed_buffer_stream.seekTo(saved_offset);
        }
        return error.NoPairAdjustmentLookup;
    };
    var subtable_offset_absolute: u32 = 0;
    const subtable_start_offset = try fixed_buffer_stream.getPos();

    try fixed_buffer_stream.seekTo(subtable_start_offset);
    const left_glyph_index = findGlyphIndex(font, left_codepoint);
    i = 0;
    subtable_loop: while (i < subtable_count) : (i += 1) {
        const subtable_offset = try reader.readInt(u16, .big);
        subtable_offset_absolute = lookup_table_offset + subtable_offset;
        const saved_lookup_offset = try fixed_buffer_stream.getPos();
        try fixed_buffer_stream.seekTo(subtable_offset_absolute);
        const pos_format = try reader.readInt(u16, .big);
        const coverage_offset = try reader.readInt(u16, .big);
        const coverage_offset_absolute = coverage_offset + subtable_offset_absolute;
        const coverage_slice = font.data[coverage_offset_absolute..font.data_len];
        switch (pos_format) {
            1 => {
                if (try coverageIndexForGlyphID(coverage_slice, @as(u16, @intCast(left_glyph_index)))) |coverage_index| {
                    const value_format_1 = try reader.readInt(u16, .big);
                    const value_format_2 = try reader.readInt(u16, .big);
                    const pair_set_count = try reader.readInt(u16, .big);
                    _ = pair_set_count;

                    // TODO: Support more format types
                    if (!(value_format_1 == 4 and value_format_2 == 0)) return error.InvalidValueFormat;

                    // Jump to pairSetOffset[coverage_index]
                    try reader.skipBytes(coverage_index * @sizeOf(u16), .{});

                    const pair_set_offset = try reader.readInt(u16, .big);
                    try fixed_buffer_stream.seekTo(subtable_offset_absolute + pair_set_offset);

                    const pair_value_count = try reader.readInt(u16, .big);
                    const saved_pairlist_offset = try fixed_buffer_stream.getPos();

                    const right_glyph_index = findGlyphIndex(font, right_codepoint);
                    i = 0;
                    while (i < pair_value_count) : (i += 1) {
                        const right_glyph_id = try reader.readInt(u16, .big);
                        const advance_x = try reader.readInt(i16, .big);
                        if (right_glyph_id == right_glyph_index) {
                            return advance_x;
                        }
                    }
                    try fixed_buffer_stream.seekTo(saved_pairlist_offset);
                    break :subtable_loop;
                }
            },
            2 => {
                const value_format_1 = try reader.readInt(u16, .big);
                const value_format_2 = try reader.readInt(u16, .big);
                // TODO: Support more format types
                std.debug.assert(value_format_1 == 4);
                std.debug.assert(value_format_2 == 0);
                const classdef_offset_1 = try reader.readInt(u16, .big);
                const classdef_offset_2 = try reader.readInt(u16, .big);
                const class_count_1 = try reader.readInt(u16, .big);
                _ = class_count_1;
                const class_count_2 = try reader.readInt(u16, .big);
                const class_index_1 = try getClassForGlyph(font.data[subtable_offset_absolute + classdef_offset_1 .. font.data_len], left_glyph_index);
                const saved_offset = try fixed_buffer_stream.getPos();
                const right_glyph_index = findGlyphIndex(font, right_codepoint);
                const class_index_2 = try getClassForGlyph(font.data[subtable_offset_absolute + classdef_offset_2 .. font.data_len], right_glyph_index);
                try reader.skipBytes((class_index_2 + (class_index_1 * class_count_2)) * @sizeOf(u16), .{});
                const advance_x = try reader.readInt(i16, .big);
                if (advance_x != 0) {
                    return advance_x;
                }
                try fixed_buffer_stream.seekTo(saved_offset);
                break :subtable_loop;
            },
            else => return error.InvalidPairAdjustmentSubtableFormat,
        }
        try fixed_buffer_stream.seekTo(saved_lookup_offset);
    }

    return null;
}

pub fn generateKernPairsFromGpos(
    allocator: std.mem.Allocator,
    font: *const FontInfo,
    codepoints: []const u8,
) ![]KernPair {
    if (font.gpos.isNull()) return &[0]KernPair{};

    var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
        .buffer = font.data[0..font.data_len],
        .pos = font.gpos.offset,
    };
    var reader = fixed_buffer_stream.reader();

    const version_major = try reader.readInt(i16, .big);
    const version_minor = try reader.readInt(i16, .big);
    const script_list_offset = (try reader.readInt(u16, .big)) + font.gpos.offset;
    const feature_list_offset = try reader.readInt(u16, .big);
    const lookup_list_offset = try reader.readInt(u16, .big);

    _ = feature_list_offset;

    std.debug.assert(version_major == 1 and (version_minor == 0 or version_minor == 1));

    if (version_minor == 1) {
        _ = try reader.readInt(u32, .big); // feature variation offset
    }

    try fixed_buffer_stream.seekTo(script_list_offset);
    const script_count = try reader.readInt(u16, .big);
    var previous_offset: usize = undefined;
    var selected_lang_offset: u16 = 0;

    var i: usize = 0;
    while (i < script_count) : (i += 1) {
        var tag: [4]u8 = undefined;
        _ = try reader.read(&tag);
        const offset = try reader.readInt(u16, .big);
        previous_offset = try fixed_buffer_stream.getPos();
        try fixed_buffer_stream.seekTo(script_list_offset + offset);

        const default_lang_offset = try reader.readInt(u16, .big);
        const lang_count = try reader.readInt(u16, .big);
        _ = lang_count;
        if (std.mem.eql(u8, "DFLT", &tag)) {
            selected_lang_offset = default_lang_offset + offset;
            break;
        }
        try fixed_buffer_stream.seekTo(previous_offset);
    }

    if (selected_lang_offset == 0) {
        return error.NoDefaultLang;
    }

    try fixed_buffer_stream.seekTo(script_list_offset + selected_lang_offset);
    const lookup_order_offset = try reader.readInt(u16, .big);
    const required_feature_index = try reader.readInt(u16, .big);
    const feature_index_count = try reader.readInt(u16, .big);

    _ = required_feature_index;
    _ = feature_index_count;
    _ = lookup_order_offset;

    //
    // Jump to Lookup List Table
    // https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#lookup-list-table
    //
    try fixed_buffer_stream.seekTo(font.gpos.offset + lookup_list_offset);
    const lookup_entry_count = try reader.readInt(u16, .big);

    i = 0;
    var lookup_table_offset: u32 = 0;
    const subtable_count: u16 = blk: {
        while (i < lookup_entry_count) : (i += 1) {
            const lookup_offset = try reader.readInt(u16, .big);
            lookup_table_offset = font.gpos.offset + lookup_list_offset + lookup_offset;
            const saved_offset = try fixed_buffer_stream.getPos();
            //
            // Jump to Lookup Table
            // https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#lookup-table
            //
            try fixed_buffer_stream.seekTo(lookup_table_offset);
            const lookup_type = try reader.readEnum(GPosLookupType, .big);
            _ = try reader.readInt(u16, .big); // lookup_flag
            const count = try reader.readInt(u16, .big);
            if (lookup_type == .pair_adjustment) {
                break :blk count;
            }
            try fixed_buffer_stream.seekTo(saved_offset);
        }
        return error.NoPairAdjustmentLookup;
    };
    var subtable_offset_absolute: u32 = 0;
    const subtable_start_offset = try fixed_buffer_stream.getPos();

    //
    // Allocate maximum possible value + shrink later
    //
    var kern_pairs = try allocator.alloc(KernPair, std.math.pow(usize, codepoints.len, 2));
    errdefer allocator.free(kern_pairs);

    var kern_count: usize = 0;
    for (codepoints) |left_codepoint| {
        try fixed_buffer_stream.seekTo(subtable_start_offset);
        const left_glyph_index = findGlyphIndex(font, left_codepoint);
        i = 0;
        subtable_loop: while (i < subtable_count) : (i += 1) {
            const subtable_offset = try reader.readInt(u16, .big);
            subtable_offset_absolute = lookup_table_offset + subtable_offset;
            const saved_lookup_offset = try fixed_buffer_stream.getPos();
            try fixed_buffer_stream.seekTo(subtable_offset_absolute);
            const pos_format = try reader.readInt(u16, .big);
            const coverage_offset = try reader.readInt(u16, .big);
            const coverage_offset_absolute = coverage_offset + subtable_offset_absolute;
            const coverage_slice = font.data[coverage_offset_absolute..font.data_len];
            switch (pos_format) {
                1 => {
                    if (try coverageIndexForGlyphID(coverage_slice, @as(u16, @intCast(left_glyph_index)))) |coverage_index| {
                        const value_format_1 = try reader.readInt(u16, .big);
                        const value_format_2 = try reader.readInt(u16, .big);
                        const pair_set_count = try reader.readInt(u16, .big);
                        _ = pair_set_count;

                        // TODO: Support more format types
                        if (!(value_format_1 == 4 and value_format_2 == 0)) return error.InvalidValueFormat;

                        // Jump to pairSetOffset[coverage_index]
                        try reader.skipBytes(coverage_index * @sizeOf(u16), .{});

                        const pair_set_offset = try reader.readInt(u16, .big);
                        try fixed_buffer_stream.seekTo(subtable_offset_absolute + pair_set_offset);

                        const pair_value_count = try reader.readInt(u16, .big);
                        const saved_pairlist_offset = try fixed_buffer_stream.getPos();

                        second_glyph_loop: for (codepoints) |right_codepoint| {
                            const right_glyph_index = findGlyphIndex(font, right_codepoint);
                            i = 0;
                            while (i < pair_value_count) : (i += 1) {
                                const right_glyph_id = try reader.readInt(u16, .big);
                                const advance_x = try reader.readInt(i16, .big);
                                if (right_glyph_id == right_glyph_index) {
                                    kern_pairs[kern_count] = .{
                                        .left_codepoint = left_codepoint,
                                        .right_codepoint = right_codepoint,
                                        .advance_x = advance_x,
                                    };
                                    kern_count += 1;
                                    try fixed_buffer_stream.seekTo(saved_pairlist_offset);
                                    continue :second_glyph_loop;
                                }
                            }
                            try fixed_buffer_stream.seekTo(saved_pairlist_offset);
                        }
                        break :subtable_loop;
                    }
                },
                2 => {
                    const value_format_1 = try reader.readInt(u16, .big);
                    const value_format_2 = try reader.readInt(u16, .big);
                    // TODO: Support more format types
                    std.debug.assert(value_format_1 == 4);
                    std.debug.assert(value_format_2 == 0);
                    const classdef_offset_1 = try reader.readInt(u16, .big);
                    const classdef_offset_2 = try reader.readInt(u16, .big);
                    const class_count_1 = try reader.readInt(u16, .big);
                    _ = class_count_1;
                    const class_count_2 = try reader.readInt(u16, .big);
                    const class_index_1 = try getClassForGlyph(font.data[subtable_offset_absolute + classdef_offset_1 .. font.data_len], left_glyph_index);
                    const saved_offset = try fixed_buffer_stream.getPos();
                    for (codepoints) |right_codepoint| {
                        const right_glyph_index = findGlyphIndex(font, right_codepoint);
                        const class_index_2 = try getClassForGlyph(font.data[subtable_offset_absolute + classdef_offset_2 .. font.data_len], right_glyph_index);
                        try reader.skipBytes((class_index_2 + (class_index_1 * class_count_2)) * @sizeOf(u16), .{});
                        const advance_x = try reader.readInt(i16, .big);
                        if (advance_x != 0) {
                            kern_pairs[kern_count] = .{
                                .left_codepoint = left_codepoint,
                                .right_codepoint = right_codepoint,
                                .advance_x = advance_x,
                            };
                            kern_count += 1;
                        }
                        try fixed_buffer_stream.seekTo(saved_offset);
                    }
                    break :subtable_loop;
                },
                else => return error.InvalidPairAdjustmentSubtableFormat,
            }
            try fixed_buffer_stream.seekTo(saved_lookup_offset);
        }
    }

    if (!allocator.resize(kern_pairs, kern_count)) {
        std.log.warn("Failed to shrink KernPair array", .{});
    }

    return kern_pairs[0..kern_count];
}

pub fn loadFromFile(allocator: std.mem.Allocator, file_path: []const u8) !FontInfo {
    const file_handle = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file_handle.close();

    const file_size = (try file_handle.stat()).size;

    const font_buffer = try allocator.alloc(u8, file_size);
    _ = try file_handle.readAll(font_buffer);

    return try parseFromBytes(font_buffer);
}

pub fn parseFromBytes(font_data: []const u8) !FontInfo {
    var data_sections = DataSections{};
    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = 0 };
        var reader = fixed_buffer_stream.reader();

        const scaler_type = try reader.readInt(u32, .big);
        const tables_count = try reader.readInt(u16, .big);
        const search_range = try reader.readInt(u16, .big);
        const entry_selector = try reader.readInt(u16, .big);
        const range_shift = try reader.readInt(u16, .big);

        _ = scaler_type;
        _ = search_range;
        _ = entry_selector;
        _ = range_shift;

        if (is_debug) {
            std.debug.print("TTF / OTF Tables:\n", .{});
        }
        var i: usize = 0;
        while (i < tables_count) : (i += 1) {
            var tag_buffer: [4]u8 = undefined;
            var tag = tag_buffer[0..];
            _ = try reader.readAll(tag[0..]);
            const checksum = try reader.readInt(u32, .big);
            // TODO: Use checksum
            _ = checksum;
            const offset = try reader.readInt(u32, .big);
            const length = try reader.readInt(u32, .big);

            if (is_debug) {
                std.debug.print("  {s}\n", .{tag});
            }

            if (std.mem.eql(u8, "cmap", tag)) {
                data_sections.cmap.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "DSIG", tag)) {
                data_sections.dsig.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "loca", tag)) {
                data_sections.loca.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "head", tag)) {
                data_sections.head.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "glyf", tag)) {
                data_sections.glyf.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "hhea", tag)) {
                data_sections.hhea.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "hmtx", tag)) {
                data_sections.hmtx.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "kern", tag)) {
                data_sections.kern.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "GPOS", tag)) {
                data_sections.gpos.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "maxp", tag)) {
                data_sections.maxp.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "name", tag)) {
                data_sections.name.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "OS/2", tag)) {
                data_sections.os2.set(offset, length);
                continue;
            }

            if (std.mem.eql(u8, "vtmx", tag)) {
                data_sections.vtmx.set(offset, length);
                continue;
            }
        }
    }

    if (data_sections.os2.isNull()) {
        std.log.err("Required data section `OS/2` not found", .{});
        return error.RequiredSectionHeadMissing;
    }

    if (!data_sections.glyf.isNull()) {
        if (data_sections.loca.isNull()) {
            std.log.err("Required data section `loca` not found", .{});
            return error.RequiredSectionHeadMissing;
        }
    }

    if (data_sections.hmtx.isNull()) {
        std.log.err("Required data section `hmtx` not found", .{});
        return error.RequiredSectionHeadMissing;
    }

    var font_info = FontInfo{
        .data = font_data.ptr,
        .data_len = @as(u32, @intCast(font_data.len)),
        .hhea = data_sections.hhea,
        .hmtx = data_sections.hmtx,
        .loca = data_sections.loca,
        .glyf = data_sections.glyf,
        .gpos = data_sections.gpos,
        .ascender = undefined,
        .descender = undefined,
        .line_gap = undefined,
        .break_char = undefined,
        .default_char = undefined,
        .space_advance = undefined,
    };

    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
            .buffer = font_data,
            .pos = data_sections.os2.offset,
        };
        var reader = fixed_buffer_stream.reader();

        const version = try reader.readInt(u16, .big);
        _ = version;
        try reader.skipBytes(66, .{});

        font_info.ascender = try reader.readInt(i16, .big);
        font_info.descender = try reader.readInt(i16, .big);
        font_info.line_gap = try reader.readInt(i16, .big);

        try reader.skipBytes(16, .{});

        font_info.default_char = try reader.readInt(u16, .big);
        font_info.break_char = try reader.readInt(u16, .big);
    }

    {
        std.debug.assert(!data_sections.maxp.isNull());

        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = data_sections.maxp.offset };
        var reader = fixed_buffer_stream.reader();
        const version_major = try reader.readInt(i16, .big);
        const version_minor = try reader.readInt(i16, .big);
        _ = version_major;
        _ = version_minor;
        font_info.glyph_count = try reader.readInt(u16, .big);
    }

    var head: Head = undefined;
    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = font_data, .pos = data_sections.head.offset };
        var reader = fixed_buffer_stream.reader();

        head.version_major = try reader.readInt(i16, .big);
        head.version_minor = try reader.readInt(i16, .big);
        head.font_revision_major = try reader.readInt(i16, .big);
        head.font_revision_minor = try reader.readInt(i16, .big);
        head.checksum_adjustment = try reader.readInt(u32, .big);
        head.magic_number = try reader.readInt(u32, .big);

        if (head.magic_number != 0x5F0F3CF5) {
            std.log.warn("Magic number not set to 0x5F0F3CF5. File might be corrupt", .{});
        }

        head.flags = try reader.readStruct(Head.Flags);

        font_info.units_per_em = try reader.readInt(u16, .big);
        head.created_timestamp = try reader.readInt(i64, .big);
        head.modified_timestamp = try reader.readInt(i64, .big);

        head.x_min = try reader.readInt(i16, .big);
        head.y_min = try reader.readInt(i16, .big);
        head.x_max = try reader.readInt(i16, .big);
        head.y_max = try reader.readInt(i16, .big);

        std.debug.assert(head.x_min <= head.x_max);
        std.debug.assert(head.y_min <= head.y_max);

        head.mac_style = try reader.readStruct(Head.MacStyle);

        head.lowest_rec_ppem = try reader.readInt(u16, .big);

        head.font_direction_hint = try reader.readInt(i16, .big);
        head.index_to_loc_format = try reader.readInt(i16, .big);
        head.glyph_data_format = try reader.readInt(i16, .big);

        font_info.index_to_loc_format = head.index_to_loc_format;

        std.debug.assert(font_info.index_to_loc_format == 0 or font_info.index_to_loc_format == 1);
    }

    font_info.cmap_encoding_table_offset = outer: {
        std.debug.assert(!data_sections.cmap.isNull());

        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
            .buffer = font_data,
            .pos = data_sections.cmap.offset,
        };
        var reader = fixed_buffer_stream.reader();

        const version = try reader.readInt(u16, .big);
        const subtable_count = try reader.readInt(u16, .big);

        _ = version;

        var i: usize = 0;
        while (i < subtable_count) : (i += 1) {
            comptime {
                std.debug.assert(@sizeOf(CMAPPlatformID) == 2);
                std.debug.assert(@sizeOf(CMAPPlatformSpecificID) == 2);
            }
            const platform_id = try reader.readEnum(CMAPPlatformID, .big);
            const platform_specific_id = blk: {
                switch (platform_id) {
                    .unicode => break :blk CMAPPlatformSpecificID{ .unicode = try reader.readEnum(CMAPPlatformSpecificID.Unicode, .big) },
                    else => return error.InvalidSpecificPlatformID,
                }
            };
            _ = platform_specific_id;
            const offset = try reader.readInt(u32, .big);
            std.log.info("Platform: {}", .{platform_id});
            if (platform_id == .unicode) break :outer data_sections.cmap.offset + offset;
        }
        return error.InvalidPlatform;
    };

    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
            .buffer = font_data,
            .pos = data_sections.hhea.offset,
        };
        var reader = fixed_buffer_stream.reader();

        try reader.skipBytes(17 * @sizeOf(u16), .{});
        font_info.horizonal_metrics_count = try reader.readInt(u16, .big);
        std.debug.assert(font_info.horizonal_metrics_count > 0);
    }

    {
        var fixed_buffer_stream = std.io.FixedBufferStream([]const u8){
            .buffer = font_data,
            .pos = data_sections.hmtx.offset,
        };
        var reader = fixed_buffer_stream.reader();
        const space_glyph_index = findGlyphIndex(&font_info, ' ');
        if (space_glyph_index < font_info.horizonal_metrics_count) {
            try reader.skipBytes(space_glyph_index * @sizeOf(u32), .{});
            font_info.space_advance = @as(f32, @floatFromInt(try reader.readInt(u16, .big)));
        } else {
            try reader.skipBytes((font_info.horizonal_metrics_count - 1) * @sizeOf(u32), .{});
            font_info.space_advance = @as(f32, @floatFromInt(try reader.readInt(u16, .big)));
        }
    }

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

pub fn findGlyphIndex(font_info: *const FontInfo, unicode_codepoint: i32) u32 {
    const data = font_info.data[0..font_info.data_len];
    const encoding_offset = font_info.cmap_encoding_table_offset;

    if (unicode_codepoint > 0xffff) {
        std.log.err("Invalid codepoint", .{});
        std.debug.assert(false);
    }

    const base_index: usize = @intFromPtr(data.ptr) + encoding_offset;
    const format: u16 = bigToNative(u16, @as(*u16, @ptrFromInt(base_index)).*);

    // TODO:
    std.debug.assert(format == 4);

    const segcount = toNative(u16, @as(*u16, @ptrFromInt(base_index + 6)).*, .big) >> 1;
    var search_range = toNative(u16, @as(*u16, @ptrFromInt(base_index + 8)).*, .big) >> 1;
    var entry_selector = toNative(u16, @as(*u16, @ptrFromInt(base_index + 10)).*, .big);
    const range_shift = toNative(u16, @as(*u16, @ptrFromInt(base_index + 12)).*, .big) >> 1;

    const end_count: u32 = encoding_offset + 14;
    var search: u32 = end_count;

    if (unicode_codepoint >= toNative(u16, @as(*u16, @ptrFromInt(@intFromPtr(data.ptr) + search + (range_shift * 2))).*, .big)) {
        search += range_shift * 2;
    }

    search -= 2;

    while (entry_selector != 0) {
        var end: u16 = undefined;
        search_range = search_range >> 1;

        end = toNative(u16, @as(*u16, @ptrFromInt(@intFromPtr(data.ptr) + search + (search_range * 2))).*, .big);

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

        assert(unicode_codepoint <= toNative(u16, @as(*u16, @ptrFromInt(@intFromPtr(data.ptr) + end_count + (item * 2))).*, .big));
        start = toNative(u16, @as(*u16, @ptrFromInt(@intFromPtr(data.ptr) + encoding_offset + 14 + (segcount * 2) + 2 + (2 * item))).*, .big);

        if (unicode_codepoint < start) {
            // TODO: return error
            std.debug.assert(false);
            return 0;
        }

        offset = toNative(u16, @as(*u16, @ptrFromInt(@intFromPtr(data.ptr) + encoding_offset + 14 + (segcount * 6) + 2 + (item * 2))).*, .big);
        if (offset == 0) {
            const base = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 14 + (segcount * 4) + 2 + (2 * item))).*);
            return @as(u32, @intCast(unicode_codepoint + base));
        }

        const result_addr_index = @intFromPtr(data.ptr) + offset + @as(usize, @intCast(unicode_codepoint - start)) * 2 + encoding_offset + 14 + (segcount * 6) + 2 + (2 * item);

        const result_addr = @as(*u8, @ptrFromInt(result_addr_index));
        const result_addr_aligned = @as(*u16, @ptrCast(@alignCast(result_addr)));

        return @as(u32, @intCast(toNative(u16, result_addr_aligned.*, .big)));
    }
}

inline fn readBigEndian(comptime T: type, index: usize) T {
    return bigToNative(T, @as(*T, @ptrFromInt(index)).*);
}

pub fn getAscent(font: *const FontInfo) i16 {
    const offset = font.hhea.offset + TableHHEA.index.ascender;
    return readBigEndian(i16, @intFromPtr(font.data.ptr) + offset);
}

pub fn getDescent(font: *const FontInfo) i16 {
    const offset = font.hhea.offset + TableHHEA.index.descender;
    return readBigEndian(i16, @intFromPtr(font.data.ptr) + offset);
}

fn parseGlyfTableIndexForGlyph(font: *const FontInfo, glyph_index: u32) !usize {
    if (glyph_index >= font.glyph_count) return error.InvalidGlyphIndex;

    const font_data_start_index = @intFromPtr(&font.data[0]);
    if (font.index_to_loc_format != 0 and font.index_to_loc_format != 1) return error.InvalidIndexToLocationFormat;
    const loca_start = font_data_start_index + font.loca.offset;
    const glyf_offset = @as(usize, @intCast(font.glyf.offset));

    var glyph_data_offset: usize = 0;
    var next_glyph_data_offset: usize = 0;

    // Use 16 or 32 bit offsets based on index_to_loc_format
    // https://docs.microsoft.com/en-us/typography/opentype/spec/head
    if (font.index_to_loc_format == 0) {
        // Location values are stored as half the actual value.
        // https://docs.microsoft.com/en-us/typography/opentype/spec/loca#short-version
        const loca_table_offset: usize = loca_start + (@as(usize, @intCast(glyph_index)) * 2);
        glyph_data_offset = glyf_offset + @as(u32, @intCast(readBigEndian(u16, loca_table_offset + 0))) * 2;
        next_glyph_data_offset = glyf_offset + @as(u32, @intCast(readBigEndian(u16, loca_table_offset + 2))) * 2;
    } else {
        glyph_data_offset = glyf_offset + readBigEndian(u32, loca_start + (@as(usize, @intCast(glyph_index)) * 4) + 0);
        next_glyph_data_offset = glyf_offset + readBigEndian(u32, loca_start + (@as(usize, @intCast(glyph_index)) * 4) + 4);
    }

    if (glyph_data_offset == next_glyph_data_offset) {
        // https://docs.microsoft.com/en-us/typography/opentype/spec/loca
        // If loca[n] == loca[n + 1], that means the glyph has no outline (E.g space character)
        return error.GlyphHasNoOutline;
    }

    return glyph_data_offset;
}

pub fn boundingBoxForCodepoint(font: *const FontInfo, codepoint: i32) !geometry.BoundingBox(i32) {
    const glyph_index = findGlyphIndex(font, codepoint);
    const section_index: usize = try parseGlyfTableIndexForGlyph(font, glyph_index);
    const font_data_start_index = @intFromPtr(&font.data[0]);
    const base_index: usize = font_data_start_index + section_index;
    return geometry.BoundingBox(i32){
        .x0 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 2)).*), // min_x
        .y0 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 4)).*), // min_y
        .x1 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 6)).*), // max_x
        .y1 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 8)).*), // max_y
    };
}

pub fn calculateGlyphBoundingBox(font: *const FontInfo, glyph_index: u32) !geometry.BoundingBox(i32) {
    const section_index: usize = try parseGlyfTableIndexForGlyph(font, glyph_index);
    const font_data_start_index = @intFromPtr(&font.data[0]);
    const base_index: usize = font_data_start_index + section_index;
    return geometry.BoundingBox(i32){
        .x0 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 2)).*), // min_x
        .y0 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 4)).*), // min_y
        .x1 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 6)).*), // max_x
        .y1 = bigToNative(i16, @as(*i16, @ptrFromInt(base_index + 8)).*), // max_y
    };
}

pub fn calculateGlyphBoundingBoxScaled(font: *const FontInfo, glyph_index: u32, scale: f64) !geometry.BoundingBox(f64) {
    const unscaled = try calculateGlyphBoundingBox(font, glyph_index);
    return geometry.BoundingBox(f64){
        .x0 = @as(f64, @floatFromInt(unscaled.x0)) * scale,
        .y0 = @as(f64, @floatFromInt(unscaled.y0)) * scale,
        .x1 = @as(f64, @floatFromInt(unscaled.x1)) * scale,
        .y1 = @as(f64, @floatFromInt(unscaled.y1)) * scale,
    };
}

pub fn rasterizeGlyph(
    allocator: std.mem.Allocator,
    pixel_writer: anytype,
    font: *const FontInfo,
    scale: f32,
    codepoint: i32,
) !void {
    const glyph_index = findGlyphIndex(font, codepoint);
    const vertices: []Vertex = try loadGlyphVertices(allocator, font, glyph_index);
    defer allocator.free(vertices);

    const bounding_box = try calculateGlyphBoundingBox(font, glyph_index);
    const bounding_box_scaled = geometry.BoundingBox(i32){
        .x0 = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(bounding_box.x0)) * scale))),
        .y0 = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(bounding_box.y0)) * scale))),
        .x1 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(bounding_box.x1)) * scale))),
        .y1 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(bounding_box.y1)) * scale))),
    };

    std.debug.assert(bounding_box.y1 >= bounding_box.y0);
    for (vertices) |*vertex| {
        vertex.x -= @as(i16, @intCast(bounding_box.x0));
        vertex.y -= @as(i16, @intCast(bounding_box.y0));
        if (@as(VMove, @enumFromInt(vertex.kind)) == .curve) {
            vertex.control1_x -= @as(i16, @intCast(bounding_box.x0));
            vertex.control1_y -= @as(i16, @intCast(bounding_box.y0));
        }
    }
    const dimensions = geometry.Dimensions2D(u32){
        .width = @as(u32, @intCast(bounding_box_scaled.x1 - bounding_box_scaled.x0)),
        .height = @as(u32, @intCast(bounding_box_scaled.y1 - bounding_box_scaled.y0)),
    };

    const outlines = try createOutlines(allocator, vertices, @as(f64, @floatFromInt(dimensions.height)), scale);
    defer {
        for (outlines) |*outline| {
            allocator.free(outline.segments);
        }
        allocator.free(outlines);
    }

    try rasterizer.rasterize(graphics.RGBA(f32), dimensions, outlines, pixel_writer);
}

pub fn rasterizeGlyphAlloc(
    allocator: std.mem.Allocator,
    font: *const FontInfo,
    scale: f32,
    codepoint: i32,
) !Bitmap {
    const glyph_index = findGlyphIndex(font, codepoint);
    const vertices: []Vertex = try loadGlyphVertices(allocator, font, glyph_index);
    defer allocator.free(vertices);

    const bounding_box = try calculateGlyphBoundingBox(font, glyph_index);
    const bounding_box_scaled = geometry.BoundingBox(i32){
        .x0 = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(bounding_box.x0)) * scale))),
        .y0 = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(bounding_box.y0)) * scale))),
        .x1 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(bounding_box.x1)) * scale))),
        .y1 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(bounding_box.y1)) * scale))),
    };

    std.debug.assert(bounding_box.y1 >= bounding_box.y0);
    for (vertices) |*vertex| {
        vertex.x -= @as(i16, @intCast(bounding_box.x0));
        vertex.y -= @as(i16, @intCast(bounding_box.y0));
        if (@as(VMove, @enumFromInt(vertex.kind)) == .curve) {
            vertex.control1_x -= @as(i16, @intCast(bounding_box.x0));
            vertex.control1_y -= @as(i16, @intCast(bounding_box.y0));
        }
    }
    const dimensions = geometry.Dimensions2D(u32){
        .width = @as(u32, @intCast(bounding_box_scaled.x1 - bounding_box_scaled.x0)),
        .height = @as(u32, @intCast(bounding_box_scaled.y1 - bounding_box_scaled.y0)),
    };

    const outlines = try createOutlines(allocator, vertices, @as(f64, @floatFromInt(dimensions.height)), scale);
    defer {
        for (outlines) |*outline| {
            allocator.free(outline.segments);
        }
        allocator.free(outlines);
    }

    var bitmap = Bitmap{
        .width = dimensions.width,
        .height = dimensions.height,
        .pixels = undefined,
    };
    const pixel_count = @as(usize, @intCast(dimensions.width)) * dimensions.height;
    const pixels = try allocator.alloc(graphics.RGBA(f32), pixel_count);
    bitmap.pixels = pixels.ptr;
    @memset(pixels, graphics.RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });
    const pixel_writer = rasterizer.SubTexturePixelWriter(graphics.RGBA(f32)){
        .texture_width = dimensions.width,
        .write_extent = .{
            .x = 0,
            .y = 0,
            .width = dimensions.width,
            .height = dimensions.height,
        },
        .pixels = bitmap.pixels,
    };
    try rasterizer.rasterize(graphics.RGBA(f32), dimensions, outlines, pixel_writer);
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
    vertex.kind = @intFromEnum(kind);
    vertex.x = @as(i16, @intCast(x));
    vertex.y = @as(i16, @intCast(y));
    vertex.control1_x = @as(i16, @intCast(control1_x));
    vertex.control1_y = @as(i16, @intCast(control1_y));
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

pub inline fn pixelPerEmScale(point_size: f64, ppi: f64) f64 {
    return point_size * ppi / 72;
}

pub inline fn fUnitToPixelScale(point_size: f64, ppi: f64, units_per_em: u16) f64 {
    return (point_size * ppi) / (72 * @as(f32, @floatFromInt(units_per_em)));
}

/// Calculates the required scale value to generate glyphs with a max height of
/// desired_height. This uses the bounding box of the entire font, not a specific
/// glyph. Therefore indiviual rendered glyphs are likely to be under this value,
/// but never above.
pub fn scaleForPixelHeight(font: *const FontInfo, desired_height: f32) f32 {
    const font_data_start_index = @intFromPtr(&font.data[0]);
    const base_index: usize = font_data_start_index + font.hhea.offset;
    const ascender = bigToNative(i16, @as(*i16, @ptrFromInt((base_index + 4))).*);
    const descender = bigToNative(i16, @as(*i16, @ptrFromInt((base_index + 6))).*);
    const unscaled_height = @as(f32, @floatFromInt(ascender + (-descender)));
    return desired_height / unscaled_height;
}

pub fn getRequiredDimensions(font: *const FontInfo, codepoint: i32, scale: f64) !geometry.Dimensions2D(u32) {
    const glyph_index = findGlyphIndex(font, codepoint);
    const bounding_box = try calculateGlyphBoundingBoxScaled(font, glyph_index, scale);
    std.debug.assert(bounding_box.x1 >= bounding_box.x0);
    std.debug.assert(bounding_box.y1 >= bounding_box.y0);
    return geometry.Dimensions2D(u32){
        .width = @as(u32, @intFromFloat(@ceil(bounding_box.x1) - @floor(bounding_box.x0))),
        .height = @as(u32, @intFromFloat(@ceil(bounding_box.y1) - @floor(bounding_box.y0))),
    };
}

fn loadGlyphVertices(allocator: std.mem.Allocator, font: *const FontInfo, glyph_index: u32) ![]Vertex {
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
    const font_data_start_index = @intFromPtr(&data[0]);
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

    glyph_dimensions.width = @as(u32, @intCast(max_x - min_x + 1));
    glyph_dimensions.height = @as(u32, @intCast(max_y - min_y + 1));

    if (contour_count_signed > 0) {
        const contour_count: u32 = @as(u16, @intCast(contour_count_signed));

        var j: i32 = 0;
        var m: u32 = 0;
        var n: u16 = 0;

        // Index of the next point that begins a new contour
        // This will correspond to value after end_points_of_contours
        var next_move: i32 = 0;

        var off: usize = 0;

        // end_points_of_contours is located directly after GlyphHeader in the glyf table
        const end_points_of_contours = @as([*]u16, @ptrFromInt(glyph_offset_index + @sizeOf(GlyhHeader)));
        const end_points_of_contours_size = @as(usize, @intCast(contour_count * @sizeOf(u16)));

        const simple_glyph_table_index = glyph_offset_index + @sizeOf(GlyhHeader);

        // Get the size of the instructions so we can skip past them
        const instructions_size_bytes = readBigEndian(i16, simple_glyph_table_index + end_points_of_contours_size);

        var glyph_flags: [*]u8 = @as([*]u8, @ptrFromInt(glyph_offset_index + @sizeOf(GlyhHeader) + (@as(usize, @intCast(contour_count)) * 2) + 2 + @as(usize, @intCast(instructions_size_bytes))));

        // NOTE: The number of flags is determined by the last entry in the endPtsOfContours array
        n = 1 + readBigEndian(u16, @intFromPtr(end_points_of_contours) + (@as(usize, @intCast(contour_count - 1)) * 2));

        // What is m here?
        // Size of contours
        {
            // Allocate space for all the flags, and vertices
            m = n + (2 * contour_count);
            vertices = try allocator.alloc(Vertex, @as(usize, @intCast(m)) * @sizeOf(Vertex));

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
                vertices[@as(usize, @intCast(off)) + @as(usize, @intCast(i))].kind = flags;
                flags_len += 1;
            }
        }

        {
            var x: i16 = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                flags = vertices[@as(usize, @intCast(off)) + @as(usize, @intCast(i))].kind;
                if (isFlagSet(flags, GlyphFlags.x_short_vector)) {
                    const dx: i16 = glyph_flags[0];
                    glyph_flags += 1;
                    x += if (isFlagSet(flags, GlyphFlags.positive_x_short_vector)) dx else -dx;
                } else {
                    if (!isFlagSet(flags, GlyphFlags.same_x)) {

                        // The current x-coordinate is a signed 16-bit delta vector
                        const abs_x = (@as(i16, @intCast(glyph_flags[0])) << 8) + glyph_flags[1];

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
                        const abs_y = (@as(i16, @intCast(glyph_flags[0])) << 8) + glyph_flags[1];
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
        const x: i16 = 0;
        const y: i16 = 0;

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
                next_move = 1 + readBigEndian(i16, @intFromPtr(end_points_of_contours) + (@as(usize, @intCast(j)) * 2));
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

    const resize_sucessful = allocator.resize(vertices, vertices_count);
    std.debug.assert(resize_sucessful);

    return vertices[0..vertices_count];
}

/// Converts array of Vertex into array of Outline (Our own format)
/// Applies Y flip and scaling
fn createOutlines(allocator: std.mem.Allocator, vertices: []Vertex, height: f64, scale: f32) ![]Outline {
    // TODO:
    std.debug.assert(@as(VMove, @enumFromInt(vertices[0].kind)) == .move);

    var outline_segment_lengths = [1]u32{0} ** 32;
    const outline_count: u32 = blk: {
        var count: u32 = 0;
        for (vertices[1..]) |vertex| {
            if (@as(VMove, @enumFromInt(vertex.kind)) == .move) {
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
            switch (@as(VMove, @enumFromInt(vertices[vertex_index].kind))) {
                .move => {
                    vertex_index += 1;
                    outline_index += 1;
                    outline_segment_index = 0;
                },
                .line => {
                    const from = vertices[vertex_index - 1];
                    const to = vertices[vertex_index];
                    const point_from = Point(f64){ .x = @as(f64, @floatFromInt(from.x)) * scale, .y = height - (@as(f64, @floatFromInt(from.y)) * scale) };
                    const point_to = Point(f64){ .x = @as(f64, @floatFromInt(to.x)) * scale, .y = height - (@as(f64, @floatFromInt(to.y)) * scale) };
                    const dist = geometry.distanceBetweenPoints(point_from, point_to);
                    const t_per_pixel: f64 = 1.0 / dist;
                    outlines[outline_index].segments[outline_segment_index] = OutlineSegment{
                        .from = point_from,
                        .to = point_to,
                        .t_per_pixel = if (t_per_pixel <= 1.0) t_per_pixel else 1.0,
                    };
                    vertex_index += 1;
                    outline_segment_index += 1;
                },
                .curve => {
                    const from = vertices[vertex_index - 1];
                    const to = vertices[vertex_index];
                    const point_from = Point(f64){ .x = @as(f64, @floatFromInt(from.x)) * scale, .y = height - (@as(f64, @floatFromInt(from.y)) * scale) };
                    const point_to = Point(f64){ .x = @as(f64, @floatFromInt(to.x)) * scale, .y = height - (@as(f64, @floatFromInt(to.y)) * scale) };
                    var segment_ptr: *OutlineSegment = &outlines[outline_index].segments[outline_segment_index];
                    segment_ptr.* = OutlineSegment{
                        .from = point_from,
                        .to = point_to,
                        .t_per_pixel = undefined,
                        .control = Point(f64){
                            .x = @as(f64, @floatFromInt(to.control1_x)) * scale,
                            .y = height - (@as(f64, @floatFromInt(to.control1_y)) * scale),
                        },
                    };
                    const outline_length_pixels: f64 = blk: {
                        //
                        // Approximate length of bezier curve
                        //
                        var i: usize = 1;
                        var accumulator: f64 = 0;
                        const point_previous = point_from;
                        while (i <= 10) : (i += 1) {
                            const point_sampled = segment_ptr.sample(@as(f64, @floatFromInt(i)) * 0.1);
                            accumulator += geometry.distanceBetweenPoints(point_previous, point_sampled);
                        }
                        break :blk accumulator;
                    };
                    const t_per_pixel: f64 = (1.0 / outline_length_pixels);
                    segment_ptr.t_per_pixel = if (t_per_pixel <= 1.0) t_per_pixel else 1.0;
                    vertex_index += 1;
                    outline_segment_index += 1;
                },
                // TODO:
                else => unreachable,
            }
        }
    }

    for (outlines) |*outline| {
        outline.calculateBoundingBox();
    }

    return outlines;
}
