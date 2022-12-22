const std = @import("std");

pub const SelectionMode = enum {
    rectangle,
    point,
};

fn defaultFormatFn(
    comptime env_var: []const u8,
    comptime default: []const u8,
) fn () []const u8 {
    return struct {
        pub fn generated() []const u8 {
            return std.os.getenv(env_var) orelse default;
        }
    }.generated;
}

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn new(x: i32, y: i32) Point {
        return Point{ .x = x, .y = y };
    }
};

pub const Rectangle = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    label: []const u8,

    pub fn new(x1: i32, y1: i32, x2: i32, y2: i32, label: []const u8) Rectangle {
        return Rectangle{
            .x1 = x1,
            .y1 = y1,
            .x2 = x2,
            .y2 = y2,
            .label = label,
        };
    }

    pub fn inBounds(self: Rectangle, x: i32, y: i32) bool {
        return x >= self.x1 and
            y >= self.y1 and
            x <= self.x2 and
            y <= self.y2;
    }

    pub fn getArea(self: Rectangle) u32 {
        return std.math.absCast(self.x2 - self.x1) *
            std.math.absCast(self.y2 - self.y1);
    }
};

pub const RectangleSelection = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    label: []const u8 = "",

    pub const Formatting = struct {
        pub const x = "getX";
        pub const y = "getY";
        pub const w = "getWidth";
        pub const h = "getHeight";
        pub const l = "label";
    };

    pub fn getX(self: RectangleSelection) i32 {
        return @min(self.x1, self.x2);
    }

    pub fn getY(self: RectangleSelection) i32 {
        return @min(self.y1, self.y2);
    }

    pub fn getWidth(self: RectangleSelection) u32 {
        return std.math.absCast(self.x2 - self.x1);
    }

    pub fn getHeight(self: RectangleSelection) u32 {
        return std.math.absCast(self.y2 - self.y1);
    }

    pub const defaultFormat = defaultFormatFn("BENTO_RECTANGLE_FORMAT", "%wx%h+%x+%y");
};

pub const PointSelection = struct {
    x: i32,
    y: i32,
    label: []const u8 = "",

    pub const Formatting = struct {
        pub const x = "x";
        pub const y = "y";
        pub const l = "label";
    };

    pub const defaultFormat = defaultFormatFn("BENTO_POINT_FORMAT", "%x %y");
};

pub const Selection = union(SelectionMode) {
    rectangle: RectangleSelection,
    point: PointSelection,

    pub fn init(mode: SelectionMode) Selection {
        return switch (mode) {
            .rectangle => rectangle(0, 0, 0, 0),
            .point => point(0, 0),
        };
    }

    pub fn rectangle(x1: i32, y1: i32, x2: i32, y2: i32) Selection {
        return Selection{
            .rectangle = .{
                .x1 = x1,
                .y1 = y1,
                .x2 = x2,
                .y2 = y2,
            },
        };
    }

    pub fn point(x: i32, y: i32) Selection {
        return Selection{
            .point = .{
                .x = x,
                .y = y,
            },
        };
    }

    /// return value is the length of the formatting label
    pub fn writeValue(self: Selection, writer: anytype, format: []const u8) !usize {
        return switch (self) {
            inline else => |selection| result: {
                const SelectionType = @TypeOf(selection);
                const Formatting = SelectionType.Formatting;

                // sort formatting fields from longest to shortest
                const sort = struct {
                    fn sort(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return lhs.len > rhs.len;
                    }
                }.sort;
                const decls = @typeInfo(Formatting).Struct.decls;
                comptime var formatting_fields: [decls.len][]const u8 = undefined;
                comptime for (decls) |declaration, i| {
                    formatting_fields[i] = declaration.name;
                };
                comptime std.sort.insertionSort([]const u8, formatting_fields[0..], {}, sort);

                inline for (formatting_fields) |f| {
                    if (std.mem.startsWith(u8, format, f)) {
                        const field = @field(Formatting, f);
                        const value = if (@hasField(SelectionType, field)) value: {
                            break :value @field(selection, field);
                        } else value: {
                            const function = @field(SelectionType, field);
                            break :value @call(.auto, function, .{selection});
                        };

                        const ValueType = @TypeOf(value);
                        const VTInfo = @typeInfo(ValueType);
                        // only types that exist are integers and strings
                        try switch (VTInfo) {
                            .Int => writer.print("{d}", .{value}),
                            .Pointer => writer.print("{s}", .{value}),
                            else => @compileError("Unsupported type!"),
                        };
                        break :result f.len;
                    }
                }
                break :result 0;
            },
        };
    }

    pub fn defaultFormat(self: Selection) []const u8 {
        return switch (self) {
            .rectangle => |r| @TypeOf(r).defaultFormat(),
            .point => |p| @TypeOf(p).defaultFormat(),
        };
    }
};

pub const MouseMotionEvent = struct {
    x: i32,
    y: i32,
    // window: u32,

    pub fn new(x: i32, y: i32) Event {
        return Event{ .mouse_motion = MouseMotionEvent{
            .x = x,
            .y = y,
        } };
    }
};

pub const MouseButton = enum(u8) {
    left,
    middle,
    right,
    _,
};

pub const MouseButtonEvent = struct {
    value: MouseButton,
    x: i32,
    y: i32,

    pub fn new(value: MouseButton, x: i32, y: i32, pressed: bool) Event {
        const data = MouseButtonEvent{
            .value = value,
            .x = x,
            .y = y,
        };
        return if (pressed)
            Event{ .mouse_button_pressed = data }
        else
            Event{ .mouse_button_released = data };
    }
};

pub const ModKey = enum {
    control,
    alt,
    shift,
};

pub const ModKeyEvent = struct {
    value: ModKey,

    pub fn new(value: ModKey, pressed: bool) Event {
        const data = ModKeyEvent{ .value = value };
        return if (pressed)
            Event{ .mod_key_pressed = data }
        else
            Event{ .mod_key_released = data };
    }
};

pub const Event = union(enum) {
    mouse_motion: MouseMotionEvent,
    mouse_button_pressed: MouseButtonEvent,
    mouse_button_released: MouseButtonEvent,
    mod_key_pressed: ModKeyEvent,
    mod_key_released: ModKeyEvent,
};

pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    queue: std.TailQueue(Event) = .{},

    pub const Node = std.TailQueue(Event).Node;

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        var node = try self.allocator.create(EventQueue.Node);
        errdefer self.allocator.destroy(node);
        node.* = EventQueue.Node{ .prev = null, .next = null, .data = event };
        self.queue.append(node);
    }

    pub fn pop(self: *EventQueue) ?Event {
        const node = self.queue.popFirst() orelse return null;
        const data = node.data;
        self.allocator.destroy(node);
        return data;
    }
};

pub var event_queue: EventQueue = undefined;
