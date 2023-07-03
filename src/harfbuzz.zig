// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");

pub const Face = opaque {};
pub const Font = opaque {};
pub const Buffer = opaque {};
pub const Language = *opaque {};

pub const Tag = u32;

pub const Feature = extern struct {
    tag: Tag,
    value: u32,
    start: u32,
    end: u32,
};

pub const feature_global_start: u32 = 0;
pub const feature_global_end: u32 = std.math.maxInt(u32);

pub const GlyphInfo = extern struct {
    codepoint: u32,
    cluster: u32,
};

pub const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    _padding: u32,
};

pub const Direction = enum(i32) {
    invalid = 0,
    left_to_right = 4,
    right_to_left = 5,
    top_to_bottom = 6,
    bottom_to_top = 7,
};

pub const Script = enum(u32) {
    common = makeTag("Zyyy"),
    inherited = makeTag("Zinh"),
    unknown = makeTag("Zzzz"),

    arabic = makeTag("Arab"),
    armenian = makeTag("Armn"),
    bengali = makeTag("Beng"),
    cyrillic = makeTag("Cyrl"),
    devanagari = makeTag("Deva"),
    georgian = makeTag("Geor"),
    greek = makeTag("Grek"),
    gujarati = makeTag("Gujr"),
    gurmukhi = makeTag("Guru"),
    hangul = makeTag("Hang"),
    han = makeTag("Hani"),
    hebrew = makeTag("Hebr"),
    hiragana = makeTag("Hira"),
    kannada = makeTag("Knda"),
    katakana = makeTag("Kana"),
    lao = makeTag("Laoo"),
    latin = makeTag("Latn"),
    malayalam = makeTag("Mlym"),
    oriya = makeTag("Orya"),
    tamil = makeTag("Taml"),
    telugu = makeTag("Telu"),
    thai = makeTag("Thai"),
    tibetan = makeTag("Tibt"),
    bopomofo = makeTag("Bopo"),
    braille = makeTag("Brai"),
    canadian_syllabic = makeTag("Cans"),
    cherokee = makeTag("Cher"),
    ethiopic = makeTag("Ethi"),
    khmer = makeTag("Khmr"),
    mongolian = makeTag("Mong"),
    myanmar = makeTag("Mymr"),
    ogham = makeTag("Ogam"),
    runic = makeTag("Runr"),
    sinhala = makeTag("Sinh"),
    syriac = makeTag("Syrc"),
    thaana = makeTag("Thaa"),
    yi = makeTag("Yiii"),
    deseret = makeTag("Dsrt"),
    gothic = makeTag("Goth"),
    old_italic = makeTag("Ital"),
    buhid = makeTag("Buhd"),
    hanunoo = makeTag("Hano"),
    tagalog = makeTag("Tglg"),
    tagbanwa = makeTag("Tagb"),
    cypriot = makeTag("Cprt"),
    limbu = makeTag("Limb"),
    linear_b = makeTag("Linb"),
    osmanya = makeTag("Osma"),
    shavian = makeTag("Shaw"),
    tai_le = makeTag("Tale"),
    ugaritic = makeTag("Ugar"),
    buginese = makeTag("Bugi"),
    coptic = makeTag("Copt"),
    glagolitic = makeTag("Glag"),
    kharoshthi = makeTag("Khar"),
    new_tai_lue = makeTag("Talu"),
    old_persian = makeTag("Xpeo"),
    syloti_nagri = makeTag("Sylo"),
    tifinagh = makeTag("Tfng"),
    balinese = makeTag("Bali"),
    cuneiform = makeTag("Xsux"),
    nko = makeTag("Nkoo"),
    phags_pa = makeTag("Phag"),
    phoenician = makeTag("Phnx"),
    carian = makeTag("Cari"),
    cham = makeTag("Cham"),
    kayah_li = makeTag("Kali"),
    lepcha = makeTag("Lepc"),
    lycian = makeTag("Lyci"),
    lydian = makeTag("Lydi"),
    ol_chiki = makeTag("Olck"),
    rejang = makeTag("Rjng"),
    saurashtra = makeTag("Saur"),
    sundanese = makeTag("Sund"),
    vai = makeTag("Vaii"),
};

pub inline fn makeTag(comptime c: *const [4]u8) u32 {
    var bits: u32 = 0;
    bits += @as(u32, @intCast(c[0])) << 24;
    bits += @as(u32, @intCast(c[1])) << 16;
    bits += @as(u32, @intCast(c[2])) << 8;
    bits += @as(u32, @intCast(c[3])) << 0;
    return bits;
}
