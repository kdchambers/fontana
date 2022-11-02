// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const Point = geometry.Point;

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

        pub fn toSlice(self: @This()) []const BaseType {
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

    inline fn toSlice(self: @This()) []const YIntersection {
        const start_index = if (self.upper_index_start < self.lower_index_start) self.upper_index_start else self.lower_index_start;
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
            for (slice) |other, other_i| {
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
        for (slice) |other, other_i| {
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

pub const Outline = struct {
    segments: []OutlineSegment,

    pub fn samplePoint(self: @This(), t: f64) Point(f64) {
        const t_floored: f64 = @floor(t);
        const segment_index = @floatToInt(usize, t_floored);
        std.debug.assert(segment_index < self.segments.len);
        return self.segments[segment_index].sample(t - t_floored);
    }
};

pub const OutlineSegment = struct {
    const null_control: f64 = std.math.floatMin(f64);

    from: Point(f64),
    to: Point(f64),
    control: Point(f64) = .{ .x = @This().null_control, .y = undefined },
    /// The t value that corresponds to 1 pixel of distance (approx)
    t_per_pixel: f64,

    pub inline fn isCurve(self: @This()) bool {
        return self.control.x != @This().null_control;
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

pub fn rasterize(allocator: std.mem.Allocator, dimensions: geometry.Dimensions2D(u32), outlines: []Outline) ![*]graphics.RGBA(f32) {
    const bitmap_pixel_count = @intCast(usize, dimensions.width) * dimensions.height;
    var pixels = try allocator.alloc(graphics.RGBA(f32), bitmap_pixel_count);

    const null_pixel = graphics.RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
    std.mem.set(graphics.RGBA(f32), pixels, null_pixel);

    var scanline_lower: usize = 1;
    var intersections_upper = try calculateHorizontalLineIntersections(0, outlines);
    while (scanline_lower < dimensions.height) : (scanline_lower += 1) {
        const scanline_upper = scanline_lower - 1;
        const base_index = scanline_upper * dimensions.width;
        var intersections_lower = try calculateHorizontalLineIntersections(@intToFloat(f64, scanline_lower), outlines);
        if (intersections_lower.len > 0 or intersections_upper.len > 0) {
            const uppers = intersections_upper.buffer[0..intersections_upper.len];
            const lowers = intersections_lower.buffer[0..intersections_lower.len];
            const connected_intersections = try combineIntersectionLists(uppers, lowers, @intToFloat(f64, scanline_upper), outlines);
            const samples_per_pixel = 10;
            for (connected_intersections.buffer[0..connected_intersections.len]) |intersect_pair| {
                const invert_coverage = intersect_pair.flags.invert_coverage;
                const upper_opt = intersect_pair.upper;
                const lower_opt = intersect_pair.lower;
                if (upper_opt != null and lower_opt != null) {
                    //
                    // Ideal situation, we have two points on upper and lower scanline (4 in total)
                    // This forms a quadralateral in the range y (0.0 - 1.0) and x (0.0 - dimensions.width)
                    //
                    const upper = upper_opt.?;
                    const lower = lower_opt.?;
                    var fill_start: i32 = std.math.maxInt(i32);
                    var fill_end: i32 = 0;
                    {
                        //
                        // Start Anti-aliasing
                        //
                        const start_x = @min(upper.start.x_intersect, lower.start.x_intersect);
                        const end_x = @max(upper.start.x_intersect, lower.start.x_intersect);
                        const pixel_start = @floatToInt(usize, @floor(start_x));
                        const pixel_end = @floatToInt(usize, @floor(end_x));
                        const is_vertical = (@floor(start_x) == @floor(end_x));
                        if (is_vertical) {
                            //
                            // The upper and lower parts of the initial intersection lie on the same pixel.
                            // Coverage of pixel is the horizonal average between both points and there are
                            // no more pixels that need anti-aliasing calculated
                            //
                            const c = 255 - @floatToInt(u8, @divTrunc((@mod(start_x, 1.0) + @mod(end_x, 1.0)) * 255.0, 2.0));
                            std.debug.assert(c <= 255);
                            std.debug.assert(c >= 0);
                            pixels[pixel_start + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                        } else {
                            const starts_upper = if (upper.start.x_intersect < lower.start.x_intersect) true else false;
                            const start_fill_anchor_point = Point(f64){ .x = 1.0, .y = if (starts_upper) 1.0 else 0.0 };
                            var entry_point = Point(f64){ .x = start_x - @floor(start_x), .y = start_fill_anchor_point.y };
                            var last_point = Point(f64){ .x = end_x - @intToFloat(f64, pixel_start), .y = 1.0 - start_fill_anchor_point.y };
                            {
                                const exit_point = geometry.interpolateBoundryPoint(entry_point, last_point);
                                const c = @floatToInt(u8, @floor(255.0 * geometry.triangleArea(entry_point, exit_point, start_fill_anchor_point)));
                                pixels[pixel_start + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                                entry_point = Point(f64){ .x = 0.0, .y = exit_point.y };
                            }
                            std.debug.assert(entry_point.x >= 0.0);
                            std.debug.assert(entry_point.x <= 1.0);
                            var i = pixel_start + 1;
                            while (i < pixel_end) : (i += 1) {
                                last_point.x = end_x - @intToFloat(f64, i);
                                const exit_point = geometry.interpolateBoundryPoint(entry_point, last_point);
                                const c = (@floatToInt(u8, (255.0 * (entry_point.y + exit_point.y)) / 2.0));
                                std.debug.assert(c <= 255);
                                std.debug.assert(c >= 0);
                                pixels[i + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                                entry_point = Point(f64){ .x = 0.0, .y = exit_point.y };
                            }
                            const end_fill_anchor_point = Point(f64){
                                .x = 1.0,
                                .y = 1.0 - start_fill_anchor_point.x,
                            };
                            last_point.x = end_x - @floor(end_x);
                            std.debug.assert(i == pixel_end);
                            const c = 255 - @floatToInt(u8, @floor(255.0 * geometry.triangleArea(entry_point, last_point, end_fill_anchor_point)));
                            std.debug.assert(c <= 255);
                            std.debug.assert(c >= 0);
                            pixels[i + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                        }
                        fill_start = @floatToInt(i32, @floor(end_x)) + 1;
                    }
                    {
                        //
                        // End Anti-aliasing
                        //
                        const start_x = @min(upper.end.x_intersect, lower.end.x_intersect);
                        const end_x = @max(upper.end.x_intersect, lower.end.x_intersect);
                        const pixel_start = @floatToInt(usize, @floor(start_x));
                        const pixel_end = @floatToInt(usize, @floor(end_x));
                        const is_vertical = (@floor(start_x) == @floor(end_x));
                        if (is_vertical) {
                            const c = @floatToInt(u8, @divTrunc((@mod(start_x, 1.0) + @mod(end_x, 1.0)) * 255.0, 2.0));
                            std.debug.assert(c <= 255);
                            std.debug.assert(c >= 0);
                            pixels[pixel_start + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                        } else {
                            const starts_upper = if (upper.end.x_intersect < lower.end.x_intersect) true else false;
                            const start_fill_anchor_point = Point(f64){ .x = 1.0, .y = if (starts_upper) 1.0 else 0.0 };
                            var entry_point = Point(f64){ .x = start_x - @floor(start_x), .y = start_fill_anchor_point.y };
                            var last_point = Point(f64){ .x = end_x - @intToFloat(f64, pixel_start), .y = 1.0 - start_fill_anchor_point.y };
                            {
                                const exit_point = geometry.interpolateBoundryPoint(entry_point, last_point);
                                const c = 255 - @floatToInt(u8, @floor(255.0 * geometry.triangleArea(entry_point, exit_point, start_fill_anchor_point)));
                                pixels[pixel_start + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                                entry_point = Point(f64){ .x = 0.0, .y = exit_point.y };
                            }
                            var i = pixel_start + 1;
                            while (i < pixel_end) : (i += 1) {
                                last_point.x = end_x - @intToFloat(f64, i);
                                const exit_point = geometry.interpolateBoundryPoint(entry_point, last_point);
                                const c = 255 - (@floatToInt(u8, (255.0 * (entry_point.y + exit_point.y)) / 2.0));
                                std.debug.assert(c <= 255);
                                std.debug.assert(c >= 0);
                                pixels[i + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                                entry_point = Point(f64){ .x = 0.0, .y = exit_point.y };
                            }
                            const end_fill_anchor_point = Point(f64){
                                .x = 1.0,
                                .y = 1.0 - start_fill_anchor_point.x,
                            };
                            last_point.x = end_x - @floor(end_x);
                            std.debug.assert(i == pixel_end);
                            const c = @floatToInt(u8, @floor(255.0 * geometry.triangleArea(entry_point, last_point, end_fill_anchor_point)));
                            std.debug.assert(c <= 255);
                            std.debug.assert(c >= 0);
                            pixels[i + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                        }
                        fill_end = @floatToInt(i32, @floor(start_x)) - 1;
                    }
                    //
                    // Inner fill
                    //
                    var i: usize = @intCast(usize, fill_start);
                    while (i <= @intCast(usize, fill_end)) : (i += 1) {
                        pixels[i + base_index] = graphics.RGBA(f32).fromInt(u8, 255, 255, 255, 255);
                    }
                } else {
                    //
                    // We only have a upper or lower scanline
                    //
                    std.debug.assert(lower_opt == null or upper_opt == null);

                    const is_upper = (lower_opt == null);
                    const pair = if (is_upper) upper_opt.? else lower_opt.?;
                    const outline_index = pair.start.outline_index;
                    std.debug.assert(outline_index == pair.end.outline_index);

                    const outline = outlines[outline_index];
                    const sample_t_max = @intToFloat(f64, outlines[outline_index].segments.len);

                    const pixel_start = @floatToInt(usize, @floor(pair.start.x_intersect));
                    const pixel_end = @floatToInt(usize, @floor(pair.end.x_intersect));
                    std.debug.assert(pixel_start <= pixel_end);
                    const pixel_count: usize = pixel_end - pixel_start;

                    var pixel_x = pixel_start;
                    if (pixel_count == 0) {
                        // TODO
                        const c = 255.0;
                        pixels[pixel_x + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                        continue;
                    }

                    const samples_to_take: usize = pixel_count * samples_per_pixel;
                    const sample_t_start = pair.start.t;
                    const sample_t_end = pair.end.t;

                    //
                    // These need to be calculated based on whether which direction (forward / reverse)
                    // is most suitable (I.e Closest)
                    //
                    var sample_t_length: f64 = undefined;
                    var sample_t_increment: f64 = undefined;

                    if (sample_t_start < sample_t_end) {
                        const forward = sample_t_end - sample_t_start;
                        const backward = sample_t_start + (sample_t_max - sample_t_end);
                        if (forward < backward) {
                            sample_t_length = forward;
                            sample_t_increment = forward / @intToFloat(f64, samples_to_take);
                        } else {
                            sample_t_length = backward;
                            sample_t_increment = -backward / @intToFloat(f64, samples_to_take);
                        }
                    } else {
                        const forward = sample_t_end + (sample_t_max - sample_t_start);
                        const backward = sample_t_start - sample_t_end;
                        if (forward < backward) {
                            sample_t_length = forward;
                            sample_t_increment = forward / @intToFloat(f64, samples_to_take);
                        } else {
                            sample_t_length = backward;
                            sample_t_increment = -backward / @intToFloat(f64, samples_to_take);
                        }
                    }

                    std.debug.assert(sample_t_length <= (sample_t_max / 2.0));

                    //
                    // Paranoa checks
                    //
                    {
                        const predicted_end = @mod(sample_t_max + sample_t_start + (@intToFloat(f64, samples_to_take) * sample_t_increment), sample_t_max);
                        std.debug.assert(floatCompare(predicted_end, sample_t_end));
                    }
                    {
                        var end_sample_abs = @mod(sample_t_start + (sample_t_increment * @intToFloat(f64, samples_to_take)), sample_t_max);
                        if (end_sample_abs < 0.0) {
                            end_sample_abs += sample_t_max;
                        }
                        std.debug.assert(floatCompare(end_sample_abs, sample_t_end));
                    }

                    var fill_anchor_point = Point(f64){
                        .x = 1.0,
                        .y = if (is_upper) 1.0 else 0.0,
                    };
                    var previous_sampled_point = Point(f64){
                        .x = pair.start.x_intersect - @intToFloat(f64, pixel_start),
                        .y = if (is_upper) 1.0 else 0.0,
                    };
                    const base_y = @intToFloat(f64, scanline_upper);
                    var sample_index: usize = 1;
                    var current_sampled_point: Point(f64) = undefined;
                    var sample_t: f64 = undefined;
                    var coverage: f64 = 0.0;

                    while (sample_index < samples_to_take) : (sample_index += 1) {
                        current_sampled_point = blk: {
                            sample_t = sample_t_start + (sample_t_increment * @intToFloat(f64, sample_index));
                            // sample_t in this form can become negative or greater than sample_t_max
                            // Add sample_t_max and mod to wrap around within range
                            sample_t = @mod(sample_t + sample_t_max, sample_t_max);
                            std.debug.assert(sample_t >= 0.0);
                            std.debug.assert(sample_t <= sample_t_max);
                            const absolute_sampled_point = outline.samplePoint(sample_t);
                            break :blk Point(f64){
                                .x = absolute_sampled_point.x - @intToFloat(f64, pixel_x),
                                .y = absolute_sampled_point.y - base_y,
                            };
                        };
                        //
                        // It is possible that outline will cross into right pixel briefy before going back
                        //
                        if (current_sampled_point.x < 0.0) {
                            current_sampled_point.x = 0.0;
                        }
                        std.debug.assert(current_sampled_point.y >= 0.0);
                        std.debug.assert(current_sampled_point.y <= 1.0);

                        if (current_sampled_point.x >= 1.0) {
                            // We've sampled into the neigbouring right pixel.
                            // Interpolate a pixel on the rightside and then set the pixel value.
                            // std.log.info("Point crosses righthand pixel border. Interpolating endpoint", .{});
                            std.debug.assert(current_sampled_point.x > previous_sampled_point.x);
                            const interpolated_point = geometry.interpolateBoundryPoint(previous_sampled_point, current_sampled_point);
                            coverage += geometry.triangleArea(interpolated_point, previous_sampled_point, fill_anchor_point);
                            std.debug.assert(coverage >= 0.0);
                            std.debug.assert(coverage <= 1.0);
                            if (invert_coverage) {
                                coverage = 1.0 - coverage;
                            }
                            const c = @floatToInt(u8, coverage * 255.0);
                            pixels[pixel_x + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);

                            //
                            // Adjust for next pixel
                            //
                            previous_sampled_point = .{ .x = 0.0, .y = interpolated_point.y };
                            current_sampled_point.x -= 1.0;
                            std.debug.assert(current_sampled_point.x >= 0.0);
                            std.debug.assert(current_sampled_point.x <= 1.0);
                            fill_anchor_point.x = 0.0;
                            pixel_x += 1;
                            //
                            // Calculate first coverage for next pixel
                            //
                            coverage = geometry.triangleArea(current_sampled_point, previous_sampled_point, fill_anchor_point);
                            previous_sampled_point = current_sampled_point;
                        } else {
                            coverage += geometry.triangleArea(current_sampled_point, previous_sampled_point, fill_anchor_point);
                            std.debug.assert(coverage >= 0.0);
                            std.debug.assert(coverage <= 1.0);
                            previous_sampled_point = current_sampled_point;
                        }
                    }
                    //
                    // Rasterize last pixel
                    //
                    const interpolated_point = blk: {
                        std.debug.assert(current_sampled_point.x >= 0.0);
                        if (@floatToInt(usize, @floor(current_sampled_point.x)) == pixel_end) {
                            break :blk current_sampled_point;
                        }
                        // We actually need to interpolate a point between current_sampled_point and last point
                        const end_point = Point(f64){
                            .x = pair.end.x_intersect - @intToFloat(f64, pixel_end),
                            .y = if (is_upper) 1.0 else 0.0,
                        };
                        break :blk geometry.interpolateBoundryPoint(current_sampled_point, end_point);
                    };
                    coverage += geometry.triangleArea(interpolated_point, previous_sampled_point, fill_anchor_point);
                    if (invert_coverage) {
                        coverage = 1.0 - coverage;
                    }
                    const c = @floatToInt(u8, coverage * 255.0);
                    pixels[pixel_x + base_index] = graphics.RGBA(f32).fromInt(u8, c, c, c, 255);
                }
            }
        }
        intersections_upper = intersections_lower;
    }

    for (outlines) |*outline| {
        allocator.free(outline.segments);
    }

    return pixels.ptr;
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
        for (intersections.toSlice()) |intersection, intersection_i| {
            if (intersection_i == intersections.length() - 1) break;
            if (matched[intersection_i] == true) continue;
            const intersection_outline_index = intersection.outline_index;
            const intersection_outline = outlines[intersection_outline_index];
            const outline_max_t = @intToFloat(f64, intersection_outline.segments.len);
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
                    try connection_list.add(.{ .upper = upper, .lower = lower });
                    matched[smallest_index] = true;
                } else {
                    return error.FailedToFindMatch;
                }
            }
        }
    }
    return connection_list;
}

fn calculateHorizontalLineIntersections(scanline_y: f64, outlines: []Outline) !YIntersectionList {
    var intersection_list = YIntersectionList{ .len = 0, .buffer = undefined };
    for (outlines) |outline, outline_i| {
        for (outline.segments) |segment, segment_i| {
            const point_a = segment.from;
            const point_b = segment.to;
            const max_y = @max(point_a.y, point_b.y);
            const min_y = @min(point_a.y, point_b.y);
            if (segment.isCurve()) {
                const control_point = segment.control;
                const bezier = geometry.BezierQuadratic{ .a = point_a, .b = point_b, .control = control_point };
                const inflection_y = geometry.quadradicBezierInflectionPoint(bezier).y;
                const is_middle_higher = (inflection_y > max_y) and scanline_y > inflection_y;
                const is_middle_lower = (inflection_y < min_y) and scanline_y < inflection_y;
                if (is_middle_higher or is_middle_lower) {
                    continue;
                }
                const optional_intersection_points = geometry.quadraticBezierPlaneIntersections(bezier, scanline_y);
                if (optional_intersection_points[0]) |first_intersection| {
                    {
                        const intersection = YIntersection{
                            .outline_index = @intCast(u32, outline_i),
                            .x_intersect = first_intersection.x,
                            .t = @intToFloat(f64, segment_i) + first_intersection.t,
                        };
                        try intersection_list.add(intersection);
                    }
                    if (optional_intersection_points[1]) |second_intersection| {
                        const x_diff_threshold = 0.001;
                        if (@fabs(second_intersection.x - first_intersection.x) > x_diff_threshold) {
                            const t_second = @intToFloat(f64, segment_i) + second_intersection.t;
                            const intersection = YIntersection{
                                .outline_index = @intCast(u32, outline_i),
                                .x_intersect = second_intersection.x,
                                .t = t_second,
                            };
                            try intersection_list.add(intersection);
                        }
                    }
                } else if (optional_intersection_points[1]) |second_intersection| {
                    try intersection_list.add(.{
                        .outline_index = @intCast(u32, outline_i),
                        .x_intersect = second_intersection.x,
                        .t = @intToFloat(f64, segment_i) + second_intersection.t,
                    });
                }
                continue;
            }

            //
            // Outline segment is a line
            //
            std.debug.assert(max_y >= min_y);
            if (scanline_y > max_y or scanline_y < min_y) {
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
            const t = @intToFloat(f64, segment_i) + interp_t;
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

    for (intersection_list.toSlice()) |intersection| {
        std.debug.assert(intersection.outline_index >= 0);
        std.debug.assert(intersection.outline_index < outlines.len);
        const max_t = @intToFloat(f64, outlines[intersection.outline_index].segments.len);
        std.debug.assert(intersection.t >= 0.0);
        std.debug.assert(intersection.t < max_t);
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

    for (intersection_list.buffer[0..intersection_list.len]) |intersection| {
        std.debug.assert(intersection.outline_index >= 0);
        std.debug.assert(intersection.outline_index < outlines.len);
        const max_t = @intToFloat(f64, outlines[intersection.outline_index].segments.len);
        std.debug.assert(intersection.t >= 0.0);
        std.debug.assert(intersection.t < max_t);
    }

    // TODO: This isn't very clean
    if (intersection_list.len == 2) {
        const a = intersection_list.buffer[0];
        const b = intersection_list.buffer[1];
        if (a.t == b.t) {
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