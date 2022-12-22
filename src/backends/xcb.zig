const std = @import("std");
const root = @import("root");
const frontend = @import("../frontend.zig");
const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_cursor.h");
    @cInclude("xcb/shape.h");
});

const Allocator = std.mem.Allocator;

const XcbErrors = error{
    XcbConnectionError,
    XcbCursorGrabError,
    XcbKeyGrabError,
    XcbEventIoError,
    XcbEventError,
    XcbGeometryError,
};

const alt_keycode = 64;

const ModState = struct {
    control: bool = false,
    shift: bool = false,

    pub fn update(self: *ModState, event_queue: *frontend.EventQueue, mod_state: u16) !void {
        const new_control = (mod_state & c.XCB_MOD_MASK_CONTROL) > 0;
        const new_shift = (mod_state & c.XCB_MOD_MASK_SHIFT) > 0;

        if (new_control != self.control)
            try event_queue.push(frontend.ModKeyEvent.new(.control, new_control));
        if (new_shift != self.shift)
            try event_queue.push(frontend.ModKeyEvent.new(.shift, new_shift));

        self.*.control = new_control;
        self.*.shift = new_shift;
    }
};

const State = struct {
    connection: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    mask_pixmap: c.xcb_pixmap_t,
    mask_graphics_context: c.xcb_gc_t,
    draw_pixmap: c.xcb_pixmap_t,
    draw_graphics_context: c.xcb_gc_t,
    selection_window: c.xcb_window_t = 0,
    mod_state: ModState = .{},
};

const raw_allocator = std.heap.raw_c_allocator;

var state: State = undefined;

pub fn init(options: root.OptionsType) XcbErrors!void {
    state.connection = c.xcb_connect(null, null) orelse return error.XcbConnectionError;
    if (c.xcb_connection_has_error(state.connection) != 0)
        return error.XcbConnectionError;
    errdefer c.xcb_disconnect(state.connection);

    defer flush();

    state.screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(state.connection)).data.*;

    var cursor_context: ?*c.xcb_cursor_context_t = undefined;
    _ = c.xcb_cursor_context_new(state.connection, &state.screen, &cursor_context);
    defer c.xcb_cursor_context_free(cursor_context);
    const cursor = c.xcb_cursor_load_cursor(cursor_context, "crosshair");
    defer _ = c.xcb_free_cursor(state.connection, cursor);

    var grab_pointer_cookie: c.xcb_grab_pointer_cookie_t = undefined;
    var pointer_reply: *c.xcb_grab_pointer_reply_t = undefined;

    while (true) {
        grab_pointer_cookie = c.xcb_grab_pointer(
            state.connection,
            0,
            state.screen.root,
            c.XCB_EVENT_MASK_BUTTON_PRESS |
                c.XCB_EVENT_MASK_BUTTON_RELEASE |
                c.XCB_EVENT_MASK_POINTER_MOTION,
            c.XCB_GRAB_MODE_ASYNC,
            c.XCB_GRAB_MODE_ASYNC,
            state.screen.root,
            cursor,
            c.XCB_CURRENT_TIME,
        );
        pointer_reply = c.xcb_grab_pointer_reply(
            state.connection,
            grab_pointer_cookie,
            null,
        ) orelse return error.XcbCursorGrabError;
        defer raw_allocator.destroy(pointer_reply);

        if (pointer_reply.*.status == c.XCB_GRAB_STATUS_SUCCESS)
            break
        else if (!options.@"x11-wait")
            return error.XcbCursorGrabError;
    }
    errdefer _ = c.xcb_ungrab_pointer(state.connection, c.XCB_CURRENT_TIME);

    const grab_key_cookie = c.xcb_grab_key(
        state.connection,
        0,
        state.screen.root,
        c.XCB_MOD_MASK_ANY,
        // TODO: I should be properly getting the keycode, not hardcoding
        //       the value.
        alt_keycode,
        c.XCB_GRAB_MODE_ASYNC,
        c.XCB_GRAB_MODE_ASYNC,
    );
    if (@ptrCast(?*c.xcb_generic_error_t, c.xcb_request_check(state.connection, grab_key_cookie))) |*err| {
        raw_allocator.destroy(err);
        return error.XcbKeyGrabError;
    }
    errdefer _ = c.xcb_ungrab_key(
        state.connection,
        alt_keycode,
        state.screen.root,
        c.XCB_MOD_MASK_ANY,
    );

    _ = c.xcb_change_window_attributes(
        state.connection,
        state.screen.root,
        c.XCB_CW_EVENT_MASK,
        &c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
    );

    try selectionWindowInit();
}

// TODO: add error checking here
fn selectionWindowInit() XcbErrors!void {
    const mask = c.XCB_CW_OVERRIDE_REDIRECT;
    const values = &[_]u32{1};

    state.selection_window = c.xcb_generate_id(state.connection);
    _ = c.xcb_create_window(
        state.connection,
        c.XCB_COPY_FROM_PARENT,
        state.selection_window,
        state.screen.root,
        0,
        0,
        state.screen.width_in_pixels,
        state.screen.height_in_pixels,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        c.XCB_COPY_FROM_PARENT,
        mask,
        values,
    );
    errdefer _ = c.xcb_kill_client(state.connection, state.selection_window);

    const name = "bento";
    const class = name ++ "\x00" ++ name;

    _ = c.xcb_change_property(
        state.connection,
        c.XCB_PROP_MODE_REPLACE,
        state.selection_window,
        c.XCB_ATOM_WM_NAME,
        c.XCB_ATOM_STRING,
        8,
        name.len,
        name,
    );

    _ = c.xcb_change_property(
        state.connection,
        c.XCB_PROP_MODE_REPLACE,
        state.selection_window,
        c.XCB_ATOM_WM_CLASS,
        c.XCB_ATOM_STRING,
        8,
        class.len,
        class,
    );

    state.mask_pixmap = c.xcb_generate_id(state.connection);
    _ = c.xcb_create_pixmap(
        state.connection,
        1,
        state.mask_pixmap,
        state.screen.root,
        state.screen.width_in_pixels,
        state.screen.height_in_pixels,
    );
    errdefer _ = c.xcb_free_pixmap(state.connection, state.mask_pixmap);

    state.mask_graphics_context = c.xcb_generate_id(state.connection);
    _ = c.xcb_create_gc(
        state.connection,
        state.mask_graphics_context,
        state.mask_pixmap,
        0,
        null,
    );
    errdefer _ = c.xcb_free_gc(state.connection, state.mask_graphics_context);

    state.draw_pixmap = c.xcb_generate_id(state.connection);
    _ = c.xcb_create_pixmap(
        state.connection,
        state.screen.root_depth,
        state.draw_pixmap,
        state.screen.root,
        state.screen.width_in_pixels,
        state.screen.height_in_pixels,
    );
    errdefer _ = c.xcb_free_pixmap(state.connection, state.draw_pixmap);

    state.draw_graphics_context = c.xcb_generate_id(state.connection);
    _ = c.xcb_create_gc(
        state.connection,
        state.draw_graphics_context,
        state.draw_pixmap,
        0,
        null,
    );
    errdefer _ = c.xcb_free_gc(state.connection, state.draw_graphics_context);

    _ = c.xcb_shape_mask(
        state.connection,
        c.XCB_SHAPE_SO_SET,
        c.XCB_SHAPE_SK_BOUNDING,
        state.selection_window,
        0,
        0,
        state.mask_pixmap,
    );

    _ = c.xcb_map_window(state.connection, state.selection_window);
}

pub fn deinit() void {
    _ = c.xcb_ungrab_pointer(state.connection, c.XCB_CURRENT_TIME);
    _ = c.xcb_ungrab_key(state.connection, alt_keycode, state.screen.root, c.XCB_MOD_MASK_ANY);

    _ = c.xcb_kill_client(state.connection, state.selection_window);

    _ = c.xcb_free_pixmap(state.connection, state.mask_pixmap);
    _ = c.xcb_free_gc(state.connection, state.mask_graphics_context);

    _ = c.xcb_free_pixmap(state.connection, state.draw_pixmap);
    _ = c.xcb_free_gc(state.connection, state.draw_graphics_context);

    c.xcb_disconnect(state.connection);
}

fn getMouseButton(index: u8) frontend.MouseButton {
    return switch (index) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => @intToEnum(frontend.MouseButton, index - 1),
    };
}

pub fn updateEvents() !void {
    var event_queue = &frontend.event_queue;
    if (c.xcb_wait_for_event(state.connection)) |event| {
        switch (event.*.response_type & ~@as(u8, 0x80)) {
            c.XCB_BUTTON_PRESS => {
                const e = @ptrCast(*c.xcb_button_press_event_t, event);
                try state.mod_state.update(event_queue, e.*.state);
                try event_queue.push(frontend.MouseButtonEvent.new(
                    getMouseButton(e.*.detail),
                    e.*.root_x,
                    e.*.root_y,
                    true,
                ));
            },
            c.XCB_BUTTON_RELEASE => {
                const e = @ptrCast(*c.xcb_button_release_event_t, event);
                try state.mod_state.update(event_queue, e.*.state);
                try event_queue.push(frontend.MouseButtonEvent.new(
                    getMouseButton(e.*.detail),
                    e.*.root_x,
                    e.*.root_y,
                    false,
                ));
            },
            c.XCB_KEY_PRESS => {
                const e = @ptrCast(*c.xcb_key_press_event_t, event);
                if (e.*.detail == alt_keycode)
                    try event_queue.push(frontend.ModKeyEvent.new(.alt, true));
            },
            c.XCB_KEY_RELEASE => {
                const e = @ptrCast(*c.xcb_key_release_event_t, event);
                if (e.*.detail == alt_keycode)
                    try event_queue.push(frontend.ModKeyEvent.new(.alt, false));
            },
            c.XCB_MOTION_NOTIFY => {
                const e = @ptrCast(*c.xcb_motion_notify_event_t, event);
                try state.mod_state.update(event_queue, e.*.state);
                try event_queue.push(frontend.MouseMotionEvent.new(
                    e.*.root_x,
                    e.*.root_y,
                ));
            },
            else => {},
        }

        raw_allocator.destroy(event);
    } else return error.XcbEventError;
}

pub fn getWindowGeometry(window: u32) frontend.WindowGeometry {
    const w = if (window == 0) state.screen.root else window;
    const g = c.xcb_get_geometry_reply(
        state.connection,
        c.xcb_get_geometry(state.connection, w),
        null,
    );
    defer raw_allocator.destroy(g);

    const result = frontend.WindowGeometry{
        .x = g.*.x + @intCast(i16, g.*.border_width),
        .y = g.*.y + @intCast(i16, g.*.border_width),
        .w = g.*.width,
        .h = g.*.height,
    };

    return result;
}

// TODO: I will need this later
// fn tryGetChildWindow(base_window: u32) u32 {
//     const tree_cookie = c.xcb_query_tree(state.connection, base_window);
//     const tree = c.xcb_query_tree_reply(
//         state.connection,
//         tree_cookie,
//         null,
//     ) orelse return base_window;
//     defer raw_allocator.destroy(tree);

//     const child_count = tree.*.children_len;
//     if (child_count == 0)
//         return base_window;
//     const children = c.xcb_query_tree_children(tree) orelse unreachable;

//     const atom_name = "WM_STATE";
//     const wm_state_cookie = c.xcb_intern_atom(state.connection, 0, atom_name.len, atom_name);
//     const wm_state = c.xcb_intern_atom_reply(
//         state.connection,
//         wm_state_cookie,
//         null,
//     ) orelse unreachable;
//     defer raw_allocator.destroy(wm_state);

//     var i: usize = child_count - 1;
//     while (i >= 0) : (i -= 1) {
//         const property_cookie = c.xcb_get_property(
//             state.connection,
//             0,
//             children[i],
//             wm_state.*.atom,
//             c.XCB_GET_PROPERTY_TYPE_ANY,
//             0,
//             0,
//         );
//         const property = c.xcb_get_property_reply(
//             state.connection,
//             property_cookie,
//             null,
//         );

//         if (property) |p| {
//             defer raw_allocator.destroy(p);
//             if (p.*.type == c.XCB_NONE) {
//                 if (i == 0) break;
//                 continue;
//             }
//         }

//         return children[i];
//     }

//     i = child_count - 1;
//     while (i >= 0) : (i -= 1) {
//         if (children[i] != c.XCB_WINDOW_NONE) {
//             const window = tryGetChildWindow(children[i]);
//             if (window != c.XCB_WINDOW_NONE)
//                 return window;
//         }
//     }
// }

pub fn warpPointer(x: i32, y: i32) void {
    _ = c.xcb_warp_pointer(
        state.connection,
        c.XCB_NONE,
        state.screen.root,
        0,
        0,
        0,
        0,
        @intCast(i16, x),
        @intCast(i16, y),
    );
    flush();
}

pub fn clearDraw() void {
    _ = c.xcb_change_gc(
        state.connection,
        state.mask_graphics_context,
        c.XCB_GC_FOREGROUND,
        &[_]u8{0},
    );

    _ = c.xcb_poly_fill_rectangle(
        state.connection,
        state.mask_pixmap,
        state.mask_graphics_context,
        1,
        &c.xcb_rectangle_t{
            .x = 0,
            .y = 0,
            .width = state.screen.width_in_pixels,
            .height = state.screen.height_in_pixels,
        },
    );
}

pub fn drawLines(points: []const frontend.Point, border_size: u32, border_color: u32) void {
    _ = c.xcb_change_gc(
        state.connection,
        state.mask_graphics_context,
        c.XCB_GC_FOREGROUND,
        &[_]u8{1},
    );

    _ = c.xcb_change_gc(
        state.connection,
        state.draw_graphics_context,
        c.XCB_GC_FOREGROUND,
        &[_]u32{border_color},
    );

    _ = c.xcb_change_gc(
        state.connection,
        state.mask_graphics_context,
        c.XCB_GC_LINE_WIDTH,
        &[_]u32{border_size},
    );

    _ = c.xcb_change_gc(
        state.connection,
        state.draw_graphics_context,
        c.XCB_GC_LINE_WIDTH,
        &[_]u32{border_size},
    );

    var i: usize = 0;
    while (i < points.len - 1) : (i += 1) {
        const line = [2]c.xcb_point_t{
            .{
                .x = @truncate(i16, points[i].x),
                .y = @truncate(i16, points[i].y),
            },
            .{
                .x = @truncate(i16, points[i + 1].x),
                .y = @truncate(i16, points[i + 1].y),
            },
        };
        _ = c.xcb_poly_line(
            state.connection,
            c.XCB_COORD_MODE_ORIGIN,
            state.mask_pixmap,
            state.mask_graphics_context,
            2,
            &line,
        );
        _ = c.xcb_poly_line(
            state.connection,
            c.XCB_COORD_MODE_ORIGIN,
            state.draw_pixmap,
            state.draw_graphics_context,
            2,
            &line,
        );
    }
}

pub fn commitChanges() void {
    _ = c.xcb_shape_mask(
        state.connection,
        c.XCB_SHAPE_SO_SET,
        c.XCB_SHAPE_SK_BOUNDING,
        state.selection_window,
        0,
        0,
        state.mask_pixmap,
    );
    _ = c.xcb_copy_area(
        state.connection,
        state.draw_pixmap,
        state.selection_window,
        state.draw_graphics_context,
        0,
        0,
        0,
        0,
        state.screen.width_in_pixels,
        state.screen.height_in_pixels,
    );
    flush();
}

const RectangleList = std.ArrayListUnmanaged(frontend.Rectangle);
pub fn generateRectangles(allocator: Allocator) ![]frontend.Rectangle {
    var rectangle_list = RectangleList{};
    const tree_cookie = c.xcb_query_tree(state.connection, state.screen.root);
    const tree = c.xcb_query_tree_reply(
        state.connection,
        tree_cookie,
        null,
    );
    defer raw_allocator.destroy(tree);

    try rectangle_list.append(
        allocator,
        .{
            .x1 = 0,
            .y1 = 0,
            .x2 = @intCast(i16, state.screen.width_in_pixels),
            .y2 = @intCast(i16, state.screen.height_in_pixels),
            .label = try std.fmt.allocPrint(allocator, "{d}", .{state.screen.root}),
        },
    );

    const child_count = tree.*.children_len;
    if (child_count == 0)
        return &.{};
    const children = c.xcb_query_tree_children(tree);

    const atom_name = "WM_STATE";
    const wm_state_cookie = c.xcb_intern_atom(state.connection, 0, atom_name.len, atom_name);
    const wm_state = c.xcb_intern_atom_reply(
        state.connection,
        wm_state_cookie,
        null,
    ) orelse unreachable;
    defer raw_allocator.destroy(wm_state);

    var i: usize = 0;
    while (i < child_count) : (i += 1) {
        // const window = children[@intCast(usize, i)];
        const window = children[i];
        if (window == state.selection_window) continue;
        const attribute_cookie = c.xcb_get_window_attributes(state.connection, window);
        const attributes = c.xcb_get_window_attributes_reply(
            state.connection,
            attribute_cookie,
            null,
        );

        if (attributes) |a| {
            defer raw_allocator.destroy(a);
            // if (a.*.override_redirect != 0 or a.*.map_state != c.XCB_MAP_STATE_VIEWABLE)
            //     continue;
            if (a.*._class != c.XCB_WINDOW_CLASS_INPUT_OUTPUT or a.*.map_state != c.XCB_MAP_STATE_VIEWABLE)
                continue;
            // if (a.*.map_state != c.XCB_MAP_STATE_VIEWABLE)
            //     continue;
        } else continue;

        const geometry = c.xcb_get_geometry_reply(
            state.connection,
            c.xcb_get_geometry(state.connection, window),
            null,
        ) orelse return error.XcbGeometryError;
        defer raw_allocator.destroy(geometry);

        try rectangle_list.append(
            allocator,
            .{
                .x1 = geometry.*.x,
                .y1 = geometry.*.y,
                .x2 = geometry.*.x + @intCast(i16, geometry.*.width),
                .y2 = geometry.*.y + @intCast(i16, geometry.*.height),
                .label = try std.fmt.allocPrint(allocator, "{d}", .{window}),
            },
        );
    }

    rectangle_list.shrinkAndFree(allocator, rectangle_list.items.len);
    return rectangle_list.items;
}

fn flush() void {
    _ = c.xcb_flush(state.connection);
}
