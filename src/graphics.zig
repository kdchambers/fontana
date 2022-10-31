// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

pub fn RGB(comptime BaseType: type) type {
    return packed struct {
        pub fn fromInt(r: u8, g: u8, b: u8) @This() {
            return .{
                .r = @intToFloat(BaseType, r) / 255.0,
                .g = @intToFloat(BaseType, g) / 255.0,
                .b = @intToFloat(BaseType, b) / 255.0,
            };
        }

        pub fn clear() @This() {
            return .{
                .r = 0,
                .g = 0,
                .b = 0,
            };
        }

        pub inline fn toRGBA(self: @This()) RGBA(BaseType) {
            return .{
                .r = self.r,
                .g = self.g,
                .b = self.b,
                .a = 1.0,
            };
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
    };
}

pub fn RGBA(comptime BaseType: type) type {
    return packed struct {
        pub fn fromInt(comptime IntType: type, r: IntType, g: IntType, b: IntType, a: IntType) @This() {
            return .{
                .r = @intToFloat(BaseType, r) / 255.0,
                .g = @intToFloat(BaseType, g) / 255.0,
                .b = @intToFloat(BaseType, b) / 255.0,
                .a = @intToFloat(BaseType, a) / 255.0,
            };
        }

        pub fn clear() @This() {
            return .{
                .r = 0,
                .g = 0,
                .b = 0,
                .a = 0,
            };
        }

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType,
    };
}
