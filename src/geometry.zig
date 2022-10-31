// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

pub fn Dimensions2D(comptime BaseType: type) type {
    return packed struct {
        height: BaseType,
        width: BaseType,
    };
}

pub fn Extent2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
        height: BaseType,
        width: BaseType,
    };
}

fn BoundingBox(comptime T: type) type {
    return struct {
        x0: T,
        y0: T,
        x1: T,
        y1: T,
    };
}