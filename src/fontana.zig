// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const otf = @import("otf.zig");
const rasterizer = @import("rasterizer.zig");
const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");
const freetype = @import("freetype.zig");
const harfbuzz = @import("harfbuzz.zig");

const font_api = @import("backends/api.zig");

const backends = struct {
    pub const fontana = @import("backends/fontana.zig");
    pub const freetype = @import("backends/freetype.zig");
    pub const freetype_harfbuzz = @import("backends/freetype_harfbuzz.zig");
};

pub const Atlas = @import("Atlas.zig");

const FontOptions = struct {
    backend: Backend,
    type_overrides: font_api.OverridableTypes = .{},
};

pub fn Font(comptime options: FontOptions) type {
    return switch (options.backend) {
        .fontana => backends.fontana.FontConfig(.{ .type_overrides = options.type_overrides }),
        .freetype => backends.freetype.FontConfig(.{ .type_overrides = options.type_overrides }),
        .freetype_harfbuzz => backends.freetype_harfbuzz.FontConfig(.{ .type_overrides = options.type_overrides }),
    };
}

pub const Backend = enum {
    freetype,
    freetype_harfbuzz,
    fontana,
};
