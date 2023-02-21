const std = @import("std");
const build_options = @import("build_options");
const accord = @import("accord");
const frontend = @import("frontend.zig");

const Backend = @import("backends/backend.zig");
const Rectangle = frontend.Rectangle;

const AltState = enum {
    none,
    waiting,
    horizontal,
    vertical,
};

const ModState = struct {
    control: bool = false,
    alt: AltState = .none,
    shift: bool = false,

    pub fn any(self: ModState) bool {
        return self.control or self.alt != .none or self.shift;
    }
};

// TODO: reduce global state?
const State = struct {
    running: bool = true,
    selecting: bool = false,
    selection: frontend.Selection = undefined,
    hovered_rectangle: ?Rectangle = null,
    mod_state: ModState = ModState{},
    mouse_float_x: f64 = 0.0,
    mouse_float_y: f64 = 0.0,
    options: OptionsType = undefined,
    rectangles: []Rectangle = undefined,
};

const EventResult = enum { running, finished, cancel };

const raw_allocator = std.heap.raw_c_allocator;

// NOTE: the order these are in is the order that each backend
// will be tried when not one is not manually supplied
const backends: []const Backend = value: {
    const X11Impl = @import("backends/xcb.zig");
    const WaylandImpl = @import("backends/wayland.zig");

    var result: []const Backend = &.{};
    if (build_options.wayland_backend) {
        result = result ++ &[1]Backend{Backend{
            .name = "wayland",
            .init = WaylandImpl.init,
            .updateEvents = WaylandImpl.updateEvents,
            .warpPointer = WaylandImpl.warpPointer,
            .clearDraw = WaylandImpl.clearDraw,
            .drawLines = WaylandImpl.drawLines,
            .commitChanges = WaylandImpl.commitChanges,
            .deinit = WaylandImpl.deinit,
        }};
    }

    if (build_options.x11_backend) {
        result = result ++ &[1]Backend{Backend{
            .name = "x11",
            .init = X11Impl.init,
            .updateEvents = X11Impl.updateEvents,
            .warpPointer = X11Impl.warpPointer,
            .clearDraw = X11Impl.clearDraw,
            .drawLines = X11Impl.drawLines,
            .commitChanges = X11Impl.commitChanges,
            .generateRectangles = X11Impl.generateRectangles,
            .deinit = X11Impl.deinit,
        }};
    }

    break :value result;
};

var state = State{};

fn eventHandler(backend: Backend) !EventResult {
    try backend.updateEvents();

    while (frontend.event_queue.pop()) |event| {
        switch (event) {
            .mouse_button_pressed => |button| {
                if (button.value == .left and state.selection == .rectangle) {
                    state.selecting = true;
                    if (state.mod_state.any() and state.hovered_rectangle != null) {
                        const rectangle = state.hovered_rectangle.?;
                        state.selection = frontend.Selection.rectangle(
                            rectangle.x1,
                            rectangle.y1,
                            rectangle.x2,
                            rectangle.y2,
                        );
                        backend.warpPointer(
                            state.selection.rectangle.x2,
                            state.selection.rectangle.y2,
                        );
                        state.mouse_float_x = @intToFloat(f64, state.selection.rectangle.x2);
                        state.mouse_float_y = @intToFloat(f64, state.selection.rectangle.y2);
                    } else {
                        state.mouse_float_x = @intToFloat(f64, button.x);
                        state.mouse_float_y = @intToFloat(f64, button.y);
                        state.selection = frontend.Selection.rectangle(
                            button.x,
                            button.y,
                            button.x,
                            button.y,
                        );
                    }
                } else if (button.value == .right)
                    return .cancel;
            },

            .mouse_motion => |motion| {
                if (state.selecting) {
                    const rectangle = &state.selection.rectangle;
                    var relative_x = @intToFloat(f64, motion.x - rectangle.x2);
                    var relative_y = @intToFloat(f64, motion.y - rectangle.y2);

                    if (state.mod_state.alt == .waiting) {
                        const abs_x = @fabs(relative_x);
                        const abs_y = @fabs(relative_y);
                        if (abs_x > abs_y) {
                            state.mod_state.alt = .horizontal;
                        } else if (abs_y > abs_x) {
                            state.mod_state.alt = .vertical;
                        }
                    }

                    switch (state.mod_state.alt) {
                        .horizontal => relative_y = 0,
                        .vertical => relative_x = 0,
                        else => {},
                    }

                    if (state.mod_state.control) {
                        relative_x = relative_x / state.options.precision;
                        relative_y = relative_y / state.options.precision;
                    }

                    if (state.options.aspect[1] != 0.0) {
                        const aspect = state.options.aspect[0] / state.options.aspect[1];
                        if (aspect != 0.0 and !state.mod_state.shift) {
                            if (@fabs(relative_x) >= @fabs(relative_y)) {
                                relative_y = relative_x / aspect;
                            } else {
                                relative_x = relative_y * aspect;
                            }
                        }
                    }

                    state.mouse_float_x += relative_x;
                    state.mouse_float_y += relative_y;

                    if (state.mod_state.shift) {
                        rectangle.x1 += @floatToInt(i32, state.mouse_float_x) - rectangle.x2;
                        rectangle.y1 += @floatToInt(i32, state.mouse_float_y) - rectangle.y2;
                    }

                    rectangle.x2 = @floatToInt(i32, state.mouse_float_x);
                    rectangle.y2 = @floatToInt(i32, state.mouse_float_y);

                    if (motion.x != rectangle.x2 or motion.y != rectangle.y2)
                        backend.warpPointer(rectangle.x2, rectangle.y2);
                    backend.clearDraw();
                    backend.drawRectangle(
                        rectangle.x1,
                        rectangle.y1,
                        rectangle.x2,
                        rectangle.y2,
                        state.options.@"border-size".?,
                        state.options.@"border-color".?,
                    );
                    backend.commitChanges();
                } else {
                    state.hovered_rectangle = null;
                    backend.clearDraw();
                    var i: usize = state.rectangles.len;
                    while (i > 0) : (i -= 1) {
                        const rectangle = state.rectangles[i - 1];
                        if (rectangle.inBounds(motion.x, motion.y) and
                            (state.hovered_rectangle == null or
                            rectangle.getArea() < state.hovered_rectangle.?.getArea()))
                        {
                            state.hovered_rectangle = rectangle;
                        } else if (state.options.@"inactive-border-color".? > 0) {
                            backend.drawRectangle(
                                rectangle.x1,
                                rectangle.y1,
                                rectangle.x2,
                                rectangle.y2,
                                state.options.@"border-size".?,
                                state.options.@"inactive-border-color".?,
                            );
                        }
                    }
                    if (state.hovered_rectangle) |rectangle|
                        backend.drawRectangle(
                            rectangle.x1,
                            rectangle.y1,
                            rectangle.x2,
                            rectangle.y2,
                            state.options.@"border-size".?,
                            state.options.@"border-color".?,
                        );
                    backend.commitChanges();
                }
            },

            .mouse_button_released => |button| {
                if (button.value == .left) {
                    switch (state.selection) {
                        .point => {
                            var point = &state.selection.point;
                            point.x = button.x;
                            point.y = button.y;
                            if (state.hovered_rectangle) |rect|
                                point.label = rect.label;
                            return .finished;
                        },
                        .rectangle => {
                            if (state.selecting) {
                                var rectangle = &state.selection.rectangle;
                                if (rectangle.x1 == rectangle.x2 and rectangle.y1 == rectangle.y2) {
                                    if (state.hovered_rectangle) |rect| {
                                        rectangle.x1 = rect.x1;
                                        rectangle.y1 = rect.y1;
                                        rectangle.x2 = rect.x2;
                                        rectangle.y2 = rect.y2;
                                        rectangle.label = rect.label;
                                    }
                                }
                                return .finished;
                            }
                        },
                    }
                }
            },

            .mod_key_pressed => |mod_key| {
                switch (mod_key.value) {
                    .control => state.mod_state.control = true,
                    .alt => state.mod_state.alt = .waiting,
                    .shift => state.mod_state.shift = true,
                }
            },

            .mod_key_released => |mod_key| {
                switch (mod_key.value) {
                    .control => state.mod_state.control = false,
                    .alt => state.mod_state.alt = .none,
                    .shift => state.mod_state.shift = false,
                }
            },
        }
    }
    return .running;
}

const FormatValues = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    l: []const u8 = "",
};

fn getFormatValues() FormatValues {
    var result = FormatValues{};
    switch (state.selection) {
        .point => {
            const point = &state.selection.point;
            result.x = point.x;
            result.y = point.y;
            result.l = point.label;
        },
        .rectangle => {
            const rectangle = &state.selection.rectangle;
            const min_x = std.math.min(rectangle.x1, rectangle.x2);
            const min_y = std.math.min(rectangle.y1, rectangle.y2);
            const max_x = std.math.max(rectangle.x1, rectangle.x2);
            const max_y = std.math.max(rectangle.y1, rectangle.y2);
            result.x = min_x;
            result.y = min_y;
            result.w = max_x - min_x;
            result.h = max_y - min_y;
            result.l = rectangle.label;
        },
    }
    return result;
}

fn writeSelection(selection: frontend.Selection, writer: anytype, format: []const u8) !void {
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const char = format[i];
        switch (char) {
            '%' => {
                var formatter_len = try selection.writeValue(writer, format[i + 1 ..]);
                if (formatter_len > 0) {
                    i += formatter_len;
                } else {
                    try writer.writeByte(char);
                    i += 1;
                    if (i < format.len)
                        try writer.writeByte(format[i]);
                }
            },
            '\\' => {
                const parsed_escape = std.zig.string_literal.parseEscapeSequence(format, &i);
                try switch (parsed_escape) {
                    .success => |value| writer.writeIntNative(@TypeOf(value), value),
                    .failure => error.InvalidEscapeSequence,
                };
                // parseEscapeSequence moves i one past where it should be
                i -= 1;
            },
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('\n');
}

fn printHelp() void {
    const message =
        \\Usage: bento [FLAGS/OPTIONS]
        \\  A tool for making a selection on your screen and printing the details to stdout
        \\
        \\Flags/Options:
        \\  -h, --help
        \\   print this help and exit
        \\
        \\   -b, --backend BACKEND
        \\   manually select which backend to use
        \\   available values:
    ++ comptime value: {
        var result: []const u8 = " ";
        for (backends) |backend| {
            if (result.len == 1)
                result = result ++ backend.name
            else
                result = result ++ ", " ++ backend.name;
        }
        break :value result;
    } ++
        \\
        \\   default value: selected automatically
        \\
        \\  -m, --mode MODE
        \\    selection mode
        \\    available values: rectangle, point
        \\    default: rectangle
        \\
        \\  -p, --precision PRECISION
        \\    level of precision when holding the control key (higher value = slower cursor, must be > 1.0)
        \\    default: 5.0
        \\
        \\  -f, --format FORMAT
        \\    set output format
        \\    available values: %x, %y, %w, and %h for selection values, %l will print the label for the selected rectangle if applicable
        \\    environment variables: BENTO_RECTANGLE_FORMAT
        \\                           BENTO_POINT_FORMAT
        \\    default rectangle format: "%wx%h+%x+%y"
        \\    default point format: "%x %y"
        \\
        \\  -a, --aspect WIDTH:HEIGHT
        \\    make selection rectangles adhere to an aspect ratio
        \\    default: 0.0:0.0 (off)
        \\
        \\  -s, --border-size SIZE
        \\    set selection border size
        \\    environment variable: BENTO_BORDER_SIZE
        \\    default: 4
        \\
        \\  -c, --border-color HEX_COLOR
        \\    border color for selection and hovered rectangles
        \\    environment variable: BENTO_BORDER_COLOR
        \\    default: 420dab
        \\
        \\  -i, --inactive-border-color HEX_COLOR
        \\    border color for un-hovered rectangles
        \\    environment variable: BENTO_INACTIVE_BORDER_COLOR
        \\    default: none 
        \\
        \\  --force-default-rects
        \\    use piped rectangles with a backend's default rectangle generation
        \\    
        \\  --force-no-default-rects
        \\    disable a backend's default rectangle generation
        \\
    ++ value: {
        if (build_options.x11_backend) {
            break :value 
            \\
            \\X11 Specific Flags/Options:
            \\  --x11-wait
            \\    if the pointer is already captured by another program, wait for it to be free instead of failing
            \\
            ;
        } else break :value "";
    };
    std.io.getStdErr().writer().writeAll(message) catch {};
}

fn rectParseError(line: []const u8) error{RectParseError} {
    std.log.err("Unable to parse rectangle: {s}!", .{line});
    return error.RectParseError;
}

fn getRectangles(allocator: std.mem.Allocator, reader: anytype) ![]Rectangle {
    var rectangle_list = std.ArrayListUnmanaged(Rectangle){};
    while (try reader.readUntilDelimiterOrEofAlloc(
        allocator,
        '\n',
        std.math.maxInt(usize),
    )) |line| {
        defer allocator.free(line);
        var line_iterator = std.mem.tokenize(u8, line, " ");
        var xy_iterator = std.mem.split(
            u8,
            line_iterator.next() orelse return rectParseError(line),
            ",",
        );
        var wh_iterator = std.mem.split(
            u8,
            line_iterator.next() orelse return rectParseError(line),
            "x",
        );
        const parseInt = std.fmt.parseInt;
        var rectangle: Rectangle = undefined;
        rectangle.x1 = (parseInt(
            i32,
            xy_iterator.next() orelse return rectParseError(line),
            10,
        ) catch return rectParseError(line));
        rectangle.y1 = (parseInt(
            i32,
            xy_iterator.next() orelse return rectParseError(line),
            10,
        ) catch return rectParseError(line));
        rectangle.x2 = rectangle.x1 + (parseInt(
            i32,
            wh_iterator.next() orelse return rectParseError(line),
            10,
        ) catch return rectParseError(line));
        rectangle.y2 = rectangle.y1 + (parseInt(
            i32,
            wh_iterator.next() orelse return rectParseError(line),
            10,
        ) catch return rectParseError(line));
        rectangle.label = try allocator.dupe(u8, line_iterator.rest());
        try rectangle_list.append(allocator, rectangle);
    }
    rectangle_list.shrinkAndFree(allocator, rectangle_list.items.len);
    return rectangle_list.items;
}

const arguments: []const accord.Option = &(.{
    accord.option('h', "help", accord.Flag, {}, .{}),
    accord.option('b', "backend", ?[]const u8, null, .{}),
    accord.option('m', "mode", frontend.SelectionMode, .rectangle, .{}),
    accord.option('p', "precision", f64, 5.0, .{}),
    accord.option('f', "format", ?[]const u8, null, .{}),
    accord.option('a', "aspect", [2]f64, .{ 0.0, 0.0 }, .{ .array_delimiter = ":" }),
    accord.option('s', "border-size", ?u32, null, .{}),
    accord.option('c', "border-color", ?u32, null, .{ .radix = 16 }),
    accord.option('i', "inactive-border-color", ?u32, null, .{ .radix = 16 }),
    accord.option(0, "force-default-rects", accord.Flag, {}, .{}),
    accord.option(0, "force-no-default-rects", accord.Flag, {}, .{}),
} ++ value: {
    if (build_options.x11_backend) {
        break :value .{
            accord.option(0, "x11-wait", accord.Flag, {}, .{}),
        };
    } else {
        break :value .{};
    }
});
pub const OptionsType = accord.OptionStruct(arguments);

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    var arg_iterator = std.process.args();
    _ = arg_iterator.skip();

    var options = accord.parse(arguments, allocator, &arg_iterator) catch return 1;
    defer options.positionals.deinit(allocator);

    if (options.help) {
        printHelp();
        return 0;
    }

    if (options.precision <= 1.0) {
        std.log.err("Precision level must be greater than 1!", .{});
        return 1;
    }
    if (options.aspect[0] != 0.0 and options.aspect[1] == 0.0) {
        std.log.err("Denominator of aspect ratio cannot be 0!", .{});
        return 1;
    }

    state.selection = frontend.Selection.init(options.mode);

    const default_border_size: u32 = 4;
    const border_size: u32 = if (options.@"border-size") |size|
        size
    else if (std.os.getenv("BENTO_BORDER_SIZE")) |string|
        std.fmt.parseInt(u32, string, 0) catch default_border_size
    else
        default_border_size;
    options.@"border-size" = border_size;

    const default_border_color: u32 = 0xff420dab;
    var border_color = if (options.@"border-color") |color|
        color
    else if (std.os.getenv("BENTO_BORDER_COLOR")) |string|
        std.fmt.parseInt(u32, std.mem.trimLeft(u8, string, "#"), 16) catch default_border_color
    else
        default_border_color;
    if (border_color & 0xff000000 == 0)
        border_color |= 0xff000000;
    options.@"border-color" = border_color;

    const default_inactive_border_color: ?u32 = 0xff210655;
    var inactive_border_color = if (options.@"inactive-border-color") |color|
        color
    else if (std.os.getenv("BENTO_INACTIVE_BORDER_COLOR")) |string|
        std.fmt.parseInt(u32, std.mem.trimLeft(u8, string, "#"), 16) catch default_inactive_border_color
    else
        default_inactive_border_color;
    if (inactive_border_color) |*color| {
        if (color.* & 0xff000000 == 0)
            color.* |= 0xff000000;
    } else inactive_border_color = 0;
    options.@"inactive-border-color" = inactive_border_color;

    state.options = options;

    const stdin = std.io.getStdIn();
    const pipe_exists = !std.os.isatty(stdin.handle);

    if (pipe_exists) {
        state.rectangles = try getRectangles(allocator, stdin.reader());
    }

    // TODO: add error messages inside each backend init so people know why it failed
    var backend: Backend = undefined;
    if (options.backend) |backend_name| {
        for (backends) |b| {
            if (std.ascii.eqlIgnoreCase(b.name, backend_name)) {
                b.init(options) catch {
                    std.log.err("Failed to initialize backend: {s}!", .{backend_name});
                    return 1;
                };
                backend = b;
                break;
            }
        } else {
            std.log.err("Could not find backend: {s}!", .{backend_name});
            return 1;
        }
    } else {
        for (backends) |b| {
            if (b.init(options)) {
                backend = b;
                break;
            } else |_| {}
        } else {
            std.log.err("Could not successfully start any backend!", .{});
            return 1;
        }
    }
    defer backend.deinit();

    if (!options.@"force-no-default-rects") {
        if (backend.generateRectangles) |generateRectangles| {
            if (state.rectangles.len == 0) {
                state.rectangles = try generateRectangles(allocator);
            } else if (options.@"force-default-rects") {
                const default_rects = try generateRectangles(allocator);
                const original_length = state.rectangles.len;
                if (!allocator.resize(state.rectangles, original_length + default_rects.len)) {
                    const pipe_rects = state.rectangles;
                    state.rectangles = try allocator.alloc(Rectangle, original_length + default_rects.len);
                    std.mem.copy(Rectangle, state.rectangles[0..pipe_rects.len], pipe_rects);
                    allocator.free(pipe_rects);
                }
                std.mem.copy(Rectangle, state.rectangles[original_length..], default_rects);
                allocator.free(default_rects);
            }
        }
    }

    defer if (state.rectangles.len > 0) {
        for (state.rectangles) |rect| {
            allocator.free(rect.label);
        }
        allocator.free(state.rectangles);
    };

    if (options.@"inactive-border-color".? > 0) {
        for (state.rectangles) |rectangle| {
            backend.drawRectangle(
                rectangle.x1,
                rectangle.y1,
                rectangle.x2,
                rectangle.y2,
                options.@"border-size".?,
                options.@"inactive-border-color".?,
            );
        }
    }
    backend.commitChanges();

    frontend.event_queue = frontend.EventQueue.init(allocator);

    while (true) switch (try eventHandler(backend)) {
        .running => continue,
        .finished => break,
        .cancel => return 1,
    };

    const format = options.format orelse state.selection.defaultFormat();
    const writer = std.io.getStdOut().writer();
    try writeSelection(state.selection, writer, format);

    return 0;
}
