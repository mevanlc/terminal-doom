//! SPDX-License-Identifier: GPL-2-0 or MIT
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const zigimg = vaxis.zigimg;
const Key = vaxis.Key;

/// The events we want vaxis to deliver
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    winsize: vaxis.Winsize,
    mouse: vaxis.Mouse,
};

fn sigintHandler(_: std.posix.SIG) callconv(.c) void {
    state.exit_flag.store(true, .seq_cst);
}

/// Game state
const State = struct {
    // For each key in the queue, Doom expects a word. The upper byte
    // contains the pressed-flag, the lower byte the Doom-specific keycode.
    key_queue: [32]u16,
    key_queue_write_idx: u5,
    key_queue_read_idx: u5,
    shared_key_source_down: [shared_source_count]bool = [_]bool{false} ** shared_source_count,
    shared_key_alias_count: [shared_alias_count]u8 = [_]u8{0} ** shared_alias_count,
    startup: i64,
    loop: vaxis.Loop(Event),
    exit_flag: std.atomic.Value(bool),
    mouse_enabled: bool = true,
    last_mouse_x: f32 = std.math.floatMax(f32),
    last_mouse_y: f32 = std.math.floatMax(f32),
    mouse_dir: u21 = 0,
    debug_key_events: bool = false,
    scale: bool = true,
};

// We feed mouse events directly to Doom:
//
//    data1: Bitfield of buttons currently held down.
//           (bit 0 = left; bit 1 = right; bit 2 = middle).
//    data2: X axis mouse movement (turn).
//    data3: Y axis mouse movement (forward/backward).
//    data4: Not used
const evtype_t = enum(c_int) { ev_keydown, ev_keyup, ev_mouse, ev_joystick, ev_quit };
const event_t = extern struct {
    t: evtype_t,
    data1: c_int,
    data2: c_int,
    data3: c_int,
    data4: c_int,
};

// We use global state as the Doom callbacks don't allow for userdata to be passed.
var state: State = undefined;

// Called by Doom on startup; not needed in our case
pub export fn DG_Init() callconv(.c) void {}

// Called by doomgeneric to draw a single frame
pub export fn DG_DrawFrame() callconv(.c) void {
    // We need to have a window size before continuing
    const win = state.loop.vaxis.window();
    if (win.screen.width == 0) {
        while (state.loop.tryEvent() catch null) |event| {
            switch (event) {
                .winsize => |ws| state.loop.vaxis.resize(std.heap.c_allocator, state.loop.tty.writer(), ws) catch unreachable,
                else => {},
            }
        }
        return;
    }
    translateDoomBufferToRGB();

    var pixels = zigimg.Image{
        .width = 640,
        .height = 400,
        .pixels = zigimg.color.PixelStorage.initRawPixels(&DG_ScreenBuffer_Converted, .rgb24) catch unreachable,
    };

    // Write the image pixels using the Kitty image protocol
    const img = state.loop.vaxis.transmitImage(std.heap.c_allocator, state.loop.tty.writer(), &pixels, .rgb) catch unreachable;

    // Image size measured in cells
    const cell_size = img.cellSize(win) catch unreachable;

    const x_pix: f32 = @floatFromInt(win.screen.width_pix);
    const y_pix: f32 = @floatFromInt(win.screen.height_pix);
    const w: f32 = @floatFromInt(win.screen.width);
    const h: f32 = @floatFromInt(win.screen.height);

    const pix_per_col = x_pix / w;
    const pix_per_row = y_pix / h;

    const aspect_ratio = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));

    // Calculate the maximum allowed width and height based on window dimensions
    const max_width_cells = @max(w, @as(f32, @floatFromInt(cell_size.cols)));
    const max_height_cells = h;

    // Calculate the pixel dimensions for the max width and height
    const max_width_pix = max_width_cells * pix_per_col;
    const max_height_pix = max_height_cells * pix_per_row;

    var final_width_pix: f32 = 0;
    var final_height_pix: f32 = 0;

    // Scale according to the most limiting direction
    if (max_width_pix / aspect_ratio <= max_height_pix) {
        final_width_pix = max_width_pix;
        final_height_pix = final_width_pix / aspect_ratio;
    } else {
        final_height_pix = max_height_pix;
        final_width_pix = final_height_pix * aspect_ratio;
    }

    const final_width_cells = final_width_pix / pix_per_col;
    const final_height_cells = final_height_pix / pix_per_row;

    if (state.scale) {
        img.draw(win, .{ .size = .{
            .rows = @intFromFloat(final_height_cells),
            .cols = @intFromFloat(final_width_cells),
        } }) catch unreachable;
    } else {
        img.draw(win, .{}) catch unreachable;
    }

    while (state.loop.tryEvent() catch null) |event| {
        switch (event) {
            .key_press, .key_release => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    state.exit_flag.store(true, .seq_cst);
                } else if (key.codepoint == 'm' and event == .key_release) {
                    state.mouse_enabled = !state.mouse_enabled;
                } else if (key.codepoint == 'u' and event == .key_release) {
                    state.scale = !state.scale;
                } else {
                    enqueueKey(event == .key_press, key);
                }
            },
            .mouse => |mouse| {
                if (state.mouse_enabled) {
                    // Unscaled screen coordinates
                    var abs_x: f32 = @as(f32, @floatFromInt(mouse.col)) * pix_per_col + @as(f32, @floatFromInt(mouse.xoffset));
                    var abs_y: f32 = @as(f32, @floatFromInt(mouse.row)) * pix_per_row + @as(f32, @floatFromInt(mouse.yoffset));

                    // Scaled coordinates
                    const scalex = doom_width / final_width_pix;
                    const scaley = doom_height / final_height_pix;
                    abs_x *= scalex;
                    abs_y *= scaley;

                    var rel_x: c_int = 0;
                    var rel_y: c_int = 0;

                    if (state.last_mouse_x != std.math.floatMax(f32)) {
                        rel_x = @intFromFloat((abs_x - state.last_mouse_x) / scalex);
                    }
                    state.last_mouse_x = abs_x;

                    if (state.last_mouse_y != std.math.floatMax(f32)) {
                        rel_y = @intFromFloat((abs_y - state.last_mouse_y) / scaley);
                    }
                    state.last_mouse_y = abs_y;

                    var button_state: c_int = 0;
                    if (mouse.button == .left) button_state |= 1;
                    if (mouse.button == .right) button_state |= 2;
                    if (mouse.button == .middle) button_state |= 4;

                    var doom_event: event_t = .{
                        .t = .ev_mouse,
                        .data1 = button_state,
                        .data2 = accelerateMouse(rel_x, 16),
                        .data3 = -accelerateMouse(rel_y, 4),
                        .data4 = 0,
                    };

                    D_PostEvent(&doom_event);
                }
            },
            .winsize => |ws| state.loop.vaxis.resize(std.heap.c_allocator, state.loop.tty.writer(), ws) catch unreachable,
        }
    }

    state.loop.vaxis.render(state.loop.tty.writer()) catch unreachable;
}

fn accelerateMouse(delta: c_int, clamp: f32) c_int {
    const dx: f32 = @floatFromInt(delta);
    return @intFromFloat(dx * @min(clamp, 8 * @exp(@abs(dx))));
}

/// Called by Doom when it needs to sleep
pub export fn DG_SleepMs(ms: c_uint) callconv(.c) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// Called by Doom to get milliseconds passed since startup
pub export fn DG_GetTicksMs() callconv(.c) u32 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const now = std.Io.Timestamp.now(io, .awake);
    return @intCast(now.toMilliseconds() - state.startup);
}

/// Called by Doom to pull a keypress from the queue. Returns 0 if the queue is empty.
pub export fn DG_GetKey(pressed: [*c]c_int, doom_key: [*c]u8) callconv(.c) c_int {
    if (state.key_queue_read_idx != state.key_queue_write_idx) {
        const key_data = state.key_queue[state.key_queue_read_idx];
        state.key_queue_read_idx +%= 1;
        pressed.* = key_data >> 8;
        doom_key.* = @intCast(key_data & 0xff);
        return 1;
    }
    return 0;
}

/// Called by Doom to set window title. Not used.
pub export fn DG_SetWindowTitle(title: [*c]const u8) callconv(.c) void {
    _ = title;
}

fn translateDoomBufferToRGB() void {
    var rgb_index: usize = 0;
    for (0..doom_frame_buffer_size / 3) |i| {
        const pixel: u32 = DG_ScreenBuffer[i];
        DG_ScreenBuffer_Converted[rgb_index] = @intCast((pixel >> 16) & @as(u32, 0xFF));
        rgb_index += 1;
        DG_ScreenBuffer_Converted[rgb_index] = @intCast((pixel >> 8) & @as(u32, 0xFF));
        rgb_index += 1;
        DG_ScreenBuffer_Converted[rgb_index] = @intCast((pixel >> 0) & @as(u32, 0xFF));
        rgb_index += 1;
    }
}

/// Sets up libvaxis for terminal- and keyboard handling. Finally it
/// enters the Doom game-loop.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Use the C allocator for speed
    const alloc = std.heap.c_allocator;
    if (init.environ_map.get("TMUX") != null) {
        std.debug.print("Terminal Doom can not run under tmux\n", .{});
        std.process.exit(1);
    }

    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{ .kitty_keyboard_flags = .{ .report_events = true } });
    defer vx.deinit(alloc, tty.writer());

    const debug_key_events = if (init.environ_map.get("TERMINAL_DOOM_KEY_DEBUG")) |raw| raw.len > 0 and (std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "TRUE")) else false;

    const now = std.Io.Timestamp.now(io, .awake);
    state = .{
        .key_queue = [_]u16{0} ** 32,
        .key_queue_write_idx = 0,
        .key_queue_read_idx = 0,
        .startup = now.toMilliseconds(),
        .debug_key_events = debug_key_events,
        .exit_flag = std.atomic.Value(bool).init(false),
        .loop = .init(io, &tty, &vx),
    };

    const posix = std.posix;
    var sigint_act = posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            else => posix.sigemptyset(),
        },
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sigint_act, null);

    try state.loop.start();
    defer state.loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setMouseMode(tty.writer(), true);

    // Pass args to allow switching wad files, e.g. `terminal-doom -iwad PLUTONIA.WAD`
    const args = init.minimal.args.vector;
    const args_c: [*c][*c]u8 = @ptrCast(@constCast(args));

    // Initialize Doom-generic and enter the game loop
    doomgeneric_Create(@intCast(args.len), args_c);
    while (state.exit_flag.load(.seq_cst) == false) {
        doomgeneric_Tick();
    }
}

// Doomgeneric provides the screen buffer which we render when `DG_DrawFrame` is called.
pub extern var DG_ScreenBuffer: [*c]u32;
var DG_ScreenBuffer_Converted: [doom_frame_buffer_size]u8 = undefined;
pub extern fn doomgeneric_Create(argc: c_int, argv: [*c][*c]u8) void;
pub extern fn doomgeneric_Tick() void;
pub extern fn D_PostEvent(ev: *event_t) void;

const doom_width: usize = 640;
const doom_height: usize = 400;
const doom_frame_buffer_size: usize = doom_width * doom_height * 3;

const SharedAlias = enum(u8) {
    none = 0,
    forward = 1,
    backward = 2,
    left = 3,
    right = 4,
    fire = 5,
};

const shared_alias_count: usize = @intFromEnum(SharedAlias.fire) + 1;

const SharedSource = enum(u8) {
    none = 0,
    forward_w = 1,
    forward_up = 2,
    backward_down = 3,
    backward_k = 4,
    backward_s = 5,
    left_left = 6,
    left_j = 7,
    right_right = 8,
    right_l = 9,
    fire_lctrl = 10,
    fire_rctrl = 11,
    fire_f = 12,
    fire_i = 13,
};

const shared_source_count: usize = @intFromEnum(SharedSource.fire_i) + 1;

/// Map from codepoints to Doom keys
const SharedKeyMap = struct {
    doom_key: u8,
    shared_alias: SharedAlias,
    source: SharedSource,
};

fn enqueueKey(pressed: bool, key: vaxis.Key) void {
    const mapped_key = mapSharedKey(key);
    const doom_key = mapped_key.doom_key;
    const alias_idx = @intFromEnum(mapped_key.shared_alias);
    const source_idx = @intFromEnum(mapped_key.source);
    const alias_count_before = if (alias_idx < shared_alias_count) state.shared_key_alias_count[alias_idx] else 0;
    const source_down_before = if (source_idx < shared_source_count) state.shared_key_source_down[source_idx] else false;

    if (state.debug_key_events) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var debug_buffer: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &debug_buffer);
        stdout.interface.print("key_codepoint={} pressed={} doom_key=0x{x:0>2} alias={} source={} alias_count_before={} source_down_before={}\n", .{
            key.codepoint,
            pressed,
            doom_key,
            @intFromEnum(mapped_key.shared_alias),
            @intFromEnum(mapped_key.source),
            alias_count_before,
            source_down_before,
        }) catch {};
    }

    if (mapped_key.shared_alias == .none or mapped_key.source == .none) {
        queueDoomKey(pressed, doom_key);
        return;
    }

    if (pressed) {
        if (!state.shared_key_source_down[source_idx]) {
            if (state.shared_key_alias_count[alias_idx] == 0) {
                queueDoomKey(pressed, doom_key);
            }
            if (state.shared_key_alias_count[alias_idx] < std.math.maxInt(u8)) {
                state.shared_key_alias_count[alias_idx] += 1;
            }
            state.shared_key_source_down[source_idx] = true;
        }
        return;
    }

    if (state.shared_key_alias_count[alias_idx] > 0) {
        state.shared_key_alias_count[alias_idx] -= 1;
        state.shared_key_source_down[source_idx] = false;
        if (state.shared_key_alias_count[alias_idx] == 0) {
            queueDoomKey(pressed, doom_key);
        }
        return;
    }

    if (state.shared_key_source_down[source_idx]) {
        state.shared_key_source_down[source_idx] = false;
        queueDoomKey(pressed, doom_key);
        return;
    }

    queueDoomKey(pressed, doom_key);
}

fn mapSharedKey(key: vaxis.Key) SharedKeyMap {
    return switch (key.codepoint) {
        Key.enter => .{ .doom_key = KEY_ENTER, .shared_alias = .none, .source = .none },
        Key.escape => .{ .doom_key = KEY_ESCAPE, .shared_alias = .none, .source = .none },
        Key.left => .{ .doom_key = KEY_LEFTARROW, .shared_alias = .left, .source = .left_left },
        'j' => .{ .doom_key = KEY_LEFTARROW, .shared_alias = .left, .source = .left_j },
        Key.right => .{ .doom_key = KEY_RIGHTARROW, .shared_alias = .right, .source = .right_right },
        'l' => .{ .doom_key = KEY_RIGHTARROW, .shared_alias = .right, .source = .right_l },
        Key.up => .{ .doom_key = KEY_UPARROW, .shared_alias = .forward, .source = .forward_up },
        'w' => .{ .doom_key = KEY_UPARROW, .shared_alias = .forward, .source = .forward_w },
        Key.down => .{ .doom_key = KEY_DOWNARROW, .shared_alias = .backward, .source = .backward_down },
        'k' => .{ .doom_key = KEY_DOWNARROW, .shared_alias = .backward, .source = .backward_k },
        's' => .{ .doom_key = KEY_DOWNARROW, .shared_alias = .backward, .source = .backward_s },
        Key.left_control => .{ .doom_key = KEY_FIRE, .shared_alias = .fire, .source = .fire_lctrl },
        Key.right_control => .{ .doom_key = KEY_FIRE, .shared_alias = .fire, .source = .fire_rctrl },
        'f' => .{ .doom_key = KEY_FIRE, .shared_alias = .fire, .source = .fire_f },
        'i' => .{ .doom_key = KEY_FIRE, .shared_alias = .fire, .source = .fire_i },
        Key.space => .{ .doom_key = KEY_USE, .shared_alias = .none, .source = .none },
        Key.left_alt, Key.right_alt => .{ .doom_key = KEY_LALT, .shared_alias = .none, .source = .none },
        Key.left_shift, Key.right_shift => .{ .doom_key = KEY_RSHIFT, .shared_alias = .none, .source = .none },
        Key.f2 => .{ .doom_key = KEY_F2, .shared_alias = .none, .source = .none },
        Key.f3 => .{ .doom_key = KEY_F3, .shared_alias = .none, .source = .none },
        Key.f4 => .{ .doom_key = KEY_F4, .shared_alias = .none, .source = .none },
        Key.f5 => .{ .doom_key = KEY_F5, .shared_alias = .none, .source = .none },
        Key.f6 => .{ .doom_key = KEY_F6, .shared_alias = .none, .source = .none },
        Key.f7 => .{ .doom_key = KEY_F7, .shared_alias = .none, .source = .none },
        Key.f8 => .{ .doom_key = KEY_F8, .shared_alias = .none, .source = .none },
        Key.f9 => .{ .doom_key = KEY_F9, .shared_alias = .none, .source = .none },
        Key.f10 => .{ .doom_key = KEY_F10, .shared_alias = .none, .source = .none },
        Key.f11 => .{ .doom_key = KEY_F11, .shared_alias = .none, .source = .none },
        Key.kp_equal, '=', '+' => .{ .doom_key = KEY_EQUALS, .shared_alias = .none, .source = .none },
        '-' => .{ .doom_key = KEY_MINUS, .shared_alias = .none, .source = .none },
        'a' => .{ .doom_key = KEY_STRAFE_L, .shared_alias = .none, .source = .none },
        'd' => .{ .doom_key = KEY_STRAFE_R, .shared_alias = .none, .source = .none },
        else => .{ .doom_key = if (key.codepoint <= std.math.maxInt(u8)) std.ascii.toLower(@intCast(key.codepoint)) else 0, .shared_alias = .none, .source = .none },
    };
}

fn queueDoomKey(pressed: bool, doom_key: u8) void {
    const key_data: u16 = (@as(u16, @intCast(@intFromBool(pressed))) << 8) | doom_key;
    state.key_queue[state.key_queue_write_idx] = key_data;
    state.key_queue_write_idx +%= 1;
}

// Doom key definitions
const KEY_RIGHTARROW: u8 = 0xae;
const KEY_LEFTARROW: u8 = 0xac;
const KEY_UPARROW: u8 = 0xad;
const KEY_DOWNARROW: u8 = 0xaf;
const KEY_STRAFE_L: u8 = 0xa0;
const KEY_STRAFE_R: u8 = 0xa1;
const KEY_USE: u8 = 0xa2;
const KEY_FIRE: u8 = 0xa3;
const KEY_ESCAPE: u8 = 27;
const KEY_ENTER: u8 = 13;
const KEY_TAB: u8 = 9;
const KEY_F1: u8 = (0x80 + 0x3b);
const KEY_F2: u8 = (0x80 + 0x3c);
const KEY_F3: u8 = (0x80 + 0x3d);
const KEY_F4: u8 = (0x80 + 0x3e);
const KEY_F5: u8 = (0x80 + 0x3f);
const KEY_F6: u8 = (0x80 + 0x40);
const KEY_F7: u8 = (0x80 + 0x41);
const KEY_F8: u8 = (0x80 + 0x42);
const KEY_F9: u8 = (0x80 + 0x43);
const KEY_F10: u8 = (0x80 + 0x44);
const KEY_F11: u8 = (0x80 + 0x57);
const KEY_F12: u8 = (0x80 + 0x58);
const KEY_BACKSPACE: u8 = 0x7f;
const KEY_PAUSE: u8 = 0xff;
const KEY_EQUALS: u8 = 0x3d;
const KEY_MINUS: u8 = 0x2d;
const KEY_RSHIFT: u8 = (0x80 + 0x36);
const KEY_RCTRL: u8 = (0x80 + 0x1d);
const KEY_RALT: u8 = (0x80 + 0x38);
const KEY_LALT: u8 = KEY_RALT;
const KEY_CAPSLOCK: u8 = (0x80 + 0x3a);
const KEY_NUMLOCK: u8 = (0x80 + 0x45);
const KEY_SCRLCK: u8 = (0x80 + 0x46);
const KEY_PRTSCR: u8 = (0x80 + 0x59);
const KEY_HOME: u8 = (0x80 + 0x47);
const KEY_END: u8 = (0x80 + 0x4f);
const KEY_PGUP: u8 = (0x80 + 0x49);
const KEY_PGDN: u8 = (0x80 + 0x51);
const KEY_INS: u8 = (0x80 + 0x52);
const KEY_DEL: u8 = (0x80 + 0x53);
const KEYP_0: u8 = 0;
const KEYP_1: u8 = KEY_END;
const KEYP_2: u8 = KEY_DOWNARROW;
const KEYP_3: u8 = KEY_PGDN;
const KEYP_4: u8 = KEY_LEFTARROW;
const KEYP_5: u8 = '5';
const KEYP_6: u8 = KEY_RIGHTARROW;
const KEYP_7: u8 = KEY_HOME;
const KEYP_8: u8 = KEY_UPARROW;
const KEYP_9: u8 = KEY_PGUP;
const KEYP_DIVIDE: u8 = '/';
const KEYP_PLUS: u8 = '+';
const KEYP_MINUS: u8 = '-';
const KEYP_MULTIPLY: u8 = '*';
const KEYP_PERIOD: u8 = 0;
const KEYP_EQUALS: u8 = KEY_EQUALS;
const KEYP_ENTER: u8 = KEY_ENTER;
