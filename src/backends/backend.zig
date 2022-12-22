const std = @import("std");
const root = @import("root");
const frontend = @import("../frontend.zig");

const Allocator = std.mem.Allocator;
const Backend = @This();
const Point = frontend.Point;

name: []const u8,
init: *const fn (options: root.OptionsType) anyerror!void,
updateEvents: *const fn () anyerror!void,
warpPointer: *const fn (x: i32, y: i32) void,
clearDraw: *const fn () void,
drawLines: *const fn (points: []const frontend.Point, border_size: u32, border_color: u32) void,
commitChanges: *const fn () void,
generateRectangles: ?*const fn (allocator: Allocator) anyerror![]frontend.Rectangle = null,
deinit: *const fn () void,

pub fn drawRectangle(self: Backend, x1: i32, y1: i32, x2: i32, y2: i32, border_size: u32, border_color: u32) void {
    const half_border = @intCast(i32, border_size / 2);
    const left_border = half_border + @intCast(i32, border_size % 2);
    const right_border = half_border;

    const min_x = @min(x1, x2) - left_border;
    const min_y = @min(y1, y2) - left_border;
    const max_x = @max(x1, x2) + right_border;
    const max_y = @max(y1, y2) + right_border;

    self.drawLines(&.{ Point.new(min_x - right_border, min_y), Point.new(max_x + left_border, min_y) }, border_size, border_color);
    self.drawLines(&.{ Point.new(max_x, min_y), Point.new(max_x, max_y) }, border_size, border_color);
    self.drawLines(&.{ Point.new(max_x + left_border, max_y), Point.new(min_x - right_border, max_y) }, border_size, border_color);
    self.drawLines(&.{ Point.new(min_x, max_y), Point.new(min_x, min_y) }, border_size, border_color);
}
