// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

pub const Face = opaque{};
pub const Font = opaque{};
pub const Buffer = opaque{};

pub const Tag = [4]u8;

pub const Feature = extern struct {
    tag: Tag,
    value: u32,
    start: u32,
    end: u32,
};

pub const GlyphInfo = extern struct {
    codepoint: u32,
    cluster: u32,
};

pub const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
};