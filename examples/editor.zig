const std = @import("std");
const sum_tree = @import("sum_tree");
const Rope = sum_tree.Rope;
const Point = sum_tree.Point;
const tui_lib = @import("tui.zig");
const Tui = tui_lib.Tui;
const Key = tui_lib.Key;

const Allocator = std.mem.Allocator;
const RenderCursor = sum_tree.SumTree(sum_tree.RopeChunk).Cursor(sum_tree.RopeChunk.Summary);
fn getLineWordStarts(allocator: Allocator, line: []const u8) !std.ArrayList(usize) {
    var starts = std.ArrayList(usize).empty;
    errdefer starts.deinit(allocator);

    var idx: usize = 0;
    while (idx < line.len) {
        const c = line[idx];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            idx += 1;
            continue;
        }

        // Start of a word or punctuation sequence
        try starts.append(allocator, idx);

        const start_class_word = std.ascii.isAlphanumeric(c) or c == '_';
        idx += 1;
        while (idx < line.len) {
            const next_c = line[idx];
            if (next_c == ' ' or next_c == '\t' or next_c == '\n' or next_c == '\r') {
                break;
            }
            const next_class_word = std.ascii.isAlphanumeric(next_c) or next_c == '_';
            if (next_class_word != start_class_word) {
                break; // Transition between word and punctuation
            }
            idx += 1;
        }
    }
    return starts;
}

fn capCursor(r: *Rope, pos: *Point, is_normal: bool) !void {
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(r.allocator);
    try r.lineText(pos.row, &line_buf);
    var line_len = line_buf.items.len;
    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
        line_len -= 1;
    }
    const max_col = if (is_normal) (if (line_len > 0) line_len - 1 else 0) else line_len;
    pos.column = @min(pos.column, max_col);
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

    var rope: *Rope = undefined;
    if (file_content) |content| {
        rope = try Rope.initFromString(allocator, content);
    } else {
        rope = try Rope.init(allocator);
    }
    defer rope.deinit();
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

    var wrap_enabled = true;
    const init_size = try tui.getScreenSize();
    var wrap_map = try sum_tree.WrapMap.init(allocator, init_size.width);
    defer wrap_map.deinit();
    try wrap_map.rewrapAll(init_size.width, rope);

    const EditorContext = struct {
        wrap_map: *sum_tree.WrapMap,
        rope: *Rope,
        render_cursor: *RenderCursor,
        tui: *Tui,
        wrap_enabled: *bool,
        
        fn onEdit(self: @This()) !void {
            const size = try self.tui.getScreenSize();
            self.render_cursor.* = RenderCursor.init(self.rope.tree);
            const target_width = if (self.wrap_enabled.*) size.width else 100000;
            try self.wrap_map.rewrapAll(target_width, self.rope);
        }

        fn onLineEdit(self: @This(), row: usize) !void {
            self.render_cursor.* = RenderCursor.init(self.rope.tree);
            try self.wrap_map.updateLine(row, self.rope);
        }
    };
    const ed_ctx = EditorContext{
        .wrap_map = wrap_map,
        .rope = rope,
        .render_cursor = &render_cursor,
        .tui = tui,
        .wrap_enabled = &wrap_enabled,
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

    var selection_manager = sum_tree.SelectionManager.init(allocator);
    defer selection_manager.deinit();
    var visual_anchor_pos = Point{ .row = 0, .column = 0 };

    const SavedCursor = struct {
        pos: Point,
        visual_anchor: ?Point,
        mode: Mode,
    };
    var saved_cursors = std.ArrayList(SavedCursor).empty;
    defer saved_cursors.deinit(allocator);

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
            try wrap_map.rewrapAll(if (wrap_enabled) screen_width else 100000, rope);
        }

        const total_newlines = rope.tree.root.summary.line_len;

        if (force_render) {
            force_render = false;

            // Sync selections
            selection_manager.clear();
            if (current_mode == .visual) {
                const total_char = rope.tree.root.summary.char_len;
                const head = rope.pointToOffset(cursor_pos);
                const tail = rope.pointToOffset(visual_anchor_pos);
                if (head >= tail) {
                    try selection_manager.addSelection(@min(head + 1, total_char), tail);
                } else {
                    try selection_manager.addSelection(head, @min(tail + 1, total_char));
                }
            } else if (current_mode == .visual_line) {
                const min_row = @min(cursor_pos.row, visual_anchor_pos.row);
                const max_row = @max(cursor_pos.row, visual_anchor_pos.row);
                const start_offset = rope.pointToOffset(Point{ .row = min_row, .column = 0 });
                const end_offset = if (max_row >= total_newlines)
                    rope.tree.root.summary.char_len
                else
                    rope.pointToOffset(Point{ .row = max_row + 1, .column = 0 });
                try selection_manager.addSelection(start_offset, end_offset);
            } else {
                const offset = rope.pointToOffset(cursor_pos);
                try selection_manager.addSelection(offset, offset);
            }

            for (saved_cursors.items) |sc| {
                if (sc.visual_anchor) |anchor| {
                    if (sc.mode == .visual) {
                        const total_char = rope.tree.root.summary.char_len;
                        const head = rope.pointToOffset(sc.pos);
                        const tail = rope.pointToOffset(anchor);
                        if (head >= tail) {
                            try selection_manager.addSelection(@min(head + 1, total_char), tail);
                        } else {
                            try selection_manager.addSelection(head, @min(tail + 1, total_char));
                        }
                    } else if (sc.mode == .visual_line) {
                        const min_row = @min(sc.pos.row, anchor.row);
                        const max_row = @max(sc.pos.row, anchor.row);
                        const start_offset = rope.pointToOffset(Point{ .row = min_row, .column = 0 });
                        const end_offset = if (max_row >= total_newlines)
                            rope.tree.root.summary.char_len
                        else
                            rope.pointToOffset(Point{ .row = max_row + 1, .column = 0 });
                        try selection_manager.addSelection(start_offset, end_offset);
                    }
                } else {
                    const offset = rope.pointToOffset(sc.pos);
                    try selection_manager.addSelection(offset, offset);
                }
            }

            // Viewport Scroll Constraints
            const display_cursor = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
            if (screen_height >= 3) {
                if (display_cursor.row < viewport_offset.row) {
                    viewport_offset.row = display_cursor.row;
                }
                if (display_cursor.row >= viewport_offset.row + screen_height - 2) {
                    viewport_offset.row = display_cursor.row - (screen_height - 3);
                }
            }
            if (wrap_enabled) {
                viewport_offset.column = 0;
            } else {
                if (display_cursor.col < viewport_offset.column) {
                    viewport_offset.column = display_cursor.col;
                }
                if (display_cursor.col >= viewport_offset.column + screen_width) {
                    viewport_offset.column = display_cursor.col - screen_width + 1;
                }
            }

            // Render Frame
            render_buf.clearRetainingCapacity();
            try tui.clear(&render_buf);

            var r: usize = 0;
            const render_limit = if (screen_height >= 2) screen_height - 2 else 0;
            while (r < render_limit) : (r += 1) {
                const display_row = viewport_offset.row + r;
                const start_pt = try wrap_map.displayToBuffer(.{ .row = display_row, .col = 0 }, rope);
                const total_lines = rope.tree.root.summary.line_len + 1;

                if (start_pt.row < total_lines) {
                    try rope.lineText(start_pt.row, &line_buf);

                    // Strip trailing newlines
                    var text_len = line_buf.items.len;
                    while (text_len > 0 and (line_buf.items[text_len - 1] == '\n' or line_buf.items[text_len - 1] == '\r')) {
                        text_len -= 1;
                    }
                    const clean_line = line_buf.items[0..text_len];

                    const display_start_for_line = (try wrap_map.bufferToDisplay(.{ .row = start_pt.row, .column = 0 }, rope)).row;
                    const sub_row = display_row - display_start_for_line;

                    const char_start = sub_row * (if (wrap_enabled) screen_width else wrap_map.wrap_width) + (if (wrap_enabled) 0 else viewport_offset.column);

                    // Offset of start of the line in the rope
                    const line_start_offset = rope.pointToOffset(Point{ .row = start_pt.row, .column = 0 });

                    var col: usize = 0;
                    for (clean_line, 0..) |char, raw_idx| {
                        const char_offset = line_start_offset + raw_idx;
                        const is_selected = selection_manager.isOffsetSelected(char_offset);

                        var is_secondary = false;
                        for (saved_cursors.items) |sc| {
                            const sc_offset = rope.pointToOffset(sc.pos);
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

                    // Highlight selected newline at end of line (rendered as a single highlighted space)
                    const newline_offset = line_start_offset + clean_line.len;
                    var newline_secondary = false;
                    for (saved_cursors.items) |sc| {
                        const sc_offset = rope.pointToOffset(sc.pos);
                        if (sc_offset == newline_offset) {
                            newline_secondary = true;
                            break;
                        }
                    }

                    if (newline_secondary or selection_manager.isOffsetSelected(newline_offset)) {
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
                const screen_col = display_cursor.col - viewport_offset.column + 1;
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
                    } else if (std.mem.eql(u8, cmd, "set wrap")) {
                        wrap_enabled = true;
                        try wrap_map.rewrapAll(screen_width, rope);
                        status_message = "Wrapping Enabled";
                        status_timer = 2;
                        current_mode = .normal;
                        command_input.clearRetainingCapacity();
                        force_render = true;
                    } else if (std.mem.eql(u8, cmd, "set nowrap")) {
                        wrap_enabled = false;
                        try wrap_map.rewrapAll(100000, rope);
                        status_message = "Wrapping Disabled";
                        status_timer = 2;
                        current_mode = .normal;
                        command_input.clearRetainingCapacity();
                        force_render = true;
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
                const offset = rope.undo() catch {
                    status_message = "Nothing to Undo!";
                    status_timer = 2;
                    force_render = true;
                    continue;
                };
                try ed_ctx.onEdit();
                cursor_pos = rope.offsetToPoint(offset);
                force_render = true;
            },
            .ctrl_y => {
                const offset = rope.redo() catch {
                    status_message = "Nothing to Redo!";
                    status_timer = 2;
                    force_render = true;
                    continue;
                };
                try ed_ctx.onEdit();
                cursor_pos = rope.offsetToPoint(offset);
                force_render = true;
            },
            .ctrl_r => {
                if (current_mode == .normal) {
                    const offset = rope.redo() catch {
                        status_message = "Nothing to Redo!";
                        status_timer = 2;
                        force_render = true;
                        continue;
                    };
                    try ed_ctx.onEdit();
                    cursor_pos = rope.offsetToPoint(offset);
                    force_render = true;
                }
            },
            .ctrl_d => {
                const has_selection = (current_mode == .visual or current_mode == .visual_line);
                try saved_cursors.append(allocator, .{
                    .pos = cursor_pos,
                    .visual_anchor = if (has_selection) visual_anchor_pos else null,
                    .mode = current_mode,
                });
                current_mode = .normal;
                force_render = true;
            },
            .escape => {
                saved_cursors.clearRetainingCapacity();
                if (current_mode != .normal) {
                    current_mode = .normal;
                    pending_op = null;
                    if (cursor_pos.column > 0) {
                        cursor_pos.column -= 1;
                    }
                }
                force_render = true;
            },
            .up => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                if (disp_pos.row > 0) {
                    cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, rope);
                    force_render = true;
                }
            },
            .down => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const total_display_rows = wrap_map.tree.root.summary.display_rows;
                if (disp_pos.row + 1 < total_display_rows) {
                    cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, rope);
                    force_render = true;
                }
            },
            .home => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, rope);
                force_render = true;
            },
            .end => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, rope);
                force_render = true;
            },
            .page_up => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const page = screen_height - 2;
                const target_row = if (disp_pos.row > page) disp_pos.row - page else 0;
                cursor_pos = try wrap_map.displayToBuffer(.{ .row = target_row, .col = disp_pos.col }, rope);
                force_render = true;
            },
            .page_down => {
                const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                const page = screen_height - 2;
                const total_display_rows = wrap_map.tree.root.summary.display_rows;
                const target_row = if (disp_pos.row + page < total_display_rows) disp_pos.row + page else (if (total_display_rows > 0) total_display_rows - 1 else 0);
                cursor_pos = try wrap_map.displayToBuffer(.{ .row = target_row, .col = disp_pos.col }, rope);
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
                        try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                        var line_len = line_buf.items.len;
                        while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                            line_len -= 1;
                        }
                        try rope.delete(offset, 1);
                        if (cursor_pos.column < line_len) {
                            try ed_ctx.onLineEdit(cursor_pos.row);
                        } else {
                            try ed_ctx.onEdit();
                        }
                        force_render = true;
                    }
                }
            },
            .backspace => {
                if (current_mode == .insert) {
                    if (cursor_pos.row > 0 or cursor_pos.column > 0) {
                        const offset = rope.pointToOffset(cursor_pos);
                        try rope.delete(offset - 1, 1);
                        if (cursor_pos.column > 0) {
                            cursor_pos.column -= 1;
                            try ed_ctx.onLineEdit(cursor_pos.row);
                        } else {
                            cursor_pos.row -= 1;
                            try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                            var line_len = line_buf.items.len;
                            while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                line_len -= 1;
                            }
                            cursor_pos.column = line_len;
                            try ed_ctx.onEdit();
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
                if (current_mode == .normal or current_mode == .visual or current_mode == .visual_line) {
                    if (seq.len == 1) {
                        const c = seq[0];
                        if (current_mode == .visual or current_mode == .visual_line) {
                            if (c == 'd' or c == 'x') {
                                if (selection_manager.getPrimary()) |sel| {
                                    try rope.delete(sel.start(), sel.end() - sel.start());
                                    current_mode = .normal;
                                    try ed_ctx.onEdit();
                                    const total_char = rope.tree.root.summary.char_len;
                                    cursor_pos = rope.offsetToPoint(@min(sel.start(), total_char));
                                    force_render = true;
                                }
                                continue;
                            }
                            if (c == 'h' or c == 'j' or c == 'k' or c == 'l' or
                                c == '0' or c == '$' or c == '^' or
                                c == '{' or c == '}' or c == 'g' or c == 'G' or
                                c == 'v' or c == 'V' or c == ':' or
                                c == 'w' or c == 'b')
                            {
                                // fall through
                            } else {
                                continue;
                            }
                        }
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
                                    const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    const total_display_rows = wrap_map.tree.root.summary.display_rows;
                                    if (disp_pos.row + 1 < total_display_rows) {
                                        cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, rope);
                                        force_render = true;
                                    }
                                },
                                'k' => {
                                    const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    if (disp_pos.row > 0) {
                                        cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, rope);
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
                                'w' => {
                                    try capCursor(rope, &cursor_pos, current_mode == .normal);

                                    // Get current line text
                                    try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    const line_text = line_buf.items[0..line_len];

                                    // Parse word starts
                                    var starts = try getLineWordStarts(allocator, line_text);
                                    defer starts.deinit(allocator);

                                    // Find next word start
                                    var next_col: ?usize = null;
                                    for (starts.items) |start| {
                                        if (start > cursor_pos.column) {
                                            next_col = start;
                                            break;
                                        }
                                    }

                                    if (next_col) |col| {
                                        cursor_pos.column = col;
                                    } else {
                                        // Go to next line column 0
                                        if (cursor_pos.row < total_newlines) {
                                            cursor_pos.row += 1;
                                            cursor_pos.column = 0;
                                        }
                                    }
                                    force_render = true;
                                },
                                'b' => {
                                    try capCursor(rope, &cursor_pos, current_mode == .normal);

                                    if (cursor_pos.column == 0) {
                                        // Move to previous line at last column
                                        if (cursor_pos.row > 0) {
                                            cursor_pos.row -= 1;
                                            try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                            var prev_len = line_buf.items.len;
                                            while (prev_len > 0 and (line_buf.items[prev_len - 1] == '\n' or line_buf.items[prev_len - 1] == '\r')) {
                                                prev_len -= 1;
                                            }
                                            const max_col = if (current_mode == .normal) (if (prev_len > 0) prev_len - 1 else 0) else prev_len;
                                            cursor_pos.column = max_col;
                                        }
                                    } else {
                                        // Get current line text
                                        try getLineText(rope, &render_cursor, cursor_pos.row, &line_buf);
                                        var line_len = line_buf.items.len;
                                        while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                            line_len -= 1;
                                        }
                                        const line_text = line_buf.items[0..line_len];

                                        var starts = try getLineWordStarts(allocator, line_text);
                                        defer starts.deinit(allocator);

                                        // Find the last start offset that is strictly less than current column
                                        var prev_col: ?usize = null;
                                        for (starts.items) |start| {
                                            if (start < cursor_pos.column) {
                                                prev_col = start;
                                            } else {
                                                break;
                                            }
                                        }

                                        if (prev_col) |col| {
                                            cursor_pos.column = col;
                                        } else {
                                            // Move to start of current line
                                            cursor_pos.column = 0;
                                        }
                                    }
                                    force_render = true;
                                },
                                'x' => {
                                    const offset = rope.pointToOffset(cursor_pos);
                                    const total_char = rope.tree.root.summary.char_len;
                                    if (offset < total_char) {
                                        try rope.delete(offset, 1);
                                        try ed_ctx.onLineEdit(cursor_pos.row);
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
                                    const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, rope);
                                    force_render = true;
                                },
                                '$' => {
                                    const disp_pos = try wrap_map.bufferToDisplay(.{ .row = cursor_pos.row, .column = cursor_pos.column }, rope);
                                    cursor_pos = try wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, rope);
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
                                    const offset = rope.undo() catch {
                                        status_message = "Nothing to Undo!";
                                        status_timer = 2;
                                        force_render = true;
                                        continue;
                                    };
                                    try ed_ctx.onEdit();
                                    cursor_pos = rope.offsetToPoint(offset);
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
                                    if (current_mode == .visual) {
                                        current_mode = .normal;
                                    } else {
                                        current_mode = .visual;
                                        visual_anchor_pos = cursor_pos;
                                    }
                                    force_render = true;
                                },
                                'V' => {
                                    if (current_mode == .visual_line) {
                                        current_mode = .normal;
                                    } else {
                                        current_mode = .visual_line;
                                        visual_anchor_pos = cursor_pos;
                                    }
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
                    try ed_ctx.onLineEdit(cursor_pos.row);
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
