const std = @import("std");
const sum_tree = @import("sum_tree");
const Rope = sum_tree.Rope;
const Point = sum_tree.Point;
const Document = sum_tree.Document;
const Editor = sum_tree.Editor;
const tui_lib = @import("tui.zig");
const Tui = tui_lib.Tui;

const Allocator = std.mem.Allocator;

fn mapTuiKeyToEditorKey(tui_key: tui_lib.Key) sum_tree.Key {
    switch (tui_key) {
        .char => |ch| return .{ .char = .{ .buf = ch.buf, .len = ch.len } },
        .escape => return .escape,
        .up => return .up,
        .down => return .down,
        .left => return .left,
        .right => return .right,
        .page_up => return .page_up,
        .page_down => return .page_down,
        .home => return .home,
        .end => return .end,
        .delete => return .delete,
        .backspace => return .backspace,
        .enter => return .enter,
        .ctrl_c => return .ctrl_c,
        .ctrl_d => return .ctrl_d,
        .ctrl_q => return .ctrl_q,
        .ctrl_s => return .ctrl_s,
        .ctrl_z => return .ctrl_z,
        .ctrl_y => return .ctrl_y,
        .ctrl_r => return .ctrl_r,
        .other => return .other,
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next(); // skips the executable name
    const filename = args.next() orelse "untitled.txt";

    // 1. Load file if it exists
    var file_content: ?[]u8 = null;
    if (std.Io.Dir.cwd().openFile(io, filename, .{})) |file| {
        defer file.close(io);
        var file_read_buffer: [4096]u8 = undefined;
        var f_reader = file.reader(io, &file_read_buffer);
        const f_reader_ptr = &f_reader.interface;
        file_content = try f_reader_ptr.allocRemaining(allocator, .unlimited);
    } else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("unable to open file {s}: {}\n", .{ filename, err });
            return;
        }
    }
    defer if (file_content) |content| allocator.free(content);

    // 2. Initialize Document
    const document = try Document.init(allocator, file_content orelse "", filename);
    defer document.deinit();

    // 3. Initialize TUI helper (handles Raw mode)
    var tui = try Tui.init(io, allocator);
    defer tui.deinit();

    const init_size = try tui.getScreenSize();

    // 4. Initialize Editor
    var editor = try Editor.init(allocator, document, init_size.width);
    defer editor.deinit();

    var render_buf = std.ArrayList(u8).empty;
    defer render_buf.deinit(allocator);

    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    var force_render = true;
    var prev_screen_width: usize = 0;
    var prev_screen_height: usize = 0;

    while (true) {
        // Query Terminal Size via Tui helper
        const size = try tui.getScreenSize();
        const screen_width = size.width;
        const screen_height = size.height;

        if (screen_width != prev_screen_width or screen_height != prev_screen_height) {
            force_render = true;
            prev_screen_width = screen_width;
            prev_screen_height = screen_height;
            try editor.wrap_map.rewrapAll(if (editor.wrap_enabled) screen_width else 100000, document.rope);
        }

        const total_newlines = document.rope.tree.root.summary.line_len;

        if (force_render) {
            force_render = false;

            // Viewport Scroll Constraints
            const display_cursor = try editor.wrap_map.bufferToDisplay(.{ .row = editor.cursor_pos.row, .column = editor.cursor_pos.column }, document.rope);
            if (screen_height >= 3) {
                if (display_cursor.row < editor.viewport_offset.row) {
                    editor.viewport_offset.row = display_cursor.row;
                }
                if (display_cursor.row >= editor.viewport_offset.row + screen_height - 2) {
                    editor.viewport_offset.row = display_cursor.row - (screen_height - 3);
                }
            }
            if (editor.wrap_enabled) {
                editor.viewport_offset.column = 0;
            } else {
                if (display_cursor.col < editor.viewport_offset.column) {
                    editor.viewport_offset.column = display_cursor.col;
                }
                if (display_cursor.col >= editor.viewport_offset.column + screen_width) {
                    editor.viewport_offset.column = display_cursor.col - screen_width + 1;
                }
            }

            // Render Frame
            render_buf.clearRetainingCapacity();
            try tui.clear(&render_buf);

            var r: usize = 0;
            const render_limit = if (screen_height >= 2) screen_height - 2 else 0;
            while (r < render_limit) : (r += 1) {
                const display_row = editor.viewport_offset.row + r;
                const start_pt = try editor.wrap_map.displayToBuffer(.{ .row = display_row, .col = 0 }, document.rope);
                const total_lines = document.rope.tree.root.summary.line_len + 1;

                if (start_pt.row < total_lines) {
                    try document.rope.lineText(start_pt.row, &line_buf);

                    // Strip trailing newlines
                    var text_len = line_buf.items.len;
                    while (text_len > 0 and (line_buf.items[text_len - 1] == '\n' or line_buf.items[text_len - 1] == '\r')) {
                        text_len -= 1;
                    }
                    const clean_line = line_buf.items[0..text_len];

                    const display_start_for_line = (try editor.wrap_map.bufferToDisplay(.{ .row = start_pt.row, .column = 0 }, document.rope)).row;
                    const sub_row = display_row - display_start_for_line;

                    const char_start = sub_row * (if (editor.wrap_enabled) screen_width else editor.wrap_map.wrap_width) + (if (editor.wrap_enabled) 0 else editor.viewport_offset.column);

                    // Offset of start of the line in the rope
                    const line_start_offset = document.rope.pointToOffset(Point{ .row = start_pt.row, .column = 0 });

                    var col: usize = 0;
                    for (clean_line, 0..) |char, raw_idx| {
                        const char_offset = line_start_offset + raw_idx;
                        const is_selected = editor.selection_manager.isOffsetSelected(char_offset);

                        var is_secondary = false;
                        for (editor.saved_cursors.items) |sc| {
                            const sc_offset = document.rope.pointToOffset(sc.pos);
                            if (sc_offset == char_offset) {
                                is_secondary = true;
                                break;
                            }
                        }

                        const spaces = if (char == '\t') 4 - (col % 4) else 1;
                        var s: usize = 0;
                        while (s < spaces) : (s += 1) {
                            const exp_col = col + s;
                            if (exp_col >= char_start and exp_col < char_start + screen_width) {
                                if (is_secondary) {
                                    try render_buf.appendSlice(allocator, "\x1b[7m");
                                } else if (is_selected) {
                                    try render_buf.appendSlice(allocator, "\x1b[48;5;239m");
                                }
                                if (char == '\t') {
                                    try render_buf.appendSlice(allocator, " ");
                                } else {
                                    try render_buf.append(allocator, char);
                                }
                                if (is_secondary or is_selected) {
                                    try render_buf.appendSlice(allocator, "\x1b[m");
                                }
                            }
                        }
                        col += spaces;
                    }

                    // Highlight selected newline at end of line
                    const newline_offset = line_start_offset + clean_line.len;
                    var newline_secondary = false;
                    for (editor.saved_cursors.items) |sc| {
                        const sc_offset = document.rope.pointToOffset(sc.pos);
                        if (sc_offset == newline_offset) {
                            newline_secondary = true;
                            break;
                        }
                    }

                    if (newline_secondary or editor.selection_manager.isOffsetSelected(newline_offset)) {
                        if (col >= char_start and col < char_start + screen_width) {
                            if (newline_secondary) {
                                try render_buf.appendSlice(allocator, "\x1b[7m \x1b[m");
                            } else {
                                try render_buf.appendSlice(allocator, "\x1b[48;5;239m \x1b[m");
                            }
                        }
                    }
                }
                try render_buf.appendSlice(allocator, "\x1b[K\r\n"); // Clear line and newline
            }

            // Draw Status Bar
            try render_buf.appendSlice(allocator, "\x1b[7m"); // Reverse video
            var status_content = std.ArrayList(u8).empty;
            defer status_content.deinit(allocator);

            const mode_str = switch (editor.current_mode) {
                .normal => "NORMAL",
                .insert => "INSERT",
                .visual => "VISUAL",
                .visual_line => "V-LINE",
                .command => "COMMAND",
            };

            if (editor.status_message) |msg| {
                try status_content.print(allocator, " -- {s} -- [File: {s}] | {s} ", .{ mode_str, filename, msg });
                if (editor.status_timer > 0) {
                    editor.status_timer -= 1;
                    if (editor.status_timer == 0) editor.status_message = null;
                }
            } else {
                try status_content.print(allocator, " -- {s} -- [File: {s}] | Cursor: {}:{} (Buf: {}:{}) | Total Lines: {} | ESC: Normal | i: Insert | Ctrl-S: Save", .{
                    mode_str,
                    filename,
                    display_cursor.row + 1,
                    display_cursor.col + 1,
                    editor.cursor_pos.row + 1,
                    editor.cursor_pos.column + 1,
                    total_newlines + 1,
                });
            }

            // Pad status bar
            if (status_content.items.len < screen_width) {
                try status_content.appendNTimes(allocator, ' ', screen_width - status_content.items.len);
            } else {
                status_content.items.len = screen_width;
            }
            try render_buf.appendSlice(allocator, status_content.items);
            try render_buf.appendSlice(allocator, "\x1b[m\x1b[K"); // Reset style

            if (editor.current_mode == .command) {
                try render_buf.print(allocator, "\r\n:{s}\x1b[K", .{editor.command_input.items});
            } else {
                try render_buf.appendSlice(allocator, "\r\n\x1b[K");
            }

            // Position Cursor
            if (editor.current_mode == .command) {
                try tui.positionCursor(&render_buf, screen_height, editor.command_input.items.len + 2);
            } else {
                const screen_row = display_cursor.row - editor.viewport_offset.row + 1;
                const screen_col = display_cursor.col - editor.viewport_offset.column + 1;
                try tui.positionCursor(&render_buf, screen_row, screen_col);
            }

            try tui.flush(render_buf.items);
        }

        // Read input using TUI helper
        const tui_key = (try tui.readKey()) orelse continue;

        // Process through editor
        const editor_key = mapTuiKeyToEditorKey(tui_key);
        const result = try editor.handleKey(editor_key, screen_width, screen_height);
        force_render = result.force_render;
        if (result.should_exit) break;

        if (result.save_requested) |save_filename| {
            const cwd = std.Io.Dir.cwd();
            const out_file = try cwd.createFile(io, save_filename, .{});
            defer out_file.close(io);
            var write_buf = std.ArrayList(u8).empty;
            defer write_buf.deinit(allocator);
            try document.rope.text(&write_buf);

            var write_buffer: [4096]u8 = undefined;
            var file_writer: std.Io.File.Writer = .init(out_file, io, &write_buffer);
            const save_writer = &file_writer.interface;
            try save_writer.writeAll(write_buf.items);
            try save_writer.flush();

            editor.status_message = "File Saved Successfully!";
            editor.status_timer = 3;
            force_render = true;
        }
    }

    // Reset cursor to make terminal clean on exit
    try tui.restore();
}
