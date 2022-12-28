// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

pub const Subglyph = *opaque {};
pub const SlotInternal = *opaque {};
pub const Library = *opaque {};

pub const Fixed = i64;
pub const Pos = i64;
pub const F26Dot6 = i64;

// TODO: Implement enums
pub const GlyphFormat = i32;
pub const Encoding = i32;

pub const LoadFlags = packed struct(i32) {
    no_scale: bool = false,
    no_hinting: bool = false,
    render: bool = false,
    no_bitmap: bool = false,
    vertical_layout: bool = false,
    force_autohint: bool = false,
    crop_bitmap: bool = false,
    pedantic: bool = false,

    reserved_bit_8: bool = false,

    ignore_global_advance_width: bool = false,
    no_recurse: bool = false,
    ignore_transform: bool = false,
    monochrome: bool = false,
    linear_design: bool = false,
    sbits_only: bool = false,
    no_autohint: bool = false,

    reserved_bit_16: bool = false,
    reserved_bit_17: bool = false,
    reserved_bit_18: bool = false,
    reserved_bit_19: bool = false,

    color: bool = false,
    compute_metrics: bool = false,
    bitmap_metrics_only: bool = false,

    reserved_bit_23: bool = false,
    reserved_bit_24: bool = false,
    reserved_bit_25: bool = false,
    reserved_bit_26: bool = false,
    reserved_bit_27: bool = false,
    reserved_bit_28: bool = false,
    reserved_bit_29: bool = false,
    reserved_bit_30: bool = false,
    reserved_bit_31: bool = false,
};

pub const Vector = extern struct {
    x: Pos,
    y: Pos,
};

pub const Outline = extern struct {
    contour_count: i16,
    point_count: i16,
    points: [*]Vector,
    tags: [*]const u8,
    contours: [*]i16,
    flags: i32,
};

pub const BitmapSize = extern struct {
    height: i16,
    width: i16,
    size: i64,
    x_ppem: i64,
    y_ppem: i64,
};

pub const GlyphMetrics = extern struct {
    width: Pos,
    height: Pos,
    hori_bearing_x: Pos,
    hori_bearing_y: Pos,
    hori_advance: Pos,
    vert_bearing_x: Pos,
    vert_bearing_y: Pos,
    vert_advance: Pos,
};

pub const Bitmap = extern struct {
    rows: u32,
    width: u32,
    pitch: i32,
    buffer: [*]u8,
    num_grays: u16,
    pixel_mode: u8,
    palette_mode: u8,
    palette: *void,
};

pub const GlyphSlot = *GlyphSlotRec;

pub const GlyphSlotRec = extern struct {
    library: Library,
    face: Face,
    next: GlyphSlot,
    glyph_index: u32,
    generic: Generic,
    metrics: GlyphMetrics,
    linear_hori_advance: Fixed,
    linear_vert_advance: Fixed,
    advance: Vector,
    format: GlyphFormat,
    bitmap: Bitmap,
    bitmap_left: i32,
    bitmap_top: i32,
    outline: Outline,
    num_subglyphs: u32,
    subglyph: Subglyph,
    control_data: *void,
    control_len: i64,
    lsb_delta: Pos,
    rsb_delta: Pos,
    other: *void,
    internal: SlotInternal,
};

pub const Charmap = extern struct {
    face: Face,
    encoding: Encoding,
    platform_id: u16,
    encoding_id: u16,
};

pub const Generic = extern struct {
    data: *void,
    finalizer: *const fn (*void) callconv(.C) void,
};

pub const BBox = extern struct {
    xMin: i64,
    yMin: i64,
    xMax: i64,
    yMax: i64,
};

pub const FaceRec = extern struct {
    num_faces: i64,
    face_index: i64,
    face_flags: i64,
    style_flags: i64,
    num_glyphs: i64,

    family_name: [*:0]const u8,
    style_name: [*:0]const u8,

    num_fixed_sizes: i32,
    available_sizes: *BitmapSize,

    num_charmaps: i32,
    charmaps: *Charmap,

    generic: Generic,

    bbox: BBox,
    units_per_EM: u16,

    ascender: i16,
    descender: i16,
    max_advance_width: i16,
    max_advance_height: i16,
    underline_position: i16,
    underline_thickness: i16,

    glyph: GlyphSlot,
    charmap: Charmap,
};

pub const Face = *FaceRec;
