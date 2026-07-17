const std = @import("std");
const sum_tree = @import("sum_tree");
const Rope = sum_tree.Rope;
const Point = sum_tree.Point;
const tui_lib = @import("tui.zig");
const Tui = tui_lib.Tui;
const Key = tui_lib.Key;

const Allocator = std.mem.Allocator;
const RenderCursor = sum_tree.SumTree(sum_tree.RopeChunk).Cursor(sum_tree.RopeChunk.Summary);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next(); // skips the executable name
    const filename = args.next() orelse "untitled.txt";

    const rope = try Rope.init(allocator);
    defer rope.deinit();

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

    rope.setEnableHistory(false);
    if (file_content) |content| {
        try rope.insert(0, content);
    }
    rope.setEnableHistory(true);

    // 2. Initialize TUI helper (handles Raw mode)
    var tui = try Tui.init(io, allocator);
    defer tui.deinit();

    // 3. Editor State
    var cursor_pos = Point{ .row = 0, .column = 0 };
    var viewport_offset = Point{ .row = 0, .column = 0 };
    var status_message: ?[]const u8 = null;
    var status_timer: usize = 0;

    var render_buf = std.ArrayList(u8).empty;
    defer render_buf.deinit(allocator);

    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    var force_render = true;
    var prev_screen_width: usize = 0;
    var prev_screen_height: usize = 0;

    // Persist render_cursor outside main loop
    var render_cursor = RenderCursor.init(rope.tree);

    const init_size = try tui.getScreenSize();
    var wrap_map = try sum_tree.WrapMap.init(allocator, init_size.width);
    defer wrap_map.deinit();
    try wrap_map.rewrapAll(init_size.width, rope);

    const EditorContext = struct {
        wrap_map: *sum_tree.WrapMap,
        rope: *Rope,
        render_cursor: *RenderCursor,
        tui: *Tui,
        
        fn onEdit(self: @This()) !void {
            const size = try self.tui.getScreenSize();
            self.render_cursor.* = RenderCursor.init(self.rope.tree);
            try self.wrap_map.rewrapAll(size.width, self.rope);
        }
    };
    const ed_ctx = EditorContext{
        .wrap_map = wrap_map,
        .rope = rope,
        .render_cursor = &render_cursor,
        .tui = tui,
    };

    // Helper to get line text reusing the persistent render_cursor
    const getLineText = struct {
        fn call(r: *Rope, rc: *RenderCursor, row: usize, buf: *std.ArrayList(u8)) !void {
            _ = rc;
            try r.lineText(row, buf);
        }
    }.call;

    // Helper to check if a line is empty
    const isLineEmpty = struct {
        fn call(r: *Rope, rc: *RenderCursor, row: usize, buf: *std.ArrayList(u8)) !bool {
            _ = rc;
            try r.lineText(row, buf);
            var len = buf.items.len;
            while (len > 0 and (buf.items[len - 1] == '\n' or buf.items[len - 1] == '\r')) {
                len -= 1;
            }
            return len == 0;
        }
    }.call;

    // Vim Modes
    const Mode = enum {
        normal,
        insert,
        visual,
        visual_line,
        command,
    };
    var current_mode = Mode.normal;
    var pending_op: ?u8 = null;
    var command_input = std.ArrayList(u8).empty;
    defer command_input.deinit(allocator);

    // 4. Main Event Loop
    while (true) {
        // Query Terminal Size via Tui helper
        const size = try tui.getScreenSize();
        const screen_width = size.width;
        const screen_height = size.height;

        if (screen_width != prev_screen_width or screen_height != prev_screen_height) {
            force_render = true;
            prev_screen_width = screen_width;
            prev_screen_height = screen_height;
            try wrap_map.rewrapAll(screen_width, rope);
        }

        const total_newlines = rope.tree.root.summary.line_len;

        if (force_render) {
            force_render = false;

            // Viewport Scroll Constraints
            const display_cursor = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
            if (screen_height >= 3) {
                if (display_cursor.row < viewport_offset.row) {
                    viewport_offset.row = display_cursor.row;
                }
                if (display_cursor.row >= viewport_offset.row + screen_height - 2) {
                    viewport_offset.row = display_cursor.row - (screen_height - 3);
                }
            }
            viewport_offset.column = 0;

            // Render Frame
            render_buf.clearRetainingCapacity();
            try tui.clear(&render_buf);

            var r: usize = 0;
            const render_limit = if (screen_height >= 2) screen_height - 2 else 0;
            while (r < render_limit) : (r += 1) {
                const display_row = viewport_offset.row + r;
                const start_pt = wrap_map.displayToBuffer(.{ .row = display_row, .col = 0 }, rope);
                const total_lines = rope.tree.root.summary.line_len + 1;

                if (start_pt.row < total_lines) {
                    try rope.lineText(start_pt.row, &line_buf);

                    // Strip trailing newlines
                    var text_len = line_buf.items.len;
                    while (text_len > 0 and (line_buf.items[text_len - 1] == '\n' or line_buf.items[text_len - 1] == '\r')) {
                        text_len -= 1;
                    }
                    const clean_line = line_buf.items[0..text_len];

                    // Expand tabs to spaces
                    var expanded_line = std.ArrayList(u8).empty;
                    defer expanded_line.deinit(allocator);
                    try sum_tree.expandTabs(allocator, clean_line, 4, &expanded_line);

                    const display_start_for_line = wrap_map.bufferToDisplay(.{ .row = start_pt.row, .column = 0 }, rope).row;
                    const sub_row = display_row - display_start_for_line;

                    const char_start = sub_row * screen_width;
                    if (char_start < expanded_line.items.len) {
                        const visible_len = @min(expanded_line.items.len - char_start, screen_width);
                        try render_buf.appendSlice(allocator, expanded_line.items[char_start .. char_start + visible_len]);
                    }
                }
                try render_buf.appendSlice(allocator, "\x1b[K\r\n"); // Clear line and newline
            }

            // Draw Status Bar
            try render_buf.appendSlice(allocator, "\x1b[7m"); // Reverse video
            var status_content = std.ArrayList(u8).empty;
            defer status_content.deinit(allocator);

            const mode_str = switch (current_mode) {
                .normal => "NORMAL",
                .insert => "INSERT",
                .visual => "VISUAL",
                .visual_line => "V-LINE",
                .command => "COMMAND",
            };

            if (status_message) |msg| {
                try status_content.print(allocator, " -- {s} -- [File: {s}] | {s} ", .{ mode_str, filename, msg });
                if (status_timer > 0) {
                    status_timer -= 1;
                    if (status_timer == 0) status_message = null;
                }
            } else {
                try status_content.print(allocator, " -- {s} -- [File: {s}] | Cursor: {}:{} (Buf: {}:{}) | Total Lines: {} | ESC: Normal | i: Insert | Ctrl-S: Save", .{
                    mode_str,
                    filename,
                    display_cursor.row + 1,
                    display_cursor.col + 1,
                    cursor_pos.row + 1,
                    cursor_pos.column + 1,
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

            if (current_mode == .command) {
                try render_buf.print(allocator, "\r\n:{s}\x1b[K", .{command_input.items});
            } else {
                try render_buf.appendSlice(allocator, "\r\n\x1b[K");
            }

            // Position Cursor
            if (current_mode == .command) {
                try tui.positionCursor(&render_buf, screen_height, command_input.items.len + 2);
            } else {
                const screen_row = display_cursor.row - viewport_offset.row + 1;
                const screen_col = display_cursor.col + 1;
                try tui.positionCursor(&render_buf, screen_row, screen_col);
            }

            try tui.flush(render_buf.items);
        }

        // Read input using TUI helper
        const key = (try tui.readKey()) orelse continue;

        if (current_mode == .command) {
            switch (key) {
                .escape => {
                    current_mode = .normal;
                    command_input.clearRetainingCapacity();
                    force_render = true;
                    continue;
                },
                .enter => {
                    const cmd = std.mem.trim(u8, command_input.items, " :");
                    if (std.mem.eql(u8, cmd, "w")) {
                        const cwd = std.Io.Dir.cwd();
                        const out_file = try cwd.createFile(io, filename, .{});
                        defer out_file.close(io);
                        var write_buf = std.ArrayList(u8).empty;
                        defer write_buf.deinit(allocator);
                        try rope.text(&write_buf);

                        var write_buffer: [4096]u8 = undefined;
                        var file_writer: std.Io.File.Writer = .init(out_file, io, &write_buffer);
                        const save_writer = &file_writer.interface;
                        try save_writer.writeAll(write_buf.items);
                        try save_writer.flush();

                        status_message = "File Saved Successfully!";
                        status_timer = 3;
                        current_mode = .normal;
                        command_input.clearRetainingCapacity();
                        force_render = true;
                    } else if (std.mem.eql(u8, cmd, "q")) {
                        break;
                    } else if (std.mem.eql(u8, cmd, "wq")) {
                        const cwd = std.Io.Dir.cwd();
                        const out_file = try cwd.createFile(io, filename, .{});
                        defer out_file.close(io);
                        var write_buf = std.ArrayList(u8).empty;
                        defer write_buf.deinit(allocator);
                        try rope.text(&write_buf);

                        var write_buffer: [4096]u8 = undefined;
                        var file_writer: std.Io.File.Writer = .init(out_file, io, &write_buffer);
                        const save_writer = &file_writer.interface;
                        try save_writer.writeAll(write_buf.items);
                        try save_writer.flush();

                        break;
                    } else {
                        status_message = "Unknown Command!";
                        status_timer = 2;
                        current_mode = .normal;
                        command_input.clearRetainingCapacity();
                        force_render = true;
                    }
                    continue;
                },
                .backspace => {
                    if (command_input.items.len > 0) {
                        _ = command_input.pop();
                    } else {
                        current_mode = .normal;
                    }
                    force_render = true;
                    continue;
                },
                .char => |ch| {
                    const seq = ch.buf[0..ch.len];
                    try command_input.appendSlice(allocator, seq);
                    force_render = true;
                    continue;
                },
                .ctrl_c, .ctrl_q => break,
                else => continue,
            }
        }

        switch (key) {
            .ctrl_c, .ctrl_q => break,
            .ctrl_s => {
                const cwd = std.Io.Dir.cwd();
                const out_file = try cwd.createFile(io, filename, .{});
                defer out_file.close(io);
                var write_buf = std.ArrayList(u8).empty;
                defer write_buf.deinit(allocator);
                try rope.text(&write_buf);

                var write_buffer: [4096]u8 = undefined;
                var file_writer: std.Io.File.Writer = .init(out_file, io, &write_buffer);
                const save_writer = &file_writer.interface;
                try save_writer.writeAll(write_buf.items);
                try save_writer.flush();

                status_message = "File Saved Successfully!";
                status_timer = 3;
                force_render = true;
            },
            .ctrl_z => {
                rope.undo() catch {
                    status_message = "Nothing to Undo!";
                    status_timer = 2;
                    force_render = true;
                    continue;
                };
                try ed_ctx.onEdit();
                cursor_pos = rope.offsetToPoint(rope.pointToOffset(cursor_pos));
                force_render = true;
            },
            .ctrl_y => {
                rope.redo() catch {
                    status_message = "Nothing to Redo!";
                    status_timer = 2;
                    force_render = true;
                    continue;
                };
                try ed_ctx.onEdit();
                cursor_pos = rope.offsetToPoint(rope.pointToOffset(cursor_pos));
                force_render = true;
            },
            .ctrl_r => {
                if (current_mode == .normal) {
                    rope.redo() catch {
                        status_message = "Nothing to Redo!";
                        status_timer = 2;
                        force_render = true;
                        continue;
                    };
                    try ed_ctx.onEdit();
                    cursor_pos = rope.offsetToPoint(rope.pointToOffset(cursor_pos));
                    force_render = true;
                }
            },
            .escape => {
                if (current_mode != .normal) {
                    current_mode = .normal;
                    pending_op = null;
                    if (cursor_pos.column > 0) {
                        cursor_pos.column -= 1;
                    }
                    force_render = true;
                }
            },
            .up => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                if (disp_pos.row > 0) {
                    cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, rope);
                    force_render = true;
                }
            },
            .down => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const total_display_rows = wrap_map.tree.root.summary.display_rows;
                if (disp_pos.row + 1 < total_display_rows) {
                    cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, rope);
                    force_render = true;
                }
            },
            .home => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, rope);
                force_render = true;
            },
            .end => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, rope);
                force_render = true;
            },
            .page_up => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const page = screen_height - 2;
                const target_row = if (disp_pos.row > page) disp_pos.row - page else 0;
                cursor_pos = wrap_map.displayToBuffer(.{ .row = target_row, .col = disp_pos.col }, rope);
                force_render = true;
            },
            .page_down => {
                const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const page = screen_height - 2;
                const total_display_rows = wrap_map.tree.root.summary.display_rows;
                const target_row = if (disp_pos.row + page < total_display_rows) disp_pos.row + page else (if (total_display_rows > 0) total_display_rows - 1 else 0);
                cursor_pos = wrap_map.displayToBuffer(.{ .row = target_row, .col = disp_pos.col }, rope);
                force_render = true;
            },
            .right => {
                try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                var line_len = line_buf.items.len;
                while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                    line_len -= 1;
                }
                if (cursor_pos.column < line_len) {
                    cursor_pos.column += 1;
                    force_render = true;
                } else if (cursor_pos.row < total_newlines) {
                    cursor_pos.row += 1;
                    cursor_pos.column = 0;
                    force_render = true;
                }
            },
            .left => {
                if (cursor_pos.column > 0) {
                    cursor_pos.column -= 1;
                    force_render = true;
                } else if (cursor_pos.row > 0) {
                    cursor_pos.row -= 1;
                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                    var line_len = line_buf.items.len;
                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                        line_len -= 1;
                    }
                    cursor_pos.column = line_len;
                    force_render = true;
                }
            },
            .delete => {
                if (current_mode == .insert) {
                    const offset = rope.pointToOffset(cursor_pos);
                    const total_char = rope.tree.root.summary.char_len;
                    if (offset < total_char) {
                        try rope.delete(offset, 1);
                        try ed_ctx.onEdit();
                        force_render = true;
                    }
                }
            },
            .backspace => {
                if (current_mode == .insert) {
                    if (cursor_pos.row > 0 or cursor_pos.column > 0) {
                        const offset = rope.pointToOffset(cursor_pos);
                        try rope.delete(offset - 1, 1);
                        try ed_ctx.onEdit();
                        if (cursor_pos.column > 0) {
                            cursor_pos.column -= 1;
                        } else {
                            cursor_pos.row -= 1;
                            try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                            var line_len = line_buf.items.len;
                            while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                line_len -= 1;
                            }
                            cursor_pos.column = line_len;
                        }
                        force_render = true;
                    }
                }
            },
            .enter => {
                if (current_mode == .insert) {
                    const offset = rope.pointToOffset(cursor_pos);
                    try rope.insert(offset, "\n");
                    try ed_ctx.onEdit();
                    cursor_pos.row += 1;
                    cursor_pos.column = 0;
                    force_render = true;
                }
            },
            .char => |ch| {
                const seq = ch.buf[0..ch.len];
                if (current_mode == .normal) {
                    if (seq.len == 1) {
                        const c = seq[0];
                        if (pending_op) |op| {
                            if (op == 'd' and c == 'd') {
                                // dd: delete current line
                                try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                const start_offset = rope.pointToOffset(Point{ .row = cursor_pos.row, .column = 0 });

                                const end_offset = if (cursor_pos.row >= total_newlines)
                                    rope.tree.root.summary.char_len
                                else
                                    rope.pointToOffset(Point{ .row = cursor_pos.row + 1, .column = 0 });

                                if (end_offset > start_offset) {
                                    try rope.delete(start_offset, end_offset - start_offset);
                                    try ed_ctx.onEdit();
                                    // Recalculate line count after deletion
                                    const new_newlines = rope.tree.root.summary.line_len;
                                    if (cursor_pos.row > 0 and cursor_pos.row >= new_newlines) {
                                        cursor_pos.row = new_newlines;
                                    }
                                    cursor_pos.column = 0;
                                    force_render = true;
                                }
                                pending_op = null;
                            } else if (op == 'g' and c == 'g') {
                                cursor_pos.row = 0;
                                cursor_pos.column = 0;
                                force_render = true;
                                pending_op = null;
                            } else {
                                pending_op = null;
                            }
                        } else {
                            switch (c) {
                                'i' => {
                                    current_mode = .insert;
                                    force_render = true;
                                },
                                'a' => {
                                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    if (cursor_pos.column < line_len) {
                                        cursor_pos.column += 1;
                                    }
                                    current_mode = .insert;
                                    force_render = true;
                                },
                                'o' => {
                                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    cursor_pos.column = line_len;
                                    const offset = rope.pointToOffset(cursor_pos);
                                    try rope.insert(offset, "\n");
                                    try ed_ctx.onEdit();
                                    cursor_pos.row += 1;
                                    cursor_pos.column = 0;
                                    current_mode = .insert;
                                    force_render = true;
                                },
                                'O' => {
                                    cursor_pos.column = 0;
                                    const offset = rope.pointToOffset(cursor_pos);
                                    try rope.insert(offset, "\n");
                                    try ed_ctx.onEdit();
                                    cursor_pos.column = 0;
                                    current_mode = .insert;
                                    force_render = true;
                                },
                                'h' => {
                                    if (cursor_pos.column > 0) {
                                        cursor_pos.column -= 1;
                                        force_render = true;
                                    }
                                },
                                'j' => {
                                    const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    const total_display_rows = wrap_map.tree.root.summary.display_rows;
                                    if (disp_pos.row + 1 < total_display_rows) {
                                        cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, rope);
                                        force_render = true;
                                    }
                                },
                                'k' => {
                                    const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    if (disp_pos.row > 0) {
                                        cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, rope);
                                        force_render = true;
                                    }
                                },
                                'l' => {
                                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    const max_col = if (line_len > 0) line_len - 1 else 0;
                                    if (cursor_pos.column < max_col) {
                                        cursor_pos.column += 1;
                                        force_render = true;
                                    }
                                },
                                'x' => {
                                    const offset = rope.pointToOffset(cursor_pos);
                                    const total_char = rope.tree.root.summary.char_len;
                                    if (offset < total_char) {
                                        try rope.delete(offset, 1);
                                        try ed_ctx.onEdit();
                                        try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                        var line_len = line_buf.items.len;
                                        while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                            line_len -= 1;
                                        }
                                        const max_col = if (line_len > 0) line_len - 1 else 0;
                                        cursor_pos.column = @min(cursor_pos.column, max_col);
                                        force_render = true;
                                    }
                                },
                                '0' => {
                                    const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, rope);
                                    force_render = true;
                                },
                                '$' => {
                                    const disp_pos = wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    cursor_pos = wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, rope);
                                    force_render = true;
                                },
                                '^' => {
                                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                    var idx: usize = 0;
                                    while (idx < line_buf.items.len) : (idx += 1) {
                                        const char = line_buf.items[idx];
                                        if (char != ' ' and char != '\t') {
                                            break;
                                        }
                                    }
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    cursor_pos.column = if (idx < line_len) idx else if (line_len > 0) line_len - 1 else 0;
                                    force_render = true;
                                },
                                '{' => {
                                    if (cursor_pos.row > 0) {
                                        var r_idx = cursor_pos.row;
                                        const current_is_empty = try isLineEmpty(rope, &render_cursor, r_idx, &line_buf);
                                        if (current_is_empty) {
                                            while (r_idx > 0) {
                                                if (try isLineEmpty(rope, &render_cursor, r_idx - 1, &line_buf)) {
                                                    r_idx -= 1;
                                                } else {
                                                    break;
                                                }
                                            }
                                            if (r_idx > 0) {
                                                r_idx -= 1;
                                                while (r_idx > 0) {
                                                    if (try isLineEmpty(rope, &render_cursor, r_idx, &line_buf)) {
                                                        break;
                                                    }
                                                    r_idx -= 1;
                                                }
                                            }
                                        } else {
                                            while (r_idx > 0) {
                                                r_idx -= 1;
                                                if (try isLineEmpty(rope, &render_cursor, r_idx, &line_buf)) {
                                                    break;
                                                }
                                            }
                                        }
                                        cursor_pos.row = r_idx;
                                        cursor_pos.column = 0;
                                        force_render = true;
                                    }
                                },
                                '}' => {
                                    if (cursor_pos.row < total_newlines) {
                                        var r_idx = cursor_pos.row;
                                        const current_is_empty = try isLineEmpty(rope, &render_cursor, r_idx, &line_buf);
                                        if (current_is_empty) {
                                            while (r_idx < total_newlines) {
                                                if (try isLineEmpty(rope, &render_cursor, r_idx + 1, &line_buf)) {
                                                    r_idx += 1;
                                                } else {
                                                    break;
                                                }
                                            }
                                            if (r_idx < total_newlines) {
                                                r_idx += 1;
                                                while (r_idx < total_newlines) {
                                                    if (try isLineEmpty(rope, &render_cursor, r_idx, &line_buf)) {
                                                        break;
                                                    }
                                                    r_idx += 1;
                                                }
                                            }
                                        } else {
                                            while (r_idx < total_newlines) {
                                                r_idx += 1;
                                                if (try isLineEmpty(rope, &render_cursor, r_idx, &line_buf)) {
                                                    break;
                                                }
                                            }
                                        }
                                        cursor_pos.row = r_idx;
                                        cursor_pos.column = 0;
                                        force_render = true;
                                    }
                                },
                                'u' => {
                                    rope.undo() catch {
                                        status_message = "Nothing to Undo!";
                                        status_timer = 2;
                                        force_render = true;
                                        continue;
                                    };
                                    try ed_ctx.onEdit();
                                    cursor_pos = rope.offsetToPoint(rope.pointToOffset(cursor_pos));
                                    force_render = true;
                                },
                                'd' => {
                                    pending_op = 'd';
                                },
                                'g' => {
                                    pending_op = 'g';
                                },
                                'G' => {
                                    cursor_pos.row = total_newlines;
                                    cursor_pos.column = 0;
                                    force_render = true;
                                },
                                'v' => {
                                    current_mode = .visual;
                                    force_render = true;
                                },
                                'V' => {
                                    current_mode = .visual_line;
                                    force_render = true;
                                },
                                ':' => {
                                    current_mode = .command;
                                    command_input.clearRetainingCapacity();
                                    force_render = true;
                                },
                                else => {},
                            }
                        }
                    }
                } else {
                    const offset = rope.pointToOffset(cursor_pos);
                    try rope.insert(offset, seq);
                    try ed_ctx.onEdit();
                    cursor_pos.column += seq.len;
                    force_render = true;
                }
            },
            .other => {},
        }
    }

    // Reset cursor to make terminal clean on exit
    try tui.restore();
}
