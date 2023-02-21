const std = @import("std");
const root = @import("root");
const os = std.os;
const frontend = @import("../frontend.zig");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("xdg-output-unstable-v1-client-protocol.h");
    @cInclude("wlr-virtual-pointer-unstable-v1-client-protocol.h");
});

// TODO: https://bugaevc.gitbooks.io/writing-wayland-clients/content/beyond-the-black-square/cursors.html

const Errors = error{
    WaylandConnectionError,
    WaylandCantFindCompositor,
    WaylandSurfaceError,
    WaylandLayerShellError,
    WaylandShellSurfaceError,
    WaylandShmError,
    WaylandVirtualPointerManagerError,
    WaylandVirtualPointerError,
    WaylandCursorError,
    XkbContextError,
    CreateShmFileError,
};

const DamageRect = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,

    fn new(x1: i32, y1: i32, x2: i32, y2: i32) DamageRect {
        return DamageRect{
            .x1 = x1,
            .y1 = y1,
            .x2 = x2,
            .y2 = y2,
        };
    }
};

const Buffer = struct {
    width: i32,
    height: i32,
    data: []align(std.mem.page_size) u8,
    wl_buffer: *c.wl_buffer,
    clear_damage: DamageRect,
    draw_damage: DamageRect,

    pub fn toSlice(self: Buffer) []align(std.mem.page_size) u32 {
        return std.mem.bytesAsSlice(u32, self.data);
    }

    pub fn getIndex(self: Buffer, x: usize, y: usize) usize {
        return y * @intCast(usize, self.width) + x;
    }

    pub fn putPixel(self: *Buffer, x: i32, y: i32, value: u32) void {
        const index = self.getIndex(@intCast(usize, x), @intCast(usize, y));
        var slice = self.toSlice();
        if (slice[index] == value) return;

        slice[index] = value;

        self.clear_damage.x1 = @min(self.clear_damage.x1, x);
        self.clear_damage.x2 = @max(self.clear_damage.x2, x);
        self.clear_damage.y1 = @min(self.clear_damage.y1, y);
        self.clear_damage.y2 = @max(self.clear_damage.y2, y);

        self.draw_damage.x1 = @min(self.clear_damage.x1, x);
        self.draw_damage.x2 = @max(self.clear_damage.x2, x);
        self.draw_damage.y1 = @min(self.clear_damage.y1, y);
        self.draw_damage.y2 = @max(self.clear_damage.y2, y);
    }

    pub fn clear(self: *Buffer) void {
        if (self.clear_damage.x1 > self.clear_damage.x2) return;

        {
            var y: i32 = self.clear_damage.y1;
            while (y <= self.clear_damage.y2) : (y += 1) {
                {
                    var x: i32 = self.clear_damage.x1;
                    while (x <= self.clear_damage.x2) : (x += 1) {
                        const i = self.getIndex(@intCast(usize, x), @intCast(usize, y));
                        self.toSlice()[i] = 0;
                    }
                }
            }
        }

        c.wl_surface_attach(state.surface, self.wl_buffer, 0, 0);
        c.wl_surface_damage_buffer(
            state.surface,
            self.clear_damage.x1,
            self.clear_damage.y1,
            (self.clear_damage.x2 - self.clear_damage.x1) + 1,
            (self.clear_damage.y2 - self.clear_damage.y1) + 1,
        );
        self.clear_damage = DamageRect.new(self.width, self.height, 0, 0);
        self.draw_damage = DamageRect.new(self.width, self.height, 0, 0);
    }

    pub fn draw(self: *Buffer) void {
        if (self.draw_damage.x1 > self.draw_damage.x2) return;
        c.wl_surface_attach(state.surface, self.wl_buffer, 0, 0);
        c.wl_surface_damage_buffer(
            state.surface,
            self.draw_damage.x1,
            self.draw_damage.y1,
            (self.draw_damage.x2 - self.draw_damage.x1) + 1,
            (self.draw_damage.y2 - self.draw_damage.y1) + 1,
        );
        self.draw_damage = DamageRect.new(self.width, self.height, 0, 0);
    }
};

const MouseState = struct {
    time: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    left_click: bool = false,
    right_click: bool = false,
    motion_dirty: bool = false,
};

const State = struct {
    display: *c.wl_display,
    registry: ?*c.wl_registry,
    compositor: ?*c.wl_compositor,
    surface: *c.wl_surface,
    layer_shell: ?*c.zwlr_layer_shell_v1,
    layer_surface: *c.zwlr_layer_surface_v1,
    shm: ?*c.wl_shm,
    shm_fd: os.fd_t,
    buffer: ?Buffer,
    mouse: MouseState,
    cursor_theme: *c.wl_cursor_theme,
    cursor: *c.wl_cursor,
    cursor_image: *c.wl_cursor_image,
    cursor_surface: *c.wl_surface,
    virtual_pointer_manager: ?*c.zwlr_virtual_pointer_manager_v1,
    virtual_pointer: ?*c.zwlr_virtual_pointer_v1,
    xkb_context: *c.xkb_context,
    xkb_keymap: ?*c.xkb_keymap,
    xkb_state: ?*c.xkb_state,
};

var state: State = undefined;

fn createShm(size: usize) !os.fd_t {
    var retries: usize = 100;
    var fd: os.fd_t = -1;
    while (retries > 0) : (retries -= 1) {
        // TODO: better name stuff
        const name = "bento";
        fd = os.open(
            "/dev/shm/" ++ name,
            os.O.RDWR | os.O.CREAT | os.O.EXCL | os.O.NOFOLLOW | os.O.CLOEXEC,
            600,
        ) catch continue;
        try os.unlink("/dev/shm/" ++ name);
        break;
    } else return error.CreateShmFileError;
    errdefer os.close(fd);

    try os.ftruncate(fd, size);

    return fd;
}

pub fn init(_: root.OptionsType) !void {
    state.display = c.wl_display_connect(null) orelse return error.WaylandConnectionError;
    errdefer c.wl_display_disconnect(state.display);

    state.compositor = null;
    state.layer_shell = null;
    state.virtual_pointer_manager = null;
    state.xkb_keymap = null;
    // TODO: would there be any benefit to using a proper input seat
    //       to pass state around instead of using a global?
    state.mouse = .{};

    state.registry = c.wl_display_get_registry(state.display);
    errdefer c.wl_registry_destroy(state.registry);
    _ = c.wl_registry_add_listener(state.registry, &registry_listener, null);
    _ = c.wl_display_roundtrip(state.display);

    if (state.compositor == null) return error.WaylandCantFindCompositor;
    errdefer c.wl_compositor_destroy(state.compositor);
    if (state.shm == null) return error.WaylandShmError;
    errdefer c.wl_shm_destroy(state.shm);
    if (state.layer_shell == null) return error.WaylandLayerShellError;
    errdefer c.zwlr_layer_shell_v1_destroy(state.layer_shell);
    if (state.virtual_pointer_manager == null) return error.WaylandVirtualPointerManagerError;
    errdefer c.zwlr_virtual_pointer_manager_v1_destroy(state.virtual_pointer_manager);

    state.surface = c.wl_compositor_create_surface(state.compositor) orelse return error.WaylandSurfaceError;
    state.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        state.layer_shell,
        state.surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        "bento",
    ) orelse return error.WaylandLayerSurfaceError;
    _ = c.zwlr_layer_surface_v1_add_listener(state.layer_surface, &layer_surface_listener, null);
    c.zwlr_layer_surface_v1_set_anchor(
        state.layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
    );
    c.zwlr_layer_surface_v1_set_keyboard_interactivity(state.layer_surface, 1);
    c.zwlr_layer_surface_v1_set_exclusive_zone(state.layer_surface, -1);
    c.wl_surface_commit(state.surface);
    _ = c.wl_display_roundtrip(state.display);
    errdefer c.zwlr_layer_surface_v1_destroy(state.layer_surface);

    state.virtual_pointer = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
        state.virtual_pointer_manager,
        null,
    ) orelse return error.WaylandVirtualPointerError;
    errdefer c.zwlr_virtual_pointer_v1_destroy(state.virtual_pointer);

    // TODO: maybe I should hide the pointer once selection starts, instead of doing a crosshair pointer?
    // TODO: read XCURSOR_SIZE
    state.cursor_theme = c.wl_cursor_theme_load(null, 24, state.shm) orelse return error.WaylandCursorError;
    errdefer c.wl_cursor_theme_destroy(state.cursor_theme);
    state.cursor = (c.wl_cursor_theme_get_cursor(
        state.cursor_theme,
        "crosshair",
    ) orelse c.wl_cursor_theme_get_cursor(
        state.cursor_theme,
        "left_ptr",
    )) orelse return error.WaylandCursorError;
    state.cursor_image = state.cursor.*.images[0] orelse unreachable; // TODO: will this ever actually be null?
    state.cursor_surface = c.wl_compositor_create_surface(state.compositor) orelse return error.WaylandSurfaceError;
    c.wl_surface_attach(
        state.cursor_surface,
        c.wl_cursor_image_get_buffer(state.cursor.*.images[0]),
        0,
        0,
    );
    c.wl_surface_commit(state.cursor_surface);

    state.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextError;
}

// TODO: organize the frontend API functions

pub fn updateEvents() !void {
    if (c.wl_display_dispatch(state.display) > 0) {
        if (state.mouse.motion_dirty) {
            try frontend.event_queue.push(frontend.MouseMotionEvent.new(
                state.mouse.x,
                state.mouse.y,
            ));
            state.mouse.motion_dirty = false;
        }
    }
}

pub fn warpPointer(x: i32, y: i32) void {
    var timespec: std.os.timespec = undefined;
    // TODO: unreachable probably fine here?
    std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &timespec) catch unreachable;
    const ms_time = 1000 * timespec.tv_sec + @divTrunc(timespec.tv_nsec, 1000000);
    c.zwlr_virtual_pointer_v1_motion_absolute(
        state.virtual_pointer,
        @intCast(u32, ms_time),
        @intCast(u32, x),
        @intCast(u32, y),
        @intCast(u32, state.buffer.?.width),
        @intCast(u32, state.buffer.?.height),
    );
    c.zwlr_virtual_pointer_v1_frame(state.virtual_pointer);
}

pub fn clearDraw() void {
    if (state.buffer) |*buffer| {
        buffer.clear();
    }
}

pub fn drawLines(points: []const frontend.Point, border_size: u32, border_color: u32) void {
    if (state.buffer) |*buffer| {
        for (points[0 .. points.len - 1], 0..) |point, i| {
            const next_point = points[i + 1];
            drawLine(point, next_point, border_size, border_color);
        }

        buffer.draw();
    }
}

pub fn commitChanges() void {
    c.wl_surface_commit(state.surface);
    _ = c.wl_display_roundtrip(state.display);
}

fn angleTo(a: frontend.Point, b: frontend.Point) f64 {
    return std.math.atan2(f64, @intToFloat(f64, b.y - a.y), @intToFloat(f64, b.x - a.x));
}

fn drawBox(a: frontend.Point, b: frontend.Point, size: u32, color: u32) void {
    const start = frontend.Point.new(
        std.math.min(a.x, b.x),
        std.math.min(a.y, b.y),
    );
    const end = frontend.Point.new(
        std.math.max(a.x, b.x),
        std.math.max(a.y, b.y),
    );
    const mod_size = @intCast(i32, size % 2);
    const half_size = @intCast(i32, size / 2);
    var buffer = &state.buffer.?;
    const width = end.x - start.x;
    const height = end.y - start.y;
    if (width > height) {
        var y: i32 = start.y - half_size;
        while (y < end.y + half_size + mod_size) : (y += 1) {
            {
                if (y < 0 or y >= buffer.height) continue;
                var x: i32 = start.x;
                while (x < end.x) : (x += 1) {
                    if (x < 0 or x >= buffer.width) continue;
                    buffer.putPixel(x, y, color);
                }
            }
        }
    } else {
        var y: i32 = start.y;
        while (y < end.y) : (y += 1) {
            {
                if (y < 0 or y >= buffer.height) continue;
                var x: i32 = start.x - half_size;
                while (x < end.x + half_size + mod_size) : (x += 1) {
                    if (x < 0 or x >= buffer.width) continue;
                    buffer.putPixel(x, y, color);
                }
            }
        }
    }
}

// TODO: BETTER LINE DRAWING!!!!!!!!!!!
fn drawLine(a: frontend.Point, b: frontend.Point, size: u32, color: u32) void {
    if (a.x == b.x or a.y == b.y)
        return drawBox(a, b, size, color);
    const angle = angleTo(a, b);
    const sin = @sin(-angle);
    const cos = @cos(-angle);
    const rotated_a = frontend.Point.new(
        @floatToInt(i32, (@intToFloat(f64, a.x) * cos) - (@intToFloat(f64, a.y) * sin)),
        @floatToInt(i32, (@intToFloat(f64, a.x) * sin) + (@intToFloat(f64, a.y) * cos)),
    );
    const rotated_b = frontend.Point.new(
        @floatToInt(i32, (@intToFloat(f64, b.x) * cos) - (@intToFloat(f64, b.y) * sin)),
        @floatToInt(i32, (@intToFloat(f64, b.x) * sin) + (@intToFloat(f64, b.y) * cos)),
    );
    const diff = frontend.Point.new(
        b.x - a.x,
        b.y - a.y,
    );
    const step_count = 32;
    const step_diff_x = @intToFloat(f64, diff.x) / step_count;
    const step_diff_y = @intToFloat(f64, diff.y) / step_count;
    const x_step: i32 = if (b.x > a.x) 1 else -1;
    const y_step: i32 = if (b.y > a.y) 1 else -1;
    const steps: [step_count][2]frontend.Point = value: {
        var result: [step_count][2]frontend.Point = undefined;
        var point_a = a;
        var step_point_x = @intToFloat(f64, point_a.x) + step_diff_x;
        var step_point_y = @intToFloat(f64, point_a.y) + step_diff_y;
        var point_b = frontend.Point.new(
            @floatToInt(i32, step_point_x),
            @floatToInt(i32, step_point_y),
        );
        var i: usize = 0;
        while (i < step_count) : (i += 1) {
            result[i][0] = point_a;
            result[i][1] = point_b;
            point_a = point_b;
            step_point_x += step_diff_x;
            step_point_y += step_diff_y;
            point_b = frontend.Point.new(
                @floatToInt(i32, step_point_x),
                @floatToInt(i32, step_point_y),
            );
        }
        break :value result;
    };
    const half_size = @intCast(i32, size / 2);
    var buffer = &state.buffer.?;
    for (steps) |step| {
        {
            var y: i32 = step[0].y - half_size * y_step;
            while (y != step[1].y + half_size * y_step) : (y += y_step) {
                {
                    if (y < 0 or y >= buffer.height)
                        continue;
                    var x: i32 = step[0].x - half_size * x_step;
                    while (x != step[1].x + half_size * x_step) : (x += x_step) {
                        if (x < 0 or x >= buffer.width)
                            continue;
                        const rotated_p = frontend.Point.new(
                            @floatToInt(i32, (@intToFloat(f64, x) * cos) - (@intToFloat(f64, y) * sin)),
                            @floatToInt(i32, (@intToFloat(f64, x) * sin) + (@intToFloat(f64, y) * cos)),
                        );
                        // I can't imagine there'd ever be a situation this actually overflows
                        const y_dist = std.math.absInt(rotated_p.y - rotated_a.y) catch unreachable;
                        if (rotated_p.x >= rotated_a.x and rotated_p.x <= rotated_b.x and y_dist <= half_size) {
                            buffer.putPixel(x, y, color);
                        }
                    }
                }
            }
        }
    }
}

pub fn deinit() void {
    _ = c.wl_display_roundtrip(state.display);

    os.close(state.shm_fd);
    c.xkb_keymap_unref(state.xkb_keymap);
    c.xkb_state_unref(state.xkb_state);
    c.xkb_context_unref(state.xkb_context);
    c.zwlr_virtual_pointer_v1_destroy(state.virtual_pointer);
    c.zwlr_virtual_pointer_manager_v1_destroy(
        state.virtual_pointer_manager,
    );
    c.wl_cursor_theme_destroy(state.cursor_theme);

    if (state.buffer) |buffer| {
        os.munmap(buffer.data);
        c.wl_buffer_destroy(buffer.wl_buffer);
    }
    c.zwlr_layer_surface_v1_destroy(state.layer_surface);
    c.zwlr_layer_shell_v1_destroy(state.layer_shell);
    c.wl_shm_destroy(state.shm);
    c.wl_compositor_destroy(state.compositor);
    c.wl_registry_destroy(state.registry);
    c.wl_display_disconnect(state.display);
}

fn handleSeatCapabilities(
    _: ?*anyopaque,
    wl_seat: ?*c.wl_seat,
    capabilities: u32,
) callconv(.C) void {
    // TODO: do I need to store these seats somewhere to clean up later?
    if (capabilities & c.WL_SEAT_CAPABILITY_POINTER > 0) {
        _ = c.wl_pointer_add_listener(c.wl_seat_get_pointer(wl_seat), &pointer_listener, null);
    }
    if (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD > 0) {
        _ = c.wl_keyboard_add_listener(c.wl_seat_get_keyboard(wl_seat), &keyboard_listener, null);
    }
}
fn handleSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.C) void {}

const seat_listener = c.wl_seat_listener{
    .capabilities = handleSeatCapabilities,
    .name = handleSeatName,
};

fn handlePointerMotion(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    time: u32,
    fixed_x: c.wl_fixed_t,
    fixed_y: c.wl_fixed_t,
) callconv(.C) void {
    if (time > state.mouse.time) {
        const x = c.wl_fixed_to_int(fixed_x);
        const y = c.wl_fixed_to_int(fixed_y);
        state.mouse.time = time;
        state.mouse.x = x;
        state.mouse.y = y;
        state.mouse.motion_dirty = true;
    }
}

fn handlePointerButton(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, button_id: u32, button_state: u32) callconv(.C) void {
    const button = switch (button_id % 272) {
        0 => .left,
        1 => .right,
        2 => .middle,
        else => @intToEnum(frontend.MouseButton, button_id % 272),
    };
    frontend.event_queue.push(frontend.MouseButtonEvent.new(
        button,
        state.mouse.x,
        state.mouse.y,
        @bitCast(bool, @truncate(u1, button_state)),
    )) catch unreachable;
}

fn handlePointerEnter(_: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.C) void {
    c.wl_pointer_set_cursor(
        pointer,
        serial,
        state.cursor_surface,
        @intCast(i32, state.cursor_image.*.hotspot_x),
        @intCast(i32, state.cursor_image.*.hotspot_y),
    );
}
fn handlePointerLeave(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.C) void {}
fn handlePointerAxis(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, _: i32) callconv(.C) void {}
fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.C) void {}
fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.C) void {}
fn handlePointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.C) void {}
fn handlePointerAxisValue120(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.C) void {}
fn handlePointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.C) void {}

const pointer_listener = c.wl_pointer_listener{
    .enter = handlePointerEnter,
    .leave = handlePointerLeave,
    .motion = handlePointerMotion,
    .button = handlePointerButton,
    .axis = handlePointerAxis,
    .axis_source = handlePointerAxisSource,
    .axis_stop = handlePointerAxisStop,
    .axis_discrete = handlePointerAxisDiscrete,
    .axis_value120 = handlePointerAxisValue120,
    .frame = handlePointerFrame,
};

// TODO: add proper error handling here, can't return error because it's called from a C callback
fn handleKeyboardKeymap(_: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.C) void {
    const xkb_keymap = switch (format) {
        c.WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP => c.xkb_keymap_new_from_names(
            state.xkb_context,
            null,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ),
        c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 => value: {
            const buffer = os.mmap(null, size - 1, os.PROT.READ, os.MAP.PRIVATE, fd, 0) catch unreachable;
            defer os.munmap(buffer);
            defer os.close(fd);
            break :value c.xkb_keymap_new_from_buffer(
                state.xkb_context,
                buffer.ptr,
                size - 1,
                c.XKB_KEYMAP_FORMAT_TEXT_V1,
                c.XKB_KEYMAP_COMPILE_NO_FLAGS,
            );
        },
        else => unreachable,
    };
    c.xkb_keymap_unref(state.xkb_keymap);
    c.xkb_state_unref(state.xkb_state);
    state.xkb_keymap = xkb_keymap;
    state.xkb_state = c.xkb_state_new(state.xkb_keymap);
}

fn handleKeyboardKey(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, key_state: u32) callconv(.C) void {
    const keysym = c.xkb_state_key_get_one_sym(state.xkb_state, key + 8);
    switch (keysym) {
        c.XKB_KEY_Control_L,
        c.XKB_KEY_Control_R,
        => frontend.event_queue.push(frontend.ModKeyEvent.new(
            .control,
            key_state == 1,
        )) catch unreachable,

        c.XKB_KEY_Alt_L,
        c.XKB_KEY_Alt_R,
        => frontend.event_queue.push(frontend.ModKeyEvent.new(
            .alt,
            key_state == 1,
        )) catch unreachable,

        c.XKB_KEY_Shift_L,
        c.XKB_KEY_Shift_R,
        => frontend.event_queue.push(frontend.ModKeyEvent.new(
            .shift,
            key_state == 1,
        )) catch unreachable,

        else => {},
    }
}

fn handleKeyboardModifiers(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.C) void {
    _ = c.xkb_state_update_mask(state.xkb_state, depressed, latched, locked, 0, 0, group);
}
fn handleKeyboardEnter(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: [*c]c.wl_array) callconv(.C) void {}
fn handleKeyboardLeave(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.C) void {}
fn handleKeyboardRepeatInfo(_: ?*anyopaque, _: ?*c.wl_keyboard, _: i32, _: i32) callconv(.C) void {}

const keyboard_listener = c.wl_keyboard_listener{
    .keymap = handleKeyboardKeymap,
    .enter = handleKeyboardEnter,
    .leave = handleKeyboardLeave,
    .key = handleKeyboardKey,
    .modifiers = handleKeyboardModifiers,
    .repeat_info = handleKeyboardRepeatInfo,
};

// TODO: add proper error handling here, can't return error because it's called from a C callback
//       I could not just call this directly from the callback and only call it in the updateevents
//       function intsead
fn initBuffer(width: u32, height: u32) Buffer {
    const stride = width * 4;
    const size = height * stride;

    state.shm_fd = createShm(size) catch unreachable;
    // errdefer os.close(state.shm_fd);

    // os.ftruncate(state.shm_fd, size) catch unreachable;
    const data = os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, state.shm_fd, 0) catch unreachable;
    // TODO: no errors after here possible currently
    // errdefer os.munmap(data);

    const pool = c.wl_shm_create_pool(state.shm, state.shm_fd, @intCast(i32, size));
    defer c.wl_shm_pool_destroy(pool);
    // TODO: buffer listener

    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(i32, width),
        @intCast(i32, height),
        @intCast(i32, stride),
        c.WL_SHM_FORMAT_ARGB8888,
    ) orelse unreachable;

    return Buffer{
        .width = @intCast(i32, width),
        .height = @intCast(i32, height),
        .data = data,
        .wl_buffer = buffer,
        .clear_damage = DamageRect.new(@intCast(i32, width), @intCast(i32, height), 0, 0),
        .draw_damage = DamageRect.new(@intCast(i32, width), @intCast(i32, height), 0, 0),
    };
}

fn handleLayerSurfaceConfigure(
    _: ?*anyopaque,
    surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.C) void {
    c.zwlr_layer_surface_v1_ack_configure(surface, serial);
    if (state.buffer) |buffer| {
        os.close(state.shm_fd);
        const new_buffer = initBuffer(width, height);
        os.munmap(buffer.data);
        c.wl_buffer_destroy(buffer.wl_buffer);
        state.buffer = new_buffer;
    } else {
        state.buffer = initBuffer(width, height);
        c.wl_surface_attach(state.surface, state.buffer.?.wl_buffer, 0, 0);
        c.wl_surface_commit(state.surface);
    }
}
fn handleLayerSurfaceClosed(_: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.C) void {}

const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
    .configure = handleLayerSurfaceConfigure,
    .closed = handleLayerSurfaceClosed,
};

fn cStringEquals(a: [*c]const u8, b: [*c]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

fn registryBind(comptime type_name: []const u8, registry: ?*c.wl_registry, id: u32, version: u32) ?*@field(c, type_name) {
    return @ptrCast(*@field(c, type_name), c.wl_registry_bind(
        registry,
        id,
        &@field(c, type_name ++ "_interface"),
        version,
    ));
}

fn globalAdd(_: ?*anyopaque, registry: ?*c.wl_registry, id: u32, interface: [*c]const u8, version: u32) callconv(.C) void {
    if (cStringEquals(interface, c.wl_compositor_interface.name)) {
        state.compositor = registryBind("wl_compositor", registry, id, version);
    } else if (cStringEquals(interface, c.wl_shm_interface.name)) {
        state.shm = registryBind("wl_shm", registry, id, version);
    } else if (cStringEquals(interface, c.wl_seat_interface.name)) {
        const wl_seat = registryBind("wl_seat", registry, id, version);
        _ = c.wl_seat_add_listener(wl_seat, &seat_listener, null);
    } else if (cStringEquals(interface, c.wl_output_interface.name)) {
        const output = registryBind("wl_output", registry, id, version);
        _ = output;
        // std.debug.print("{any}\n", .{output});
    } else if (cStringEquals(interface, c.zwlr_layer_shell_v1_interface.name)) {
        state.layer_shell = registryBind("zwlr_layer_shell_v1", registry, id, version);
    } else if (cStringEquals(interface, c.zwlr_virtual_pointer_manager_v1_interface.name)) {
        state.virtual_pointer_manager = registryBind("zwlr_virtual_pointer_manager_v1", registry, id, version);
    }
}

fn globalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.C) void {}

const registry_listener = c.wl_registry_listener{
    .global = globalAdd,
    .global_remove = globalRemove,
};
