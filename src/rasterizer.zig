// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const is_debug = if (builtin.mode == .Debug) true else false;

const Point = geometry.Point;

const YRange = struct {
    upper: f64,
    lower: f64,
};

const YIntersection = struct {
    outline_index: u32,
    x_intersect: f64,
    t: f64, // t value (sample) of outline
};

fn StackArray(comptime BaseType: type, comptime capacity: comptime_int) type {
    return struct {
        buffer: [capacity]BaseType,
        len: u64,

        pub fn add(self: *@This(), item: BaseType) !void {
            if (self.len == capacity) {
                return error.BufferFull;
            }
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn addFront(self: *@This(), item: BaseType) !void {
            if (self.len == capacity) {
                return error.BufferFull;
            }
            if (self.len == 0) {
                self.buffer[0] = item;
            } else {
                // right shift all
                var dst_index = self.len;
                while (dst_index > 0) : (dst_index -= 1) {
                    const src_index = dst_index - 1;
                    self.buffer[dst_index] = self.buffer[src_index];
                }
                self.buffer[0] = item;
            }
            self.len += 1;
        }

        // NOTE: Pass by pointer is required. Otherwise garbage value is returned
        pub fn toSlice(self: *@This()) []const BaseType {
            return self.buffer[0..self.len];
        }

        pub fn toSliceMut(self: *@This()) []BaseType {
            return self.buffer[0..self.len];
        }
    };
}

const YIntersectionPair = struct {
    start: YIntersection,
    end: YIntersection,
};

const YIntersectionPairList = StackArray(YIntersectionPair, 32);
const YIntersectionList = StackArray(YIntersection, 32);
const IntersectionConnectionList = StackArray(IntersectionConnection, 32);

const IntersectionConnection = struct {
    const Flags = packed struct {
        invert_coverage: bool = false,
    };

    lower: ?YIntersectionPair,
    upper: ?YIntersectionPair,
    flags: Flags = .{},
};

const IntersectionList = struct {
    const capacity = 64;

    upper_index_start: u32,
    lower_index_start: u32,
    upper_count: u32,
    lower_count: u32,
    increment: i32,
    buffer: [capacity]YIntersection,

    fn makeFromSeperateScanlines(uppers: []const YIntersection, lowers: []const YIntersection) IntersectionList {
        std.debug.assert(uppers.len + lowers.len <= IntersectionList.capacity);
        var result = IntersectionList{
            .upper_index_start = 0,
            .lower_index_start = @intCast(u32, uppers.len),
            .upper_count = @intCast(u32, uppers.len),
            .lower_count = @intCast(u32, lowers.len),
            .increment = 1,
            .buffer = undefined,
        };

        var i: usize = 0;
        for (uppers) |upper| {
            result.buffer[i] = upper;
            i += 1;
        }
        for (lowers) |lower| {
            result.buffer[i] = lower;
            i += 1;
        }
        const total_len = uppers.len + lowers.len;
        std.debug.assert(result.length() == total_len);
        std.debug.assert(result.toSlice().len == total_len);
        return result;
    }

    inline fn toSlice(self: *const @This()) []const YIntersection {
        const start_index = @min(self.upper_index_start, self.lower_index_start);
        return self.buffer[start_index .. start_index + (self.upper_count + self.lower_count)];
    }

    inline fn length(self: @This()) usize {
        return self.upper_count + self.lower_count;
    }

    inline fn at(self: @This(), index: usize) YIntersection {
        return self.toSlice()[index];
    }

    inline fn isUpper(self: @This(), index: usize) bool {
        const upper_start: u32 = self.upper_index_start;
        const upper_end: i64 = upper_start + @intCast(i64, self.upper_count) - 1;
        return (upper_start <= upper_end and index >= upper_start and index <= upper_end);
    }

    // Two points are 't_connected', if there doesn't exist a closer t value
    // going in the same direction (Forward or reverse)
    inline fn isTConnected(self: @This(), base_index: usize, candidate_index: usize, max_t: f64) bool {
        const slice = self.toSlice();

        const base_outline_index = slice[base_index].outline_index;
        std.debug.assert(base_outline_index == slice[candidate_index].outline_index);

        const base_t = slice[base_index].t;
        const candidate_t = slice[candidate_index].t;
        if (base_t == candidate_t) return true;

        const dist_forward = @mod(candidate_t + (max_t - base_t), max_t);
        std.debug.assert(dist_forward >= 0.0);
        std.debug.assert(dist_forward < max_t);

        const dist_reverse = @mod(@fabs(base_t + (max_t - candidate_t)), max_t);
        std.debug.assert(dist_reverse >= 0.0);
        std.debug.assert(dist_reverse < max_t);

        const is_forward = if (dist_forward < dist_reverse) true else false;
        if (is_forward) {
            for (slice, 0..) |other, other_i| {
                if (other.t == base_t or other.t == candidate_t) continue;
                if (other_i == candidate_index or other_i == base_index) continue;
                if (other.outline_index != base_outline_index) continue;
                const dist_other = @mod(other.t + (max_t - base_t), max_t);
                if (dist_other < dist_forward) {
                    return false;
                }
            }
            return true;
        }
        for (slice, 0..) |other, other_i| {
            if (other.t == base_t or other.t == candidate_t) continue;
            if (other_i == candidate_index or other_i == base_index) continue;
            if (other.outline_index != base_outline_index) continue;
            const dist_other = @mod(@fabs(base_t + (max_t - other.t)), max_t);
            if (dist_other < dist_reverse) {
                return false;
            }
        }
        return true;
    }

    fn swapScanlines(self: *@This()) !void {
        self.lower_index_start = self.upper_index_start;
        self.lower_count = self.upper_count;
        self.upper_count = 0;
        self.upper_index_start = blk: {
            const lower_index_end = self.lower_index_start + self.lower_count;
            const space_forward = self.capacity - lower_index_end;
            const space_behind = self.lower_index_start;
            if (space_forward > space_behind) {
                self.increment = 1;
                break :blk lower_index_end;
            }
            self.increment = 1;
            break :blk self.lower_index_start - 1;
        };
    }

    inline fn add(self: *@This(), intersection: YIntersection) !void {
        self.buffer[self.upper_index_start + self.increment] = intersection;
        self.upper_count += 1;
    }
};

inline fn clamp(value: f64, lower: f64, upper: f64) f64 {
    return @min(@max(value, lower), upper);
}

pub const Outline = struct {
    segments: []OutlineSegment,
    y_range: YRange,

    pub fn calculateBoundingBox(self: *@This()) void {
        self.y_range = .{ .lower = 1000, .upper = -1000.0 };
        for (self.segments) |*segment| {
            const point_a = segment.from;
            const point_b = segment.to;
            segment.y_range.lower = @min(point_a.y, point_b.y);
            segment.y_range.upper = @max(point_a.y, point_b.y);
            if (segment.isCurve()) {
                const control_point = segment.control;
                //
                // source: https://iquilezles.org/articles/bezierbbox/
                //
                if (control_point.y > segment.y_range.upper or control_point.y < segment.y_range.lower) {
                    const t_unclamped = (point_a.y - control_point.y) / (point_a.y - (2.0 * control_point.y) + point_b.y);
                    const t = clamp(t_unclamped, 0.0, 1.0);
                    const s = 1.0 - t;
                    const q = s * s * point_a.y + (2.0 * s * t * control_point.y) + t * t + point_b.y;
                    segment.y_range.lower = @min(segment.y_range.lower, q);
                    segment.y_range.upper = @max(segment.y_range.upper, q);
                }
            }
            self.y_range.lower = @min(self.y_range.lower, segment.y_range.lower);
            self.y_range.upper = @max(self.y_range.upper, segment.y_range.upper);
        }
    }

    pub inline fn withinYBounds(self: @This(), y_scanline: f64) bool {
        return (y_scanline >= self.y_range.lower and y_scanline <= self.y_range.upper);
    }

    pub fn samplePoint(self: @This(), t: f64) Point(f64) {
        const t_floored: f64 = @floor(t);
        const segment_index = @intFromFloat(usize, t_floored);
        std.debug.assert(segment_index < self.segments.len);
        return self.segments[segment_index].sample(t - t_floored);
    }
};

pub const OutlineSegment = struct {
    const null_control: f64 = std.math.floatMin(f64);

    y_range: YRange = undefined,
    from: Point(f64),
    to: Point(f64),
    control: Point(f64) = .{ .x = @This().null_control, .y = undefined },
    /// The t value that corresponds to 1 pixel of distance (approx)
    t_per_pixel: f64,

    pub inline fn isCurve(self: @This()) bool {
        return self.control.x != @This().null_control;
    }

    pub inline fn withinYBounds(self: @This(), y_scanline: f64) bool {
        return (y_scanline >= self.y_range.lower and y_scanline <= self.y_range.upper);
    }

    pub fn sample(self: @This(), t: f64) Point(f64) {
        std.debug.assert(t <= 1.0);
        std.debug.assert(t >= 0.0);
        if (self.isCurve()) {
            const bezier = geometry.BezierQuadratic{
                .a = self.from,
                .b = self.to,
                .control = self.control,
            };
            return geometry.quadraticBezierPoint(bezier, t);
        }
        return .{
            .x = self.from.x + (self.to.x - self.from.x) * t,
            .y = self.from.y + (self.to.y - self.from.y) * t,
        };
    }
};

pub fn SubTexturePixelWriter(comptime PixelType: type, comptime Extent2DPixel: type) type {
    return struct {
        texture_width: u32,
        write_extent: Extent2DPixel,
        pixels: [*]PixelType,

        pub inline fn add(self: @This(), coords: geometry.Coordinates2D(usize), coverage: f64) void {
            const x = coords.x;
            const y = coords.y;
            std.debug.assert(coverage >= 0);
            std.debug.assert(coverage <= 1);
            std.debug.assert(x >= 0);
            std.debug.assert(x < self.write_extent.width);
            std.debug.assert(y >= 0);
            std.debug.assert(y < self.write_extent.height);
            const global_x = self.write_extent.x + x;
            const global_y = self.write_extent.y + y;
            const index = global_x + (self.texture_width * global_y);
            const c = @floatCast(f32, coverage);

            // TODO: Detect type using comptime
            const use_transparency: bool = @hasField(PixelType, "a");

            if (@hasField(PixelType, "r"))
                self.pixels[index].r = if (use_transparency) 0.8 else self.pixels[index].r + c;

            if (@hasField(PixelType, "g"))
                self.pixels[index].g = if (use_transparency) 0.8 else self.pixels[index].g + c;

            if (@hasField(PixelType, "b"))
                self.pixels[index].b = if (use_transparency) 0.8 else self.pixels[index].b + c;

            if (use_transparency) {
                self.pixels[index].a += c;
            }
        }

        pub inline fn sub(self: @This(), coords: geometry.Coordinates2D(usize), coverage: f64) void {
            const x = coords.x;
            const y = coords.y;
            std.debug.assert(coverage >= 0);
            std.debug.assert(coverage <= 1);
            std.debug.assert(x >= 0);
            std.debug.assert(x < self.write_extent.width);
            std.debug.assert(y >= 0);
            std.debug.assert(y < self.write_extent.height);
            const global_x = self.write_extent.x + x;
            const global_y = self.write_extent.y + y;
            const index = global_x + (self.texture_width * global_y);
            const c = @floatCast(f32, coverage);

            // TODO: Detect type using comptime
            const use_transparency: bool = @hasField(PixelType, "a");

            if (@hasField(PixelType, "r"))
                self.pixels[index].r = if (use_transparency) 0.8 else self.pixels[index].r - c;

            if (@hasField(PixelType, "g"))
                self.pixels[index].g = if (use_transparency) 0.8 else self.pixels[index].g - c;

            if (@hasField(PixelType, "b"))
                self.pixels[index].b = if (use_transparency) 0.8 else self.pixels[index].b - c;

            if (use_transparency) {
                self.pixels[index].a -= c;
            }
        }

        pub inline fn set(self: @This(), coords: geometry.Coordinates2D(usize), coverage: f64) void {
            const x = coords.x;
            const y = coords.y;
            std.debug.assert(x >= 0);
            std.debug.assert(x < self.write_extent.width);
            std.debug.assert(y >= 0);
            std.debug.assert(y < self.write_extent.height);
            const global_x = self.write_extent.x + x;
            const global_y = self.write_extent.y + y;
            const index = global_x + (self.texture_width * global_y);
            const c = @floatCast(f32, coverage);

            // TODO: Detect type using comptime
            const use_transparency: bool = @hasField(PixelType, "a");

            if (@hasField(PixelType, "r"))
                self.pixels[index].r = if (use_transparency) 0.8 else c;

            if (@hasField(PixelType, "g"))
                self.pixels[index].g = if (use_transparency) 0.8 else c;

            if (@hasField(PixelType, "b"))
                self.pixels[index].b = if (use_transparency) 0.8 else c;

            if (use_transparency) {
                self.pixels[index].a = c;
            }
        }
    };
}

inline fn minTMiddle(a: f64, b: f64, max: f64) f64 {
    const positive = (a <= b);
    const dist_forward = if (positive) b - a else b + (max - a);
    const dist_reverse = if (positive) max - dist_forward else a - b;
    if (dist_forward < dist_reverse) {
        return @mod(a + (dist_forward / 2.0), max);
    }
    var middle = @mod(b + (dist_reverse / 2.0), max);
    const result = if (middle >= 0.0) middle else middle + max;
    std.debug.assert(result >= 0.0);
    std.debug.assert(result <= max);
    return result;
}

inline fn floatCompare(first: f64, second: f64) bool {
    const float_accuracy_threshold: f64 = 0.00001;
    if (first < (second + float_accuracy_threshold) and first > (second - float_accuracy_threshold))
        return true;
    return false;
}

const OutlineSamplerUnbounded = struct {
    segments: []OutlineSegment,
    t_start: f64,
    t_max: f64,
    t_current: f64,
    t_increment: f64,
    samples_per_pixel: f32,
    t_direction: f32,

    pub fn init(self: *@This(), t_end: f64) void {
        const current_segment = self.segments[@intFromFloat(usize, @floor(self.t_start))];
        const t_per_pixel = current_segment.t_per_pixel;
        self.t_direction = blk: {
            if (self.t_start < t_end) {
                const forward = t_end - self.t_start;
                const backward = self.t_start + (self.t_max - t_end);
                if (forward < backward) {
                    break :blk 1.0;
                } else {
                    break :blk -1.0;
                }
            } else {
                const forward = t_end + (self.t_max - self.t_start);
                const backward = self.t_start - t_end;
                if (forward < backward) {
                    break :blk 1.0;
                } else {
                    break :blk -1.0;
                }
            }
        };
        self.t_current = self.t_start;
        self.t_increment = self.t_direction * (t_per_pixel / self.samples_per_pixel);
    }

    pub inline fn nextSample(self: *@This(), origin: Point(f64)) Point(f64) {
        const old_segment_index = @intFromFloat(usize, @floor(self.t_current));
        const old_segment = self.segments[old_segment_index];

        self.t_current = @mod(self.t_current + self.t_increment + self.t_max, self.t_max);
        std.debug.assert(self.t_current >= 0.0);
        std.debug.assert(self.t_current <= self.t_max);
        const t_current_floored = @floor(self.t_current);
        const segment_index = @intFromFloat(usize, t_current_floored);
        const current_segment = self.segments[segment_index];
        if (segment_index != old_segment_index) {
            //
            // Recalculate t_increment for new segment
            //
            const t_per_pixel = current_segment.t_per_pixel;
            self.t_increment = self.t_direction * (t_per_pixel / self.samples_per_pixel);
            std.debug.assert(@fabs(self.t_increment) < 1.0);
            if (self.t_direction == 1.0) {
                self.t_current = @floor(self.t_current);
                std.debug.assert(old_segment.to.x == current_segment.from.x);
                std.debug.assert(old_segment.to.y == current_segment.from.y);
                const relative_y = old_segment.to.y - origin.y;
                return Point(f64){
                    .x = old_segment.to.x - origin.x,
                    .y = relative_y,
                };
            }
            self.t_current = @ceil(self.t_current) + self.t_increment;
            std.debug.assert(old_segment.from.x == current_segment.to.x);
            std.debug.assert(old_segment.from.y == current_segment.to.y);
            const relative_y = old_segment.from.y - origin.y;
            return Point(f64){
                .x = old_segment.from.x - origin.x,
                .y = relative_y,
            };
        }
        const sampled_point = current_segment.sample(self.t_current - t_current_floored);
        return Point(f64){
            .x = sampled_point.x - origin.x,
            .y = sampled_point.y - origin.y,
        };
    }
};

fn assertNormalized(point: Point(f64)) void {
    std.debug.assert(point.x <= 1.0);
    std.debug.assert(point.x >= 0.0);
    std.debug.assert(point.y <= 1.0);
    std.debug.assert(point.y >= 0.0);
}

fn assertYNormalized(point: Point(f64)) void {
    std.debug.assert(point.y <= 1.0);
    std.debug.assert(point.y >= 0.0);
}

pub fn rasterize(
    comptime PixelType: type,
    dimensions: geometry.Dimensions2D(u32),
    outlines: []Outline,
    pixel_writer: anytype,
) !void {
    if (PixelType != graphics.RGBA(f32)) {
        @compileError("rasterize function only supports bitmaps of RGBA(f32)");
    }

    //
    // TODO: This might be expensive and unnecessary. For the moment though it's the safer option to
    // clear any part of the texture before writing to it. Later on we can add the constraint
    // that the texture should be cleared in advance, or confirm that cost is minimal
    //
    {
        var y: usize = 0;
        while (y < dimensions.height) : (y += 1) {
            var x: usize = 0;
            while (x < dimensions.width) : (x += 1) {
                pixel_writer.set(.{ .x = x, .y = y }, 0);
            }
        }
    }

    const scanline_increment: f64 = 0.5;
    const scanlines_required = @intFromFloat(usize, @divExact(@floatFromInt(f64, dimensions.height), scanline_increment));
    var scanline_i: usize = 0;
    var intersections_upper = try calculateHorizontalLineIntersections(0, outlines);
    while (scanline_i < scanlines_required) : (scanline_i += 1) {
        const scanline_lower: f64 = @floatFromInt(f64, scanline_i + 1) * scanline_increment;
        const scanline_upper: f64 = @floatFromInt(f64, scanline_i) * scanline_increment;
        const pixel_y: usize = @intFromFloat(usize, @floor(scanline_upper));

        var intersections_lower = try calculateHorizontalLineIntersections(scanline_lower, outlines);
        if (intersections_lower.len == 0 and intersections_upper.len == 0) {
            intersections_upper = intersections_lower;
            continue;
        }
        const uppers = intersections_upper.toSlice();
        const lowers = intersections_lower.toSlice();
        const connected_intersection_list = try combineIntersectionLists(uppers, lowers, scanline_upper, outlines);
        const connected_intersections = connected_intersection_list.buffer[0..connected_intersection_list.len];
        for (connected_intersections) |intersect_pair| {
            const upper_opt = intersect_pair.upper;
            const lower_opt = intersect_pair.lower;
            const y_low = scanline_upper - @floor(scanline_upper);
            const y_high = scanline_lower - @floor(scanline_upper);
            std.debug.assert(y_high - y_low == scanline_increment);
            if (upper_opt != null and lower_opt != null) {
                //
                // Ideal situation, we have two points on upper and lower scanline (4 in total)
                // This forms a quadralateral in the range y (0.0 - 1.0) and x (0.0 - dimensions.width)
                //
                const upper = upper_opt.?;
                const lower = lower_opt.?;
                var fill_start: usize = std.math.maxInt(usize);
                var fill_end: usize = 0;

                {
                    //
                    // Start Anti-aliasing
                    //
                    const upper_is_left = if (upper.start.x_intersect < lower.start.x_intersect) true else false;
                    const intersect_left = if (upper_is_left) upper.start else lower.start;
                    const intersect_right = if (!upper_is_left) upper.start else lower.start;
                    const left_x = intersect_left.x_intersect;
                    const right_x = intersect_right.x_intersect;
                    const pixel_end = @intFromFloat(usize, @floor(right_x));
                    const outline_index = upper.start.outline_index;
                    std.debug.assert(outline_index == lower.start.outline_index);
                    doAntiAliasing(
                        Point(f64){ .x = left_x, .y = if (upper_is_left) y_low else y_high },
                        Point(f64){ .x = right_x, .y = if (upper_is_left) y_high else y_low },
                        intersect_left.t,
                        intersect_right.t,
                        pixel_y,
                        outlines[outline_index],
                        pixel_writer,
                        false,
                    );
                    fill_start = pixel_end + 1;
                }
                {
                    //
                    // End Anti-aliasing
                    //
                    const upper_is_left = if (upper.end.x_intersect < lower.end.x_intersect) true else false;
                    const intersect_left = if (upper_is_left) upper.end else lower.end;
                    const intersect_right = if (!upper_is_left) upper.end else lower.end;
                    const left_x = intersect_left.x_intersect;
                    const right_x = intersect_right.x_intersect;
                    const pixel_start = @intFromFloat(usize, @floor(left_x));
                    const outline_index = upper.end.outline_index;
                    std.debug.assert(outline_index == lower.end.outline_index);
                    doAntiAliasing(
                        Point(f64){ .x = left_x, .y = if (upper_is_left) y_low else y_high },
                        Point(f64){ .x = right_x, .y = if (upper_is_left) y_high else y_low },
                        intersect_left.t,
                        intersect_right.t,
                        pixel_y,
                        outlines[outline_index],
                        pixel_writer,
                        true,
                    );
                    if (pixel_start > 0) {
                        fill_end = pixel_start - 1;
                    }
                }
                //
                // Inner fill
                //
                var i: usize = @intCast(usize, fill_start);
                while (i <= @intCast(usize, fill_end)) : (i += 1) {
                    pixel_writer.add(.{ .x = i, .y = pixel_y }, 1.0 * scanline_increment);
                }
            } else {
                //
                // We only have a upper or lower scanline
                //
                const is_upper = if (upper_opt != null) true else false;
                const pair = if (is_upper) upper_opt.? else lower_opt.?;
                const invert_coverage = intersect_pair.flags.invert_coverage;
                const outline_index = pair.start.outline_index;
                const segments = outlines[outline_index].segments;

                rasterize2Point(
                    pair,
                    pixel_y,
                    y_low,
                    y_high,
                    if (is_upper) y_low else y_high,
                    invert_coverage,
                    segments,
                    pixel_writer,
                );
            }
        }
        intersections_upper = intersections_lower;
    }
}

fn doAntiAliasing(
    point_left: Point(f64),
    point_right: Point(f64),
    t_start: f64,
    t_end: f64,
    pixel_y: usize,
    outline: Outline,
    pixel_writer: anytype,
    invert: bool,
) void {
    const y_low = @min(point_left.y, point_right.y);
    const y_high = @max(point_left.y, point_right.y);
    const coverage_weight = y_high - y_low;

    const pixel_start = @intFromFloat(usize, @floor(point_left.x));
    const pixel_end = @intFromFloat(usize, @floor(point_right.x));
    if (pixel_start == pixel_end) {
        //
        // The upper and lower parts of the initial intersection lie on the same pixel.
        // Coverage of pixel is the horizonal average between both points and there are
        // no more pixels that need anti-aliasing calculated
        //
        const relative_start = point_left.x - @floor(point_left.x);
        const relative_end = point_right.x - @floor(point_right.x);
        const coverage = coverage_weight * ((relative_start + relative_end) / 2.0);
        std.debug.assert(coverage <= coverage_weight);
        std.debug.assert(coverage >= 0.0);
        pixel_writer.add(
            .{ .x = pixel_start, .y = pixel_y },
            if (invert) coverage else coverage_weight - coverage,
        );
        return;
    }

    const segments = outline.segments;
    const sample_t_max = @floatFromInt(f64, segments.len);

    var sampler = OutlineSamplerUnbounded{
        .segments = segments,
        .t_start = t_start,
        .t_max = sample_t_max,
        .samples_per_pixel = 4,
        .t_current = undefined,
        .t_direction = undefined,
        .t_increment = undefined,
    };
    sampler.init(t_end);

    var pixel_x = pixel_start;
    var fill_anchor_point = Point(f64){ .x = 1.0, .y = point_left.y };

    var previous_point = Point(f64){
        .x = point_left.x - @floatFromInt(f64, pixel_x),
        .y = point_left.y,
    };

    var origin = Point(f64){
        .x = @floor(point_left.x),
        .y = @floatFromInt(f64, pixel_y),
    };

    var coverage: f64 = 0.0;
    while (true) {
        var sampled_point = sampler.nextSample(origin);
        if (sampled_point.x >= 1.0) {
            const interpolated_point = geometry.interpolateBoundryPoint(previous_point, sampled_point);
            assertNormalized(interpolated_point);
            coverage += geometry.triangleArea(interpolated_point, previous_point, fill_anchor_point);
            if (is_debug and coverage > coverage_weight) {
                std.log.warn("Coverage set to 1.0 from {d} in g_aa next pixel", .{coverage});
            }
            coverage = @min(coverage, coverage_weight);
            pixel_writer.add(
                .{ .x = pixel_x, .y = pixel_y },
                if (invert) coverage_weight - coverage else coverage,
            );

            previous_point = .{ .x = 0.0, .y = interpolated_point.y };
            pixel_x += 1;
            origin.x = @floatFromInt(f64, pixel_x);

            if (sampled_point.y > y_high or sampled_point.y < y_low) {
                break;
            }

            const next_point = Point(f64){
                .x = sampled_point.x - 1.0,
                .y = sampled_point.y,
            };
            assertNormalized(next_point);
            coverage = geometry.triangleArea(.{ .x = 0.0, .y = point_left.y }, previous_point, fill_anchor_point);
            coverage += geometry.triangleArea(next_point, previous_point, fill_anchor_point);
            continue;
        }

        if (sampled_point.y > y_high or sampled_point.y < y_low) break;

        coverage += geometry.triangleArea(sampled_point, previous_point, fill_anchor_point);
        previous_point = sampled_point;
    }

    if (is_debug and pixel_x != pixel_end) {
        std.log.warn("s_aa: Not ending on last pixel. Expected {d} actual {d}", .{
            pixel_end,
            pixel_x,
        });
    }
    const end_point = Point(f64){
        .y = point_right.y,
        .x = point_right.x - @floatFromInt(f64, pixel_end),
    };
    assertNormalized(end_point);

    coverage += geometry.triangleArea(end_point, previous_point, fill_anchor_point);
    coverage += geometry.triangleArea(.{ .x = 1.0, .y = point_right.y }, end_point, fill_anchor_point);
    if (is_debug and coverage > coverage_weight) {
        std.log.warn("Coverage set to 1.0 from {d} in g_aa next pixel", .{coverage});
    }
    coverage = @min(coverage, coverage_weight);
    pixel_writer.add(
        .{ .x = pixel_end, .y = pixel_y },
        if (invert) coverage_weight - coverage else coverage,
    );
}

fn rasterize2Point(
    pair: YIntersectionPair,
    y_index: usize,
    y_low: f64,
    y_high: f64,
    y_intersect: f64,
    subtract: bool,
    segments: []OutlineSegment,
    pixel_writer: anytype,
) void {
    const outline_index = pair.start.outline_index;
    std.debug.assert(outline_index == pair.end.outline_index);

    var sampler = OutlineSamplerUnbounded{
        .segments = segments,
        .t_start = pair.start.t,
        .t_max = @floatFromInt(f64, segments.len),
        .samples_per_pixel = 3,
        .t_current = undefined,
        .t_direction = undefined,
        .t_increment = undefined,
    };
    sampler.init(pair.end.t);

    const coverage_weight = y_high - y_low;
    const pixel_start = @intFromFloat(usize, @floor(pair.start.x_intersect));
    const pixel_end = @intFromFloat(usize, @floor(pair.end.x_intersect));

    std.debug.assert(pixel_start <= pixel_end);
    var pixel_x = pixel_start;

    var fill_anchor_point = Point(f64){
        .x = 1.0,
        .y = y_intersect,
    };
    var previous_sampled_point = Point(f64){
        .x = pair.start.x_intersect - @floatFromInt(f64, pixel_start),
        .y = y_intersect,
    };

    var coverage: f64 = 0.0;
    var origin = Point(f64){
        .x = @floatFromInt(f64, pixel_start),
        .y = @floatFromInt(f64, y_index),
    };

    while (true) {
        var sampled_point = sampler.nextSample(origin);
        //
        // It is possible that outline will cross into right pixel briefy before going back
        //
        if (sampled_point.x < 0.0) {
            sampled_point.x = 0.0;
        }

        if (sampled_point.x >= 1.0) {
            // We've sampled into the neigbouring right pixel.
            // Interpolate a pixel on the rightside and then set the pixel value.
            std.debug.assert(sampled_point.x > previous_sampled_point.x);
            const interpolated_point = geometry.interpolateBoundryPoint(previous_sampled_point, sampled_point);
            coverage += geometry.triangleArea(interpolated_point, previous_sampled_point, fill_anchor_point);

            //
            // Finish coverage
            //
            coverage += geometry.triangleArea(fill_anchor_point, interpolated_point, .{ .x = 1.0, .y = fill_anchor_point.y });

            if (coverage > coverage_weight) {
                if (is_debug)
                    std.log.warn("Clamping coverage from {d}", .{coverage});
                coverage = coverage_weight;
            }
            std.debug.assert(coverage >= 0.0);
            std.debug.assert(coverage <= coverage_weight);
            if (subtract) {
                pixel_writer.sub(
                    .{ .x = pixel_x, .y = y_index },
                    coverage,
                );
            } else {
                pixel_writer.add(
                    .{ .x = pixel_x, .y = y_index },
                    coverage,
                );
            }

            //
            // Adjust for next pixel
            //
            pixel_x += 1;
            origin.x = @floatFromInt(f64, pixel_x);
            previous_sampled_point = .{ .x = 0.0, .y = interpolated_point.y };
            fill_anchor_point.x = 0.0;

            if (sampled_point.y > y_high or sampled_point.y < y_low) {
                break;
            }

            sampled_point.x -= 1.0;
            std.debug.assert(sampled_point.x >= 0.0);
            std.debug.assert(sampled_point.x <= 1.0);

            //
            // Calculate first coverage for next pixel
            //
            coverage = geometry.triangleArea(sampled_point, previous_sampled_point, fill_anchor_point);
            continue;
        }

        if (sampled_point.y > y_high or sampled_point.y < y_low) {
            break;
        }

        coverage += geometry.triangleArea(sampled_point, previous_sampled_point, fill_anchor_point);

        std.debug.assert(coverage >= 0.0);
        std.debug.assert(coverage <= coverage_weight);
        previous_sampled_point = sampled_point;
    }

    if (is_debug and pixel_x != pixel_end) {
        std.log.warn("2pt: Not ending on last pixel. Expected {d} actual {d}", .{
            pixel_end,
            pixel_x,
        });
    }
    const end_point = Point(f64){
        .x = pair.end.x_intersect - @floatFromInt(f64, pixel_end),
        .y = y_intersect,
    };
    assertNormalized(end_point);

    coverage += geometry.triangleArea(end_point, previous_sampled_point, fill_anchor_point);
    if (is_debug and coverage > coverage_weight) {
        std.log.warn("Coverage set to 1.0 from {d} in g_aa next pixel", .{coverage});
    }
    coverage = @min(coverage, coverage_weight);
    if (subtract) {
        pixel_writer.sub(
            .{ .x = pixel_x, .y = y_index },
            coverage,
        );
    } else {
        pixel_writer.add(
            .{ .x = pixel_x, .y = y_index },
            coverage,
        );
    }
}

/// Takes a list of upper and lower intersections, and groups them into
/// 2 or 4 point intersections that makes it easy for the rasterizer
fn combineIntersectionLists(
    uppers: []const YIntersection,
    lowers: []const YIntersection,
    base_scanline: f64,
    outlines: []const Outline,
) !IntersectionConnectionList {
    //
    // Lines are connected if:
    //   1. Connected by T
    //   2. Middle t lies within scanline
    //   3. Part of the same outline
    //
    const intersections = IntersectionList.makeFromSeperateScanlines(uppers, lowers);

    const total_count: usize = uppers.len + lowers.len;
    std.debug.assert(intersections.length() == total_count);

    // TODO: Hard coded size
    //       Replace [2]usize with struct
    var pair_list: [10][2]usize = undefined;
    var pair_count: usize = 0;
    {
        var matched = [1]bool{false} ** 32;
        for (intersections.toSlice(), 0..) |intersection, intersection_i| {
            if (intersection_i == intersections.length() - 1) break;
            if (matched[intersection_i] == true) continue;
            const intersection_outline_index = intersection.outline_index;
            const intersection_outline = outlines[intersection_outline_index];
            const outline_max_t = @floatFromInt(f64, intersection_outline.segments.len);
            var other_i: usize = intersection_i + 1;
            var smallest_t_diff = std.math.floatMax(f64);
            var best_match_index: ?usize = null;
            while (other_i < total_count) : (other_i += 1) {
                if (matched[other_i] == true) continue;
                const other_intersection = intersections.at(other_i);
                if (intersection.t == other_intersection.t) continue;
                const other_intersection_outline_index = other_intersection.outline_index;
                if (other_intersection_outline_index != intersection_outline_index) continue;
                const within_scanline = blk: {
                    const middle_t = minTMiddle(intersection.t, other_intersection.t, outline_max_t);
                    // TODO: Specialized implementation of samplePoint just for y value
                    const sample_point = intersection_outline.samplePoint(middle_t);
                    const relative_y = sample_point.y - base_scanline;
                    break :blk relative_y >= 0.0 and relative_y <= 1.0;
                };
                if (!within_scanline) {
                    continue;
                }
                const is_t_connected = intersections.isTConnected(intersection_i, other_i, outline_max_t);
                if (is_t_connected) {
                    // TODO: This doesn't take into account wrapping
                    const t_diff = @fabs(intersection.t - other_intersection.t);
                    if (t_diff < smallest_t_diff) {
                        smallest_t_diff = t_diff;
                        best_match_index = other_i;
                    }
                }
            }
            if (best_match_index) |match_index| {
                const match_intersection = intersections.at(match_index);
                const swap = intersection.x_intersect > match_intersection.x_intersect;
                pair_list[pair_count][0] = if (swap) match_index else intersection_i;
                pair_list[pair_count][1] = if (swap) intersection_i else match_index;
                matched[match_index] = true;
                matched[intersection_i] = true;
                pair_count += 1;
            } else {
                std.debug.assert(false);
            }
        }
    }

    // TODO: Remove paranoa check
    const min_pair_count = @divTrunc(total_count, 2);
    std.debug.assert(pair_count >= min_pair_count);

    var connection_list = IntersectionConnectionList{ .buffer = undefined, .len = 0 };
    {
        var matched = [1]bool{false} ** 32;
        var i: usize = 0;
        while (i < pair_count) : (i += 1) {
            if (matched[i]) continue;
            const index_start = pair_list[i][0];
            const index_end = pair_list[i][1];
            const start = intersections.at(index_start);
            const end = intersections.at(index_end);
            std.debug.assert(start.x_intersect <= end.x_intersect);
            const start_is_upper = intersections.isUpper(index_start);
            const end_is_upper = intersections.isUpper(index_end);
            if (start_is_upper == end_is_upper) {
                const intersection_pair = YIntersectionPair{
                    .start = start,
                    .end = end,
                };
                if (start_is_upper) {
                    try connection_list.add(.{ .upper = intersection_pair, .lower = null });
                } else {
                    try connection_list.add(.{ .upper = null, .lower = intersection_pair });
                }
            } else {
                //
                // Pair touches both upper and lower scanlines; Find closing match
                // Match criteria:
                //   1. Also across both scanlines
                //   2. Has the most leftmost point
                //
                var x: usize = i + 1;
                const ref_x_intersect: f64 = @max(start.x_intersect, end.x_intersect);
                var smallest_x: f64 = std.math.floatMax(f64);
                var smallest_index_opt: ?usize = null;
                while (x < pair_count) : (x += 1) {
                    const comp_index_start = pair_list[x][0];
                    const comp_index_end = pair_list[x][1];
                    const comp_start_is_upper = intersections.isUpper(comp_index_start);
                    const comp_end_is_upper = intersections.isUpper(comp_index_end);
                    if (comp_start_is_upper == comp_end_is_upper) {
                        continue;
                    }

                    const comp_start = intersections.at(comp_index_start);
                    const comp_end = intersections.at(comp_index_end);
                    const comp_x = @min(comp_start.x_intersect, comp_end.x_intersect);
                    if (comp_x >= ref_x_intersect and comp_x < smallest_x) {
                        smallest_x = comp_x;
                        smallest_index_opt = x;
                    }
                }
                if (smallest_index_opt) |smallest_index| {
                    const match_pair = pair_list[smallest_index];
                    const match_start = intersections.at(match_pair[0]);
                    const match_end = intersections.at(match_pair[1]);
                    const match_start_is_upper = intersections.isUpper(match_pair[0]);
                    std.debug.assert(match_start.x_intersect <= match_end.x_intersect);

                    const upper_start = if (start_is_upper) start else end;
                    const upper_end = if (match_start_is_upper) match_start else match_end;
                    std.debug.assert(upper_start.x_intersect <= upper_end.x_intersect);

                    const lower_start = if (start_is_upper) end else start;
                    const lower_end = if (match_start_is_upper) match_end else match_start;
                    std.debug.assert(lower_start.x_intersect <= lower_end.x_intersect);

                    const upper = YIntersectionPair{
                        .start = upper_start,
                        .end = upper_end,
                    };
                    const lower = YIntersectionPair{
                        .start = lower_start,
                        .end = lower_end,
                    };
                    try connection_list.addFront(.{ .upper = upper, .lower = lower });
                    matched[smallest_index] = true;
                } else {
                    return error.FailedToFindMatch;
                }
            }
        }
    }

    if (connection_list.len > 0) {
        var i: usize = 0;
        outer: while (i < connection_list.len) : (i += 1) {
            const connection = connection_list.buffer[i];
            if (connection.upper == null or connection.lower == null) {
                break;
            }
            const start_x = @min(connection.lower.?.start.x_intersect, connection.upper.?.start.x_intersect);
            const end_x = @max(connection.lower.?.end.x_intersect, connection.upper.?.end.x_intersect);
            var x: usize = i + 1;
            while (x < connection_list.len) : (x += 1) {
                const other_connection = connection_list.buffer[x];
                if (other_connection.upper != null and other_connection.lower != null) {
                    continue;
                }
                const comp_x = blk: {
                    if (other_connection.lower) |lower| break :blk lower.start.x_intersect;
                    if (other_connection.upper) |upper| break :blk upper.start.x_intersect;
                    unreachable;
                };
                if (comp_x > start_x and comp_x < end_x) {
                    connection_list.buffer[x].flags.invert_coverage = true;
                    continue :outer;
                }
            }
        }
    }

    // Make sure all 2 point intersections are at the end
    std.sort.sort(IntersectionConnection, connection_list.toSliceMut(), {}, intersectionConnectionLessThan);

    return connection_list;
}

fn intersectionConnectionLessThan(_: void, lhs: IntersectionConnection, rhs: IntersectionConnection) bool {
    return if ((lhs.lower != null and lhs.upper != null) and (rhs.lower == null or rhs.upper == null)) true else false;
}

fn calculateHorizontalLineIntersections(scanline_y: f64, outlines: []Outline) !YIntersectionList {
    var intersection_list = YIntersectionList{ .len = 0, .buffer = undefined };
    for (outlines, 0..) |outline, outline_i| {
        if (!outline.withinYBounds(scanline_y)) continue;
        const max_t = @floatFromInt(f64, outline.segments.len);
        for (outline.segments, 0..) |segment, segment_i| {
            if (!segment.withinYBounds(scanline_y)) continue;
            const point_a = segment.from;
            const point_b = segment.to;
            if (segment.isCurve()) {
                const control_point = segment.control;
                const bezier = geometry.BezierQuadratic{ .a = point_a, .b = point_b, .control = control_point };
                const optional_intersection_points = geometry.quadraticBezierPlaneIntersections(bezier, scanline_y);
                if (optional_intersection_points[0]) |first_intersection| {
                    {
                        const intersection = YIntersection{
                            .outline_index = @intCast(u32, outline_i),
                            .x_intersect = first_intersection.x,
                            .t = @mod(@floatFromInt(f64, segment_i) + first_intersection.t, max_t),
                        };
                        try intersection_list.add(intersection);
                    }
                    if (optional_intersection_points[1]) |second_intersection| {
                        const x_diff_threshold = 0.001;
                        if (@fabs(second_intersection.x - first_intersection.x) > x_diff_threshold) {
                            const t_second = @mod(@floatFromInt(f64, segment_i) + second_intersection.t, max_t);
                            const intersection = YIntersection{
                                .outline_index = @intCast(u32, outline_i),
                                .x_intersect = second_intersection.x,
                                .t = @mod(t_second, max_t),
                            };
                            try intersection_list.add(intersection);
                        }
                    }
                } else if (optional_intersection_points[1]) |second_intersection| {
                    try intersection_list.add(.{
                        .outline_index = @intCast(u32, outline_i),
                        .x_intersect = second_intersection.x,
                        .t = @mod(@floatFromInt(f64, segment_i) + second_intersection.t, max_t),
                    });
                }
                continue;
            }

            if (point_a.y == point_b.y) {
                continue;
            }

            const interp_t = blk: {
                if (scanline_y == 0) {
                    if (point_a.y == 0.0) break :blk 0.0;
                    if (point_b.y == 0.0) break :blk 1.0;
                    unreachable;
                }
                // TODO: Add comment. Another varient of lerp func
                // a - (b - a) * t = p`
                // p - a = (b - a) * t
                // (p - a) / (b - a) = t
                break :blk (scanline_y - point_a.y) / (point_b.y - point_a.y);
            };
            std.debug.assert(interp_t >= 0.0 and interp_t <= 1.0);
            const t = @mod(@floatFromInt(f64, segment_i) + interp_t, max_t);
            if (point_a.x == point_b.x) {
                try intersection_list.add(.{
                    .outline_index = @intCast(u32, outline_i),
                    .x_intersect = point_a.x,
                    .t = t,
                });
            } else {
                const x_diff = point_b.x - point_a.x;
                const x_intersect = point_a.x + (x_diff * interp_t);
                try intersection_list.add(.{
                    .outline_index = @intCast(u32, outline_i),
                    .x_intersect = x_intersect,
                    .t = t,
                });
            }
        }
    }

    // TODO: Verify this always has to be true, or remove assert
    std.debug.assert(intersection_list.len % 2 == 0);

    if (is_debug) {
        for (intersection_list.toSlice()) |intersection| {
            std.debug.assert(intersection.outline_index >= 0);
            std.debug.assert(intersection.outline_index < outlines.len);
            const max_t = @floatFromInt(f64, outlines[intersection.outline_index].segments.len);
            std.debug.assert(intersection.t >= 0.0);
            std.debug.assert(intersection.t < max_t);
        }
    }

    // Sort by x_intersect ascending
    var step: usize = 1;
    while (step < intersection_list.len) : (step += 1) {
        const key = intersection_list.buffer[step];
        var x = @intCast(i64, step) - 1;
        while (x >= 0 and intersection_list.buffer[@intCast(usize, x)].x_intersect > key.x_intersect) : (x -= 1) {
            intersection_list.buffer[@intCast(usize, x) + 1] = intersection_list.buffer[@intCast(usize, x)];
        }
        intersection_list.buffer[@intCast(usize, x + 1)] = key;
    }

    if (is_debug) {
        for (intersection_list.buffer[0..intersection_list.len]) |intersection| {
            std.debug.assert(intersection.outline_index >= 0);
            std.debug.assert(intersection.outline_index < outlines.len);
            const max_t = @floatFromInt(f64, outlines[intersection.outline_index].segments.len);
            std.debug.assert(intersection.t >= 0.0);
            std.debug.assert(intersection.t < max_t);
        }
    }

    // TODO: This isn't very clean
    if (intersection_list.len == 2) {
        const a = intersection_list.buffer[0];
        const b = intersection_list.buffer[1];
        if (a.t == b.t) {
            if (is_debug)
                std.log.warn("Removing pair with same t", .{});
            intersection_list.len = 0;
        }
    }

    return intersection_list;
}

test "minTMiddle" {
    const expect = std.testing.expect;
    try expect(minTMiddle(0.2, 0.5, 1.0) == 0.35);
    try expect(minTMiddle(0.5, 0.4, 1.0) == 0.45);
    try expect(minTMiddle(0.8, 0.2, 1.0) == 0.0);
    try expect(minTMiddle(16.0, 2.0, 20.0) == 19.0);
}
