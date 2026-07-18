const std = @import("std");
const Rope = @import("Rope.zig").Rope;
const Point = @import("Rope.zig").Point;
const WrapMap = @import("WrapMap.zig").WrapMap;
const SelectionManager = @import("Selection.zig").SelectionManager;
const Selection = @import("Selection.zig").Selection;
const Document = @import("Document.zig").Document;
const RopeChunk = @import("Rope.zig").RopeChunk;
const SumTree = @import("SumTree.zig").SumTree;
const RenderCursor = SumTree(RopeChunk).Cursor(RopeChunk.Summary);

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    command,
};

pub const SavedCursor = struct {
    pos: Point,
    visual_anchor: ?Point,
    mode: Mode,
};

pub const Key = union(enum) {
    char: struct {
        buf: [8]u8,
        len: u8,
    },
    escape,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    delete,
    backspace,
    enter,
    ctrl_c,
    ctrl_d,
    ctrl_q,
    ctrl_s,
    ctrl_z,
    ctrl_y,
    ctrl_r,
    other,
};

pub const Result = struct {
    force_render: bool,
    should_exit: bool,
    save_requested: ?[]const u8, // If a filename is requested to be saved
};

pub const Replacement = struct {
    cursor_idx: usize,
    start: usize,
    end: usize,
    insert_text: []const u8,
};

pub const Editor = struct {
    allocator: Allocator,
    document: *Document,
    cursor_pos: Point,
    visual_anchor_pos: Point,
    current_mode: Mode,
    saved_cursors: std.ArrayList(SavedCursor),
    selection_manager: SelectionManager,
    viewport_offset: Point,
    pending_op: ?u8,
    command_input: std.ArrayList(u8),
    wrap_map: *WrapMap,
    wrap_enabled: bool,
    status_message: ?[]const u8,
    status_timer: usize,

    pub fn init(allocator: Allocator, document: *Document, wrap_width: usize) !*Editor {
        const self = try allocator.create(Editor);
        errdefer allocator.destroy(self);

        var saved_cursors = std.ArrayList(SavedCursor).empty;
        errdefer saved_cursors.deinit(allocator);

        var command_input = std.ArrayList(u8).empty;
        errdefer command_input.deinit(allocator);

        var wrap_map = try WrapMap.init(allocator, wrap_width);
        errdefer wrap_map.deinit();
        try wrap_map.rewrapAll(wrap_width, document.rope);

        var selection_manager = SelectionManager.init(allocator);
        errdefer selection_manager.deinit();

        self.* = .{
            .allocator = allocator,
            .document = document,
            .cursor_pos = Point{ .row = 0, .column = 0 },
            .visual_anchor_pos = Point{ .row = 0, .column = 0 },
            .current_mode = .normal,
            .saved_cursors = saved_cursors,
            .selection_manager = selection_manager,
            .viewport_offset = Point{ .row = 0, .column = 0 },
            .pending_op = null,
            .command_input = command_input,
            .wrap_map = wrap_map,
            .wrap_enabled = true,
            .status_message = null,
            .status_timer = 0,
        };
        return self;
    }

    pub fn deinit(self: *Editor) void {
        self.saved_cursors.deinit(self.allocator);
        self.command_input.deinit(self.allocator);
        self.wrap_map.deinit();
        self.selection_manager.deinit();
        self.allocator.destroy(self);
    }

    pub fn setDocument(self: *Editor, doc: *Document, wrap_width: usize) !void {
        self.document = doc;
        try self.wrap_map.rewrapAll(wrap_width, doc.rope);
        self.cursor_pos = Point{ .row = 0, .column = 0 };
        self.visual_anchor_pos = Point{ .row = 0, .column = 0 };
        self.current_mode = .normal;
        self.saved_cursors.clearRetainingCapacity();
        self.selection_manager.clear();
        self.viewport_offset = Point{ .row = 0, .column = 0 };
        self.pending_op = null;
    }

    pub fn syncSelections(self: *Editor) !void {
        self.selection_manager.clear();
        if (self.current_mode == .visual or self.current_mode == .visual_line) {
            const head = self.document.rope.pointToOffset(self.cursor_pos);
            const tail = self.document.rope.pointToOffset(self.visual_anchor_pos);
            try self.selection_manager.addSelection(head, tail);
        }
        for (self.saved_cursors.items) |sc| {
            if (sc.visual_anchor) |va| {
                const head = self.document.rope.pointToOffset(sc.pos);
                const tail = self.document.rope.pointToOffset(va);
                try self.selection_manager.addSelection(head, tail);
            }
        }
    }

    fn getLineText(self: *Editor, row: usize, buf: *std.ArrayList(u8)) !void {
        try self.document.rope.lineText(row, buf);
    }

    fn isLineEmpty(self: *Editor, row: usize, buf: *std.ArrayList(u8)) !bool {
        try self.document.rope.lineText(row, buf);
        var len = buf.items.len;
        while (len > 0 and (buf.items[len - 1] == '\n' or buf.items[len - 1] == '\r')) {
            len -= 1;
        }
        return len == 0;
    }

    fn capCursorPos(self: *Editor, pos: *Point, is_normal: bool) !void {
        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(self.allocator);
        try self.getLineText(pos.row, &line_buf);
        var line_len = line_buf.items.len;
        while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
            line_len -= 1;
        }
        const max_col = if (is_normal) (if (line_len > 0) line_len - 1 else 0) else line_len;
        pos.column = @min(pos.column, max_col);
    }

    fn getSelectionRange(self: *Editor, pos: Point, anchor: ?Point, mode: Mode) struct { start: usize, end: usize } {
        const total_char = self.document.rope.tree.root.summary.char_len;
        const total_newlines = self.document.rope.tree.root.summary.line_len;
        if (anchor) |anc| {
            if (mode == .visual) {
                const head = self.document.rope.pointToOffset(pos);
                const tail = self.document.rope.pointToOffset(anc);
                const start = @min(head, tail);
                const end = @min(@max(head, tail) + 1, total_char);
                return .{ .start = start, .end = end };
            } else if (mode == .visual_line) {
                const min_row = @min(pos.row, anc.row);
                const max_row = @max(pos.row, anc.row);
                const start = self.document.rope.pointToOffset(Point{ .row = min_row, .column = 0 });
                const end = if (max_row >= total_newlines)
                    total_char
                else
                    self.document.rope.pointToOffset(Point{ .row = max_row + 1, .column = 0 });
                return .{ .start = start, .end = end };
            }
        }
        const offset = self.document.rope.pointToOffset(pos);
        return .{ .start = offset, .end = offset };
    }

    fn getLineWordStarts(self: *Editor, line: []const u8) !std.ArrayList(usize) {
        var starts = std.ArrayList(usize).empty;
        errdefer starts.deinit(self.allocator);

        var idx: usize = 0;
        while (idx < line.len) {
            const c = line[idx];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                idx += 1;
                continue;
            }

            try starts.append(self.allocator, idx);

            const start_class_word = std.ascii.isAlphanumeric(c) or c == '_';
            idx += 1;
            while (idx < line.len) {
                const next_c = line[idx];
                if (next_c == ' ' or next_c == '\t' or next_c == '\n' or next_c == '\r') {
                    break;
                }
                const next_class_word = std.ascii.isAlphanumeric(next_c) or next_c == '_';
                if (next_class_word != start_class_word) {
                    break;
                }
                idx += 1;
            }
        }
        return starts;
    }

    pub fn applyMultiCursorReplacement(
        self: *Editor,
        replacements: []const Replacement,
        push_at_start: bool,
    ) !void {
        if (replacements.len == 0) return;

        const CursorOffsets = struct {
            pos: usize,
            anchor: ?usize,
        };
        var offsets = try self.allocator.alloc(CursorOffsets, 1 + self.saved_cursors.items.len);
        defer self.allocator.free(offsets);

        offsets[0] = .{
            .pos = self.document.rope.pointToOffset(self.cursor_pos),
            .anchor = if (self.current_mode == .visual or self.current_mode == .visual_line) self.document.rope.pointToOffset(self.visual_anchor_pos) else null,
        };
        for (self.saved_cursors.items, 0..) |sc, idx| {
            offsets[idx + 1] = .{
                .pos = self.document.rope.pointToOffset(sc.pos),
                .anchor = if (sc.visual_anchor) |va| self.document.rope.pointToOffset(va) else null,
            };
        }

        var sorted_reps = std.ArrayList(Replacement).empty;
        defer sorted_reps.deinit(self.allocator);
        try sorted_reps.appendSlice(self.allocator, replacements);

        const sort_func = struct {
            fn lessThan(_: void, lhs: Replacement, rhs: Replacement) bool {
                return lhs.start > rhs.start;
            }
        }.lessThan;
        std.mem.sort(Replacement, sorted_reps.items, {}, sort_func);

        self.document.rope.setEnableHistory(false);
        defer self.document.rope.setEnableHistory(true);

        for (sorted_reps.items) |rep| {
            const del_len = rep.end - rep.start;
            if (del_len > 0) {
                try self.document.rope.delete(rep.start, del_len);
            }
            if (rep.insert_text.len > 0) {
                try self.document.rope.insert(rep.start, rep.insert_text);
            }

            const delta_len = @as(isize, @intCast(rep.insert_text.len)) - @as(isize, @intCast(del_len));
            for (offsets) |*off| {
                if (off.pos > rep.start) {
                    if (off.pos < rep.end) {
                        off.pos = rep.start;
                    } else {
                        off.pos = @as(usize, @intCast(@as(isize, @intCast(off.pos)) + delta_len));
                    }
                } else if (off.pos == rep.start) {
                    if (push_at_start) {
                        off.pos = @as(usize, @intCast(@as(isize, @intCast(off.pos)) + @as(isize, @intCast(rep.insert_text.len))));
                    }
                }

                if (off.anchor) |*anchor| {
                    if (anchor.* > rep.start) {
                        if (anchor.* < rep.end) {
                            anchor.* = rep.start;
                        } else {
                            anchor.* = @as(usize, @intCast(@as(isize, @intCast(anchor.*)) + delta_len));
                        }
                    } else if (anchor.* == rep.start) {
                        if (push_at_start) {
                            anchor.* = @as(usize, @intCast(@as(isize, @intCast(anchor.*)) + @as(isize, @intCast(rep.insert_text.len))));
                        }
                    }
                }
            }
        }

        try self.document.rope.tree.saveHistory(offsets[0].pos);

        self.cursor_pos = self.document.rope.offsetToPoint(offsets[0].pos);
        if (self.current_mode == .visual or self.current_mode == .visual_line) {
            if (offsets[0].anchor) |anc| {
                self.visual_anchor_pos = self.document.rope.offsetToPoint(anc);
            }
        }

        for (self.saved_cursors.items, 0..) |*sc, idx| {
            sc.pos = self.document.rope.offsetToPoint(offsets[idx + 1].pos);
            if (sc.visual_anchor) |*va| {
                if (offsets[idx + 1].anchor) |anc| {
                    va.* = self.document.rope.offsetToPoint(anc);
                }
            }
        }

        var i: usize = 0;
        while (i < self.saved_cursors.items.len) {
            const sc = self.saved_cursors.items[i];
            var dup = (sc.pos.row == self.cursor_pos.row and sc.pos.column == self.cursor_pos.column);
            if (!dup) {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    const prev = self.saved_cursors.items[j];
                    if (prev.pos.row == sc.pos.row and prev.pos.column == sc.pos.column) {
                        dup = true;
                        break;
                    }
                }
            }
            if (dup) {
                _ = self.saved_cursors.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn handleKey(self: *Editor, key: Key, screen_width: usize, screen_height: usize) !Result {
        _ = screen_height;
        const total_newlines = self.document.rope.tree.root.summary.line_len;
        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(self.allocator);

        if (self.current_mode == .command) {
            switch (key) {
                .escape => {
                    self.current_mode = .normal;
                    self.command_input.clearRetainingCapacity();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                },
                .enter => {
                    const cmd = self.command_input.items;
                    if (std.mem.eql(u8, cmd, "q")) {
                        return Result{ .force_render = true, .should_exit = true, .save_requested = null };
                    } else if (std.mem.eql(u8, cmd, "w")) {
                        self.command_input.clearRetainingCapacity();
                        self.current_mode = .normal;
                        return Result{ .force_render = true, .should_exit = false, .save_requested = self.document.filename };
                    } else if (std.mem.eql(u8, cmd, "wq")) {
                        return Result{ .force_render = true, .should_exit = true, .save_requested = self.document.filename };
                    } else if (std.mem.eql(u8, cmd, "set wrap")) {
                        self.wrap_enabled = true;
                        self.current_mode = .normal;
                        self.command_input.clearRetainingCapacity();
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    } else if (std.mem.eql(u8, cmd, "set nowrap")) {
                        self.wrap_enabled = false;
                        self.current_mode = .normal;
                        self.command_input.clearRetainingCapacity();
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    } else {
                        self.status_message = "Unknown Command!";
                        self.status_timer = 2;
                        self.current_mode = .normal;
                        self.command_input.clearRetainingCapacity();
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    }
                },
                .backspace => {
                    if (self.command_input.items.len > 0) {
                        _ = self.command_input.pop();
                    } else {
                        self.current_mode = .normal;
                    }
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                },
                .char => |ch| {
                    const seq = ch.buf[0..ch.len];
                    try self.command_input.appendSlice(self.allocator, seq);
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                },
                else => return Result{ .force_render = false, .should_exit = false, .save_requested = null },
            }
        }

        switch (key) {
            .ctrl_c, .ctrl_q => return Result{ .force_render = true, .should_exit = true, .save_requested = null },
            .ctrl_s => {
                return Result{ .force_render = true, .should_exit = false, .save_requested = self.document.filename };
            },
            .ctrl_z => {
                if (self.current_mode == .normal or self.current_mode == .insert) {
                    const offset = self.document.rope.undo() catch {
                        self.status_message = "Nothing to Undo!";
                        self.status_timer = 2;
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    };
                    self.cursor_pos = self.document.rope.offsetToPoint(offset);
                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .ctrl_r => {
                if (self.current_mode == .normal) {
                    const offset = self.document.rope.redo() catch {
                        self.status_message = "Nothing to Redo!";
                        self.status_timer = 2;
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    };
                    self.cursor_pos = self.document.rope.offsetToPoint(offset);
                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .ctrl_d => {
                const has_selection = (self.current_mode == .visual or self.current_mode == .visual_line);
                try self.saved_cursors.append(self.allocator, .{
                    .pos = self.cursor_pos,
                    .visual_anchor = if (has_selection) self.visual_anchor_pos else null,
                    .mode = self.current_mode,
                });
                self.current_mode = .normal;
                try self.syncSelections();
                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
            },
            .escape => {
                self.saved_cursors.clearRetainingCapacity();
                if (self.current_mode != .normal) {
                    self.current_mode = .normal;
                    self.pending_op = null;
                    if (self.cursor_pos.column > 0) {
                        self.cursor_pos.column -= 1;
                    }
                }
                try self.syncSelections();
                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
            },
            .up => {
                const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                if (disp_pos.row > 0) {
                    self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .down => {
                const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                const total_display_rows = self.wrap_map.tree.root.summary.display_rows;
                if (disp_pos.row + 1 < total_display_rows) {
                    self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .home => {
                const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, self.document.rope);
                try self.syncSelections();
                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
            },
            .end => {
                const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, self.document.rope);
                try self.syncSelections();
                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
            },
            .left => {
                if (self.cursor_pos.column > 0) {
                    self.cursor_pos.column -= 1;
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .right => {
                try self.getLineText(self.cursor_pos.row, &line_buf);
                var line_len = line_buf.items.len;
                while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                    line_len -= 1;
                }
                const max_col = if (self.current_mode == .normal) (if (line_len > 0) line_len - 1 else 0) else line_len;
                if (self.cursor_pos.column < max_col) {
                    self.cursor_pos.column += 1;
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .delete => {
                if (self.current_mode == .insert) {
                    var reps = std.ArrayList(Replacement).empty;
                    defer reps.deinit(self.allocator);

                    const total_char = self.document.rope.tree.root.summary.char_len;
                    const p_off = self.document.rope.pointToOffset(self.cursor_pos);
                    if (p_off < total_char) {
                        try reps.append(self.allocator, .{
                            .cursor_idx = 0,
                            .start = p_off,
                            .end = p_off + 1,
                            .insert_text = "",
                        });
                    }

                    for (self.saved_cursors.items, 0..) |sc, idx| {
                        const sc_off = self.document.rope.pointToOffset(sc.pos);
                        if (sc_off < total_char) {
                            try reps.append(self.allocator, .{
                                .cursor_idx = idx + 1,
                                .start = sc_off,
                                .end = sc_off + 1,
                                .insert_text = "",
                            });
                        }
                    }

                    if (reps.items.len > 0) {
                        try self.applyMultiCursorReplacement(reps.items, true);
                        try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                        try self.syncSelections();
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    }
                }
            },
            .backspace => {
                if (self.current_mode == .insert) {
                    var reps = std.ArrayList(Replacement).empty;
                    defer reps.deinit(self.allocator);

                    const p_off = self.document.rope.pointToOffset(self.cursor_pos);
                    if (p_off > 0) {
                        try reps.append(self.allocator, .{
                            .cursor_idx = 0,
                            .start = p_off - 1,
                            .end = p_off,
                            .insert_text = "",
                        });
                    }

                    for (self.saved_cursors.items, 0..) |sc, idx| {
                        const sc_off = self.document.rope.pointToOffset(sc.pos);
                        if (sc_off > 0) {
                            try reps.append(self.allocator, .{
                                .cursor_idx = idx + 1,
                                .start = sc_off - 1,
                                .end = sc_off,
                                .insert_text = "",
                            });
                        }
                    }

                    if (reps.items.len > 0) {
                        try self.applyMultiCursorReplacement(reps.items, true);
                        try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                        try self.syncSelections();
                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                    }
                }
            },
            .enter => {
                if (self.current_mode == .insert) {
                    var reps = std.ArrayList(Replacement).empty;
                    defer reps.deinit(self.allocator);

                    const p_off = self.document.rope.pointToOffset(self.cursor_pos);
                    try reps.append(self.allocator, .{
                        .cursor_idx = 0,
                        .start = p_off,
                        .end = p_off,
                        .insert_text = "\n",
                    });

                    for (self.saved_cursors.items, 0..) |sc, idx| {
                        const sc_off = self.document.rope.pointToOffset(sc.pos);
                        try reps.append(self.allocator, .{
                            .cursor_idx = idx + 1,
                            .start = sc_off,
                            .end = sc_off,
                            .insert_text = "\n",
                        });
                    }

                    try self.applyMultiCursorReplacement(reps.items, true);
                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            .char => |ch| {
                const seq = ch.buf[0..ch.len];
                if (self.current_mode == .normal or self.current_mode == .visual or self.current_mode == .visual_line) {
                    if (seq.len == 1) {
                        const c = seq[0];
                        if (self.current_mode == .visual or self.current_mode == .visual_line) {
                            if (c == 'd' or c == 'x') {
                                var reps = std.ArrayList(Replacement).empty;
                                defer reps.deinit(self.allocator);

                                const p_range = self.getSelectionRange(self.cursor_pos, self.visual_anchor_pos, self.current_mode);
                                if (p_range.end > p_range.start) {
                                    try reps.append(self.allocator, .{
                                        .cursor_idx = 0,
                                        .start = p_range.start,
                                        .end = p_range.end,
                                        .insert_text = "",
                                    });
                                }

                                for (self.saved_cursors.items, 0..) |sc, idx| {
                                    const sc_range = self.getSelectionRange(sc.pos, sc.visual_anchor, sc.mode);
                                    if (sc_range.end > sc_range.start) {
                                        try reps.append(self.allocator, .{
                                            .cursor_idx = idx + 1,
                                            .start = sc_range.start,
                                            .end = sc_range.end,
                                            .insert_text = "",
                                        });
                                    }
                                }

                                if (reps.items.len > 0) {
                                    try self.applyMultiCursorReplacement(reps.items, true);
                                    self.current_mode = .normal;
                                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                                    try self.capCursorPos(&self.cursor_pos, true);
                                    for (self.saved_cursors.items) |*sc_item| {
                                        try self.capCursorPos(&sc_item.pos, true);
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                }
                                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                            }
                            if (c == 'h' or c == 'j' or c == 'k' or c == 'l' or
                                c == '0' or c == '$' or c == '^' or
                                c == '{' or c == '}' or c == 'g' or c == 'G' or
                                c == 'v' or c == 'V' or c == ':' or
                                c == 'w' or c == 'b')
                            {
                                // fall through
                            } else {
                                return Result{ .force_render = false, .should_exit = false, .save_requested = null };
                            }
                        }
                        if (self.pending_op) |op| {
                            if (op == 'd' and c == 'd') {
                                var reps = std.ArrayList(Replacement).empty;
                                defer reps.deinit(self.allocator);

                                const p_start = self.document.rope.pointToOffset(Point{ .row = self.cursor_pos.row, .column = 0 });
                                const p_end = if (self.cursor_pos.row >= total_newlines)
                                    self.document.rope.tree.root.summary.char_len
                                else
                                    self.document.rope.pointToOffset(Point{ .row = self.cursor_pos.row + 1, .column = 0 });
                                if (p_end > p_start) {
                                    try reps.append(self.allocator, .{
                                        .cursor_idx = 0,
                                        .start = p_start,
                                        .end = p_end,
                                        .insert_text = "",
                                    });
                                }

                                for (self.saved_cursors.items, 0..) |sc, idx| {
                                    const sc_start = self.document.rope.pointToOffset(Point{ .row = sc.pos.row, .column = 0 });
                                    const sc_end = if (sc.pos.row >= total_newlines)
                                        self.document.rope.tree.root.summary.char_len
                                    else
                                        self.document.rope.pointToOffset(Point{ .row = sc.pos.row + 1, .column = 0 });
                                    if (sc_end > sc_start) {
                                        try reps.append(self.allocator, .{
                                            .cursor_idx = idx + 1,
                                            .start = sc_start,
                                            .end = sc_end,
                                            .insert_text = "",
                                        });
                                    }
                                }

                                if (reps.items.len > 0) {
                                    try self.applyMultiCursorReplacement(reps.items, true);
                                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                                    try self.capCursorPos(&self.cursor_pos, true);
                                    for (self.saved_cursors.items) |*sc_item| {
                                        try self.capCursorPos(&sc_item.pos, true);
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                }
                                self.pending_op = null;
                            } else if (op == 'g' and c == 'g') {
                                self.cursor_pos.row = 0;
                                self.cursor_pos.column = 0;
                                try self.syncSelections();
                                self.pending_op = null;
                                return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                            } else {
                                self.pending_op = null;
                            }
                        } else {
                            switch (c) {
                                'i' => {
                                    self.current_mode = .insert;
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'a' => {
                                    try self.getLineText(self.cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    if (self.cursor_pos.column < line_len) {
                                        self.cursor_pos.column += 1;
                                    }
                                    self.current_mode = .insert;
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'o' => {
                                    var reps = std.ArrayList(Replacement).empty;
                                    defer reps.deinit(self.allocator);

                                    // For primary cursor
                                    try self.getLineText(self.cursor_pos.row, &line_buf);
                                    var p_line_len = line_buf.items.len;
                                    while (p_line_len > 0 and (line_buf.items[p_line_len - 1] == '\n' or line_buf.items[p_line_len - 1] == '\r')) {
                                        p_line_len -= 1;
                                    }
                                    self.cursor_pos.column = p_line_len;
                                    const p_offset = self.document.rope.pointToOffset(self.cursor_pos);
                                    try reps.append(self.allocator, .{
                                        .cursor_idx = 0,
                                        .start = p_offset,
                                        .end = p_offset,
                                        .insert_text = "\n",
                                    });

                                    // For saved cursors
                                    for (self.saved_cursors.items, 0..) |*sc, idx| {
                                        try self.getLineText(sc.pos.row, &line_buf);
                                        var sc_line_len = line_buf.items.len;
                                        while (sc_line_len > 0 and (line_buf.items[sc_line_len - 1] == '\n' or line_buf.items[sc_line_len - 1] == '\r')) {
                                            sc_line_len -= 1;
                                        }
                                        sc.pos.column = sc_line_len;
                                        const sc_offset = self.document.rope.pointToOffset(sc.pos);
                                        try reps.append(self.allocator, .{
                                            .cursor_idx = idx + 1,
                                            .start = sc_offset,
                                            .end = sc_offset,
                                            .insert_text = "\n",
                                        });
                                    }

                                    if (reps.items.len > 0) {
                                        try self.applyMultiCursorReplacement(reps.items, true);
                                        try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                                        self.current_mode = .insert;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'O' => {
                                    var reps = std.ArrayList(Replacement).empty;
                                    defer reps.deinit(self.allocator);

                                    // For primary cursor
                                    self.cursor_pos.column = 0;
                                    const p_offset = self.document.rope.pointToOffset(self.cursor_pos);
                                    try reps.append(self.allocator, .{
                                        .cursor_idx = 0,
                                        .start = p_offset,
                                        .end = p_offset,
                                        .insert_text = "\n",
                                    });

                                    // For saved cursors
                                    for (self.saved_cursors.items, 0..) |*sc, idx| {
                                        sc.pos.column = 0;
                                        const sc_offset = self.document.rope.pointToOffset(sc.pos);
                                        try reps.append(self.allocator, .{
                                            .cursor_idx = idx + 1,
                                            .start = sc_offset,
                                            .end = sc_offset,
                                            .insert_text = "\n",
                                        });
                                    }

                                    if (reps.items.len > 0) {
                                        try self.applyMultiCursorReplacement(reps.items, false);
                                        try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                                        self.current_mode = .insert;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'h' => {
                                    if (self.cursor_pos.column > 0) {
                                        self.cursor_pos.column -= 1;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'j' => {
                                    const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                                    const total_display_rows = self.wrap_map.tree.root.summary.display_rows;
                                    if (disp_pos.row + 1 < total_display_rows) {
                                        self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row + 1, .col = disp_pos.col }, self.document.rope);
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'k' => {
                                    const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                                    if (disp_pos.row > 0) {
                                        self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row - 1, .col = disp_pos.col }, self.document.rope);
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'l' => {
                                    try self.getLineText(self.cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    const max_col = if (line_len > 0) line_len - 1 else 0;
                                    if (self.cursor_pos.column < max_col) {
                                        self.cursor_pos.column += 1;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'w' => {
                                    try self.capCursorPos(&self.cursor_pos, self.current_mode == .normal);

                                    // Get current line text
                                    try self.getLineText(self.cursor_pos.row, &line_buf);
                                    var line_len = line_buf.items.len;
                                    while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                        line_len -= 1;
                                    }
                                    const line_text = line_buf.items[0..line_len];

                                    // Parse word starts
                                    var starts = try self.getLineWordStarts(line_text);
                                    defer starts.deinit(self.allocator);

                                    // Find next word start
                                    var next_col: ?usize = null;
                                    for (starts.items) |start| {
                                        if (start > self.cursor_pos.column) {
                                            next_col = start;
                                            break;
                                        }
                                    }

                                    if (next_col) |col| {
                                        self.cursor_pos.column = col;
                                    } else {
                                        // Go to next line column 0
                                        if (self.cursor_pos.row < total_newlines) {
                                            self.cursor_pos.row += 1;
                                            self.cursor_pos.column = 0;
                                        }
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'b' => {
                                    try self.capCursorPos(&self.cursor_pos, self.current_mode == .normal);

                                    if (self.cursor_pos.column == 0) {
                                        // Move to previous line at last column
                                        if (self.cursor_pos.row > 0) {
                                            self.cursor_pos.row -= 1;
                                            try self.getLineText(self.cursor_pos.row, &line_buf);
                                            var prev_len = line_buf.items.len;
                                            while (prev_len > 0 and (line_buf.items[prev_len - 1] == '\n' or line_buf.items[prev_len - 1] == '\r')) {
                                                prev_len -= 1;
                                            }
                                            const max_col = if (self.current_mode == .normal) (if (prev_len > 0) prev_len - 1 else 0) else prev_len;
                                            self.cursor_pos.column = max_col;
                                        }
                                    } else {
                                        // Get current line text
                                        try self.getLineText(self.cursor_pos.row, &line_buf);
                                        var line_len = line_buf.items.len;
                                        while (line_len > 0 and (line_buf.items[line_len - 1] == '\n' or line_buf.items[line_len - 1] == '\r')) {
                                            line_len -= 1;
                                        }
                                        const line_text = line_buf.items[0..line_len];

                                        var starts = try self.getLineWordStarts(line_text);
                                        defer starts.deinit(self.allocator);

                                        // Find the last start offset that is strictly less than current column
                                        var prev_col: ?usize = null;
                                        for (starts.items) |start| {
                                            if (start < self.cursor_pos.column) {
                                                prev_col = start;
                                            } else {
                                                break;
                                            }
                                        }

                                        if (prev_col) |col| {
                                            self.cursor_pos.column = col;
                                        } else {
                                            // Move to start of current line
                                            self.cursor_pos.column = 0;
                                        }
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'x' => {
                                    var reps = std.ArrayList(Replacement).empty;
                                    defer reps.deinit(self.allocator);

                                    const total_char = self.document.rope.tree.root.summary.char_len;

                                    // Primary cursor range
                                    const p_range = self.getSelectionRange(self.cursor_pos, if (self.current_mode == .visual or self.current_mode == .visual_line) self.visual_anchor_pos else null, self.current_mode);
                                    if (p_range.end > p_range.start) {
                                        try reps.append(self.allocator, .{
                                            .cursor_idx = 0,
                                            .start = p_range.start,
                                            .end = p_range.end,
                                            .insert_text = "",
                                        });
                                    } else {
                                        const p_off = self.document.rope.pointToOffset(self.cursor_pos);
                                        if (p_off < total_char) {
                                            try reps.append(self.allocator, .{
                                                .cursor_idx = 0,
                                                .start = p_off,
                                                .end = p_off + 1,
                                                .insert_text = "",
                                            });
                                        }
                                    }

                                    // Saved cursors ranges
                                    for (self.saved_cursors.items, 0..) |sc, idx| {
                                        const sc_range = self.getSelectionRange(sc.pos, sc.visual_anchor, sc.mode);
                                        if (sc_range.end > sc_range.start) {
                                            try reps.append(self.allocator, .{
                                                .cursor_idx = idx + 1,
                                                .start = sc_range.start,
                                                .end = sc_range.end,
                                                .insert_text = "",
                                            });
                                        } else {
                                            const sc_off = self.document.rope.pointToOffset(sc.pos);
                                            if (sc_off < total_char) {
                                                try reps.append(self.allocator, .{
                                                    .cursor_idx = idx + 1,
                                                    .start = sc_off,
                                                    .end = sc_off + 1,
                                                    .insert_text = "",
                                                });
                                            }
                                        }
                                    }

                                    if (reps.items.len > 0) {
                                        try self.applyMultiCursorReplacement(reps.items, true);
                                        try self.wrap_map.rewrapAll(screen_width, self.document.rope);

                                        try self.capCursorPos(&self.cursor_pos, true);
                                        for (self.saved_cursors.items) |*sc_item| {
                                            try self.capCursorPos(&sc_item.pos, true);
                                        }
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                '0' => {
                                    const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                                    self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = 0 }, self.document.rope);
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                '$' => {
                                    const disp_pos = try self.wrap_map.bufferToDisplay(.{ .row = self.cursor_pos.row, .column = self.cursor_pos.column }, self.document.rope);
                                    self.cursor_pos = try self.wrap_map.displayToBuffer(.{ .row = disp_pos.row, .col = screen_width - 1 }, self.document.rope);
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                '^' => {
                                    try self.getLineText(self.cursor_pos.row, &line_buf);
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
                                    self.cursor_pos.column = if (idx < line_len) idx else if (line_len > 0) line_len - 1 else 0;
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                '{' => {
                                    if (self.cursor_pos.row > 0) {
                                        var r_idx = self.cursor_pos.row;
                                        const current_is_empty = try self.isLineEmpty(r_idx, &line_buf);
                                        if (current_is_empty) {
                                            while (r_idx > 0) {
                                                if (try self.isLineEmpty(r_idx - 1, &line_buf)) {
                                                    r_idx -= 1;
                                                } else {
                                                    break;
                                                }
                                            }
                                            if (r_idx > 0) {
                                                r_idx -= 1;
                                                while (r_idx > 0) {
                                                    if (try self.isLineEmpty(r_idx, &line_buf)) {
                                                        break;
                                                    }
                                                    r_idx -= 1;
                                                }
                                            }
                                        } else {
                                            while (r_idx > 0) {
                                                r_idx -= 1;
                                                if (try self.isLineEmpty(r_idx, &line_buf)) {
                                                    break;
                                                }
                                            }
                                        }
                                        self.cursor_pos.row = r_idx;
                                        self.cursor_pos.column = 0;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                '}' => {
                                    if (self.cursor_pos.row < total_newlines) {
                                        var r_idx = self.cursor_pos.row;
                                        const current_is_empty = try self.isLineEmpty(r_idx, &line_buf);
                                        if (current_is_empty) {
                                            while (r_idx < total_newlines) {
                                                if (try self.isLineEmpty(r_idx + 1, &line_buf)) {
                                                    r_idx += 1;
                                                } else {
                                                    break;
                                                }
                                            }
                                            if (r_idx < total_newlines) {
                                                r_idx += 1;
                                                while (r_idx < total_newlines) {
                                                    if (try self.isLineEmpty(r_idx, &line_buf)) {
                                                        break;
                                                    }
                                                    r_idx += 1;
                                                }
                                            }
                                        } else {
                                            while (r_idx < total_newlines) {
                                                r_idx += 1;
                                                if (try self.isLineEmpty(r_idx, &line_buf)) {
                                                    break;
                                                }
                                            }
                                        }
                                        self.cursor_pos.row = r_idx;
                                        self.cursor_pos.column = 0;
                                        try self.syncSelections();
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    }
                                },
                                'u' => {
                                    const offset = self.document.rope.undo() catch {
                                        self.status_message = "Nothing to Undo!";
                                        self.status_timer = 2;
                                        return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                    };
                                    self.cursor_pos = self.document.rope.offsetToPoint(offset);
                                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'd' => {
                                    self.pending_op = 'd';
                                    return Result{ .force_render = false, .should_exit = false, .save_requested = null };
                                },
                                'g' => {
                                    self.pending_op = 'g';
                                    return Result{ .force_render = false, .should_exit = false, .save_requested = null };
                                },
                                'G' => {
                                    self.cursor_pos.row = total_newlines;
                                    self.cursor_pos.column = 0;
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'v' => {
                                    if (self.current_mode == .visual) {
                                        self.current_mode = .normal;
                                    } else {
                                        self.current_mode = .visual;
                                        self.visual_anchor_pos = self.cursor_pos;
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                'V' => {
                                    if (self.current_mode == .visual_line) {
                                        self.current_mode = .normal;
                                    } else {
                                        self.current_mode = .visual_line;
                                        self.visual_anchor_pos = self.cursor_pos;
                                    }
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                ':' => {
                                    self.current_mode = .command;
                                    self.command_input.clearRetainingCapacity();
                                    try self.syncSelections();
                                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                                },
                                else => {},
                            }
                        }
                    }
                } else {
                    var reps = std.ArrayList(Replacement).empty;
                    defer reps.deinit(self.allocator);

                    const p_off = self.document.rope.pointToOffset(self.cursor_pos);
                    try reps.append(self.allocator, .{
                        .cursor_idx = 0,
                        .start = p_off,
                        .end = p_off,
                        .insert_text = seq,
                    });

                    for (self.saved_cursors.items, 0..) |sc, idx| {
                        const sc_off = self.document.rope.pointToOffset(sc.pos);
                        try reps.append(self.allocator, .{
                            .cursor_idx = idx + 1,
                            .start = sc_off,
                            .end = sc_off,
                            .insert_text = seq,
                        });
                    }

                    try self.applyMultiCursorReplacement(reps.items, true);
                    try self.wrap_map.rewrapAll(screen_width, self.document.rope);
                    try self.syncSelections();
                    return Result{ .force_render = true, .should_exit = false, .save_requested = null };
                }
            },
            else => {},
        }

        return Result{ .force_render = false, .should_exit = false, .save_requested = null };
    }
};
