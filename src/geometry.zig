// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");

pub fn Point(comptime T: type) type {
    return extern struct {
        x: T,
        y: T,
    };
}

pub fn Dimensions2D(comptime BaseType: type) type {
    return extern struct {
        height: BaseType,
        width: BaseType,
    };
}

pub fn Coordinates2D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
    };
}

pub fn Extent2D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
        height: BaseType,
        width: BaseType,
    };
}

pub fn BoundingBox(comptime T: type) type {
    return extern struct {
        x0: T,
        y0: T,
        x1: T,
        y1: T,
    };
}

pub fn Scale2D(comptime BaseType: type) type {
    return struct {
        horizontal: BaseType,
        vertical: BaseType,
    };
}

pub const BezierQuadratic = extern struct {
    a: Point(f64),
    b: Point(f64),
    control: Point(f64),
};

/// Used in quadraticBezierPlaneIntersections
pub const CurveYIntersection = struct {
    x: f64,
    t: f64,
};

pub fn distanceBetweenPoints(point_a: Point(f64), point_b: Point(f64)) f64 {
    const pow = std.math.pow;
    const sqrt = std.math.sqrt;
    return sqrt(pow(f64, point_b.y - point_a.y, 2) + pow(f64, point_a.x - point_b.x, 2));
}

pub fn quadraticBezierPoint(bezier: BezierQuadratic, t: f64) Point(f64) {
    std.debug.assert(t >= 0.0);
    std.debug.assert(t <= 1.0);
    const one_minus_t: f64 = 1.0 - t;
    const t_squared: f64 = t * t;
    const p0 = bezier.a;
    const p1 = bezier.b;
    const control = bezier.control;
    return .{
        .x = @floatCast(f64, (one_minus_t * one_minus_t) * p0.x + (2 * one_minus_t * t * control.x + (t_squared * p1.x))),
        .y = @floatCast(f64, (one_minus_t * one_minus_t) * p0.y + (2 * one_minus_t * t * control.y + (t_squared * p1.y))),
    };
}

pub fn quadradicBezierInflectionPoint(bezier: BezierQuadratic) Point(f64) {
    const line_ab_constant = bezier.a.y;
    const line_ab_t = (bezier.control.y - bezier.a.y);
    const line_bc_constant = bezier.control.y;
    const line_bc_t = (bezier.b.y - bezier.control.y);
    const t_total = line_ab_t - line_bc_t;

    const constant_total = line_ab_constant + line_bc_constant;
    const t = constant_total / t_total;

    const ab_lerp_x = bezier.a.x + ((bezier.control.x - bezier.a.x) * t);
    const ab_lerp_y = bezier.a.y + ((bezier.control.y - bezier.a.y) * t);

    const bc_lerp_x = bezier.control.x + ((bezier.b.x - bezier.control.x) * t);
    const bc_lerp_y = bezier.control.y + ((bezier.b.y - bezier.control.y) * t);

    return .{
        .x = ab_lerp_x + ((bc_lerp_x - ab_lerp_x) * t),
        .y = ab_lerp_y + ((bc_lerp_y - ab_lerp_y) * t),
    };
}

pub fn quadraticBezierPlaneIntersections(bezier: BezierQuadratic, horizontal_axis: f64) [2]?CurveYIntersection {
    const a: f64 = bezier.a.y;
    const b: f64 = bezier.control.y;
    const c: f64 = bezier.b.y;

    //
    // Handle edge-case where control.y is exactly inbetween end points (Leading to NaN)
    // A control point in the middle can be ignored and a normal percent based calculation is used.
    //
    const term_a = a - (2 * b) + c;
    if (term_a == 0.0) {
        const min = @min(a, c);
        const max = @max(a, c);
        if (horizontal_axis < min or horizontal_axis > max) return .{ null, null };
        const dist = c - a;
        const t = (horizontal_axis - a) / dist;
        std.debug.assert(t >= 0.0 and t <= 1.0);
        return .{
            CurveYIntersection{ .t = t, .x = quadraticBezierPoint(bezier, t).x },
            null,
        };
    }

    const term_b = 2 * (b - a);
    const term_c = a - horizontal_axis;

    const sqrt_calculation = std.math.sqrt((term_b * term_b) - (4.0 * term_a * term_c));

    const first_intersection_t = ((-term_b) + sqrt_calculation) / (2.0 * term_a);
    const second_intersection_t = ((-term_b) - sqrt_calculation) / (2.0 * term_a);

    const is_first_valid = (first_intersection_t <= 1.0 and first_intersection_t >= 0.0);
    const is_second_valid = (second_intersection_t <= 1.0 and second_intersection_t >= 0.0);

    return .{
        if (is_first_valid) CurveYIntersection{ .t = first_intersection_t, .x = quadraticBezierPoint(bezier, first_intersection_t).x } else null,
        if (is_second_valid) CurveYIntersection{ .t = second_intersection_t, .x = quadraticBezierPoint(bezier, second_intersection_t).x } else null,
    };
}

pub fn triangleArea(p1: Point(f64), p2: Point(f64), p3: Point(f64)) f64 {
    if (p1.x == p2.x and p2.x == p3.x) return 0.0;
    return @fabs((p1.x * (p2.y - p3.y)) + (p2.x * (p3.y - p1.y)) + (p3.x * (p1.y - p2.y))) / 2.0;
}

/// Given two points, one that lies inside a normalized boundry and one that lies outside
/// Interpolate a point between them that lies on the boundry of the imaginary 1x1 square
pub fn interpolateBoundryPoint(inside: Point(f64), outside: Point(f64)) Point(f64) {
    std.debug.assert(inside.x >= 0.0);
    std.debug.assert(inside.x <= 1.0);
    std.debug.assert(inside.y >= 0.0);
    std.debug.assert(inside.y <= 1.0);
    std.debug.assert(outside.x >= 1.0 or outside.x <= 0.0 or outside.y >= 1.0 or outside.y <= 0.0);

    if (outside.x == inside.x) {
        return Point(f64){
            .x = outside.x,
            .y = if (outside.y > inside.y) 1.0 else 0.0,
        };
    }

    if (outside.y == inside.y) {
        return Point(f64){
            .x = if (outside.x > inside.x) 1.0 else 0.0,
            .y = outside.y,
        };
    }

    const x_difference: f64 = outside.x - inside.x;
    const y_difference: f64 = outside.y - inside.y;
    const t: f64 = blk: {
        //
        // Based on lerp function `a - (b - a) * t = p`. Can be rewritten as follows:
        // `(-a + p) / (b - a) = t` where p is our desired value in the spectrum
        // 0.0 or 1.0 in our case, as they represent the left and right (Or top and bottom) sides of the pixel
        // We know whether we want 0.0 or 1.0 based on where the outside point lies in relation to the inside point
        //
        // Taking the x axis for example, if the outside point is to the right of our pixel bounds, we know that
        // we're looking for a p value of 1.0 as the line moves from left to right, otherwise it would be 0.0.
        //
        const side_x: f64 = if (inside.x > outside.x) 0.0 else 1.0;
        const side_y: f64 = if (inside.y > outside.y) 0.0 else 1.0;
        const t_x: f64 = (-inside.x + side_x) / (x_difference);
        const t_y: f64 = (-inside.y + side_y) / (y_difference);
        break :blk if (t_x > 1.0 or t_x < 0.0 or t_y < t_x) t_y else t_x;
    };

    std.debug.assert(t >= 0.0);
    std.debug.assert(t <= 1.0);

    return Point(f64){
        .x = inside.x + (x_difference * t),
        .y = inside.y + (y_difference * t),
    };
}

test "triangleArea" {
    const expect = std.testing.expect;
    {
        const p1 = Point(f64){ .x = 1.0, .y = 10.0 };
        const p2 = Point(f64){ .x = 1.0, .y = 20.0 };
        const p3 = Point(f64){ .x = 1.0, .y = 30.0 };
        const area = triangleArea(p1, p2, p3);
        try expect(area == 0.0);
    }
}

test "quadraticBezierPoint" {
    const expect = std.testing.expect;
    {
        const b = BezierQuadratic{
            .a = .{ .x = 16.882635839283466, .y = 0.0 },
            .b = .{
                .x = 23.494,
                .y = 1.208,
            },
            .control = .{ .x = 20.472, .y = 0.0 },
        };
        const s = quadraticBezierPoint(b, 0.0);
        try expect(s.x == 16.882635839283466);
        try expect(s.y == 0.0);
    }
}

test "quadraticBezierPlaneIntersection" {
    const expect = std.testing.expect;
    {
        const b = BezierQuadratic{
            .a = .{ .x = 16.882635839283466, .y = 0.0 },
            .b = .{
                .x = 23.494,
                .y = 1.208,
            },
            .control = .{ .x = 20.472, .y = 0.0 },
        };
        const s = quadraticBezierPlaneIntersections(b, 0.0);
        try expect(s[0].?.x == 16.882635839283466);
        try expect(s[0].?.t == 0.0);
        try expect(s[1].?.x == 16.882635839283466);
        try expect(s[1].?.t == 0.0);
    }
}

test "interpolateBoundryPoint" {
    {
        const in = Point(f64){
            .x = 0.5,
            .y = 0.5,
        };
        const out = Point(f64){
            .x = -2.0,
            .y = 0.5,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 0.5);
        try std.testing.expect(result.x == 0.0);
    }

    {
        const in = Point(f64){
            .x = 0.5,
            .y = 0.5,
        };
        const out = Point(f64){
            .x = 2.0,
            .y = 0.5,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 0.5);
        try std.testing.expect(result.x == 1.0);
    }

    {
        const in = Point(f64){
            .x = 0.5,
            .y = 0.5,
        };
        const out = Point(f64){
            .x = 0.5,
            .y = 2.0,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 1.0);
        try std.testing.expect(result.x == 0.5);
    }

    {
        const in = Point(f64){
            .x = 0.25,
            .y = 0.25,
        };
        const out = Point(f64){
            .x = 1.5,
            .y = 2.0,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 1.0);
        try std.testing.expect(result.x == 0.7857142857142857);
    }

    {
        const in = Point(f64){
            .x = 0.75,
            .y = 0.25,
        };
        const out = Point(f64){
            .x = -1.5,
            .y = 2.0,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 0.8333333333333333);
        try std.testing.expect(result.x == 0.0);
    }

    {
        const in = Point(f64){
            .x = 0.0,
            .y = 0.0,
        };
        const out = Point(f64){
            .x = -1.5,
            .y = -2.0,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 0.0);
        try std.testing.expect(result.x == 0.0);
    }

    {
        const in = Point(f64){
            .x = 1.0,
            .y = 1.0,
        };
        const out = Point(f64){
            .x = 2.5,
            .y = 1.0,
        };
        const result = interpolateBoundryPoint(in, out);
        try std.testing.expect(result.y == 1.0);
        try std.testing.expect(result.x == 1.0);
    }
}
