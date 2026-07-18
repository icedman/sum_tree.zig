const std = @import("std");
const Allocator = std.mem.Allocator;
const sum_tree = @import("SumTree.zig");
const SumTree = sum_tree.SumTree;
const Bias = sum_tree.Bias;

pub const LineWrapEntry = struct {
    raw_chars: usize, // Count of raw buffer characters in this line (including '\n')
    display_rows: usize, // Number of screen rows this line takes at the current wrap width

    pub const Summary = struct {
        pub const Context = void;
        buffer_lines: usize = 0,
        raw_chars: usize = 0,
        display_rows: usize = 0,

        pub fn zero(cx: Context) Summary {
            _ = cx;
            return .{};
        }

        pub fn add(self: *Summary, other: Summary, cx: Context) void {
            _ = cx;
            self.buffer_lines += other.buffer_lines;
            self.raw_chars += other.raw_chars;
            self.display_rows += other.display_rows;
        }

        pub fn addSummary(self: *Summary, other: Summary, cx: Context) void {
            self.add(other, cx);
        }
    };

    pub fn summary(self: LineWrapEntry, cx: Summary.Context) Summary {
        _ = cx;
        return .{
            .buffer_lines = 1,
            .raw_chars = self.raw_chars,
            .display_rows = self.display_rows,
        };
    }
};

pub const WrapDimension = struct {
    buffer_lines: usize = 0,
    raw_chars: usize = 0,
    display_rows: usize = 0,

    pub fn zero(cx: void) @This() {
        _ = cx;
        return .{};
    }
    pub fn addSummary(self: *@This(), s: LineWrapEntry.Summary, cx: void) void {
        _ = cx;
        self.buffer_lines += s.buffer_lines;
        self.raw_chars += s.raw_chars;
        self.display_rows += s.display_rows;
    }
};

pub const BufferLineSeekTarget = struct {
    target: usize,
    pub fn cmp(self: @This(), pos: WrapDimension, cx: void) std.math.Order {
        _ = cx;
        return std.math.order(self.target, pos.buffer_lines);
    }
};

pub const DisplayRowSeekTarget = struct {
    target: usize,
    pub fn cmp(self: @This(), pos: WrapDimension, cx: void) std.math.Order {
        _ = cx;
        return std.math.order(self.target, pos.display_rows);
    }
};

pub const BufferPoint = @import("Rope.zig").Point;

pub const DisplayPoint = struct {
    row: usize, // 0-indexed terminal screen line
    col: usize, // 0-indexed screen column
};

pub const WrapMap = struct {
    const Self = @This();
    const TreeType = SumTree(LineWrapEntry);

    allocator: Allocator,
    tree: *TreeType,
    wrap_width: usize,
    wrapped_bitset: std.DynamicBitSet,

    pub fn init(allocator: Allocator, wrap_width: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .tree = try TreeType.init(allocator, {}),
            .wrap_width = wrap_width,
            .wrapped_bitset = try std.DynamicBitSet.initEmpty(allocator, 0),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.tree.deinit();
        self.wrapped_bitset.deinit();
        self.allocator.destroy(self);
    }

    pub fn calculateDisplayRows(self: *const Self, raw_len: usize) usize {
        if (raw_len == 0) return 1;
        return (raw_len + self.wrap_width - 1) / self.wrap_width;
    }

    fn isLineWrapped(self: *const Self, row: usize) bool {
        if (row >= self.wrapped_bitset.capacity()) return false;
        return self.wrapped_bitset.isSet(row);
    }

    fn wrapLine(self: *Self, row: usize, rope: anytype) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        try rope.lineText(row, &buffer);
        const text = buffer.items;
        const visible_len = if (text.len > 0 and text[text.len - 1] == '\n') text.len - 1 else text.len;
        const expanded_len = rawToExpanded(text[0..visible_len], visible_len, 4);
        const display_rows = self.calculateDisplayRows(expanded_len);

        const entry = LineWrapEntry{
            .raw_chars = text.len,
            .display_rows = display_rows,
        };

        try self.replace(row, 1, &.{entry});

        if (row >= self.wrapped_bitset.capacity()) {
            const new_cap = @max(self.wrapped_bitset.capacity() * 2, row + 1);
            try self.wrapped_bitset.resize(new_cap, false);
        }
        self.wrapped_bitset.set(row);
    }

    pub fn bufferToDisplay(self: *Self, pt: BufferPoint, rope: anytype) !DisplayPoint {
        const total_lines = rope.tree.root.summary.line_len + 1;
        const row = @min(pt.row, total_lines - 1);
        if (!self.isLineWrapped(row)) {
            try self.wrapLine(row, rope);
        }

        if (self.tree.isEmpty()) {
            return .{ .row = 0, .col = 0 };
        }
        var cursor = TreeType.Cursor(WrapDimension).init(self.tree);
        const target = BufferLineSeekTarget{ .target = row };
        cursor.seekTo(target, .right);

        const start_pos = cursor.position;

        // Retrieve line text to calculate tab expansion
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        try rope.lineText(row, &buffer);

        const expanded_col = rawToExpanded(buffer.items, pt.column, 4);

        const offset = expanded_col / self.wrap_width;
        const col = expanded_col % self.wrap_width;

        return .{
            .row = start_pos.display_rows + offset,
            .col = col,
        };
    }

    pub fn displayToBuffer(self: *Self, pt: DisplayPoint, rope: anytype) !BufferPoint {
        while (true) {
            if (self.tree.isEmpty()) {
                return .{ .row = 0, .column = 0 };
            }
            var cursor = TreeType.Cursor(WrapDimension).init(self.tree);
            const target = DisplayRowSeekTarget{ .target = pt.row };
            cursor.seekTo(target, .right);

            const start_pos = cursor.position;
            const item = cursor.item();

            const raw_row = start_pos.buffer_lines;

            if (item) |_| {
                if (!self.isLineWrapped(raw_row)) {
                    try self.wrapLine(raw_row, rope);
                    continue;
                }
                const line_row_offset = pt.row - start_pos.display_rows;
                const expanded_col = line_row_offset * self.wrap_width + pt.col;

                // Retrieve line text to map expanded to raw column
                var buffer = std.ArrayList(u8).empty;
                defer buffer.deinit(self.allocator);
                try rope.lineText(raw_row, &buffer);

                const raw_col = expandedToRaw(buffer.items, expanded_col, 4);

                return .{
                    .row = raw_row,
                    .column = raw_col,
                };
            } else {
                const total_lines = self.tree.root.summary.buffer_lines;
                if (total_lines > 0) {
                    const last_row = total_lines - 1;
                    if (!self.isLineWrapped(last_row)) {
                        try self.wrapLine(last_row, rope);
                        continue;
                    }
                    cursor.reset();
                    cursor.seekTo(BufferLineSeekTarget{ .target = last_row }, .right);
                    const last_entry = cursor.item().?;
                    const visible_chars = if (last_entry.raw_chars > 0) last_entry.raw_chars - 1 else 0;
                    return .{
                        .row = last_row,
                        .column = visible_chars,
                    };
                }
                return .{ .row = 0, .column = 0 };
            }
        }
    }

    pub fn replace(self: *Self, start_line: usize, old_lines_count: usize, new_entries: []const LineWrapEntry) !void {
        if (self.tree.isEmpty()) {
            for (new_entries) |entry| {
                try self.tree.push(entry);
            }
            return;
        }

        var cursor = TreeType.Cursor(WrapDimension).init(self.tree);
        const start_target = BufferLineSeekTarget{ .target = start_line };

        const split_A = try self.tree.splitNode(WrapDimension, self.tree.root, start_target, .right, &cursor.position);
        errdefer split_A.left.deref(self.allocator);
        errdefer split_A.right.deref(self.allocator);

        const left_tree = try TreeType.init(self.allocator, {});
        left_tree.root.deref(self.allocator);
        left_tree.root = split_A.left;
        defer left_tree.deinit();

        const split_A_right_tree = try TreeType.init(self.allocator, {});
        split_A_right_tree.root.deref(self.allocator);
        split_A_right_tree.root = split_A.right;
        defer split_A_right_tree.deinit();

        var right_cursor = TreeType.Cursor(WrapDimension).init(split_A_right_tree);
        const len_target = BufferLineSeekTarget{ .target = old_lines_count };
        const split_B = try self.tree.splitNode(WrapDimension, split_A_right_tree.root, len_target, .right, &right_cursor.position);
        errdefer split_B.left.deref(self.allocator);
        errdefer split_B.right.deref(self.allocator);

        split_B.left.deref(self.allocator);

        for (new_entries) |entry| {
            try left_tree.push(entry);
        }

        const right_tree = try TreeType.init(self.allocator, {});
        right_tree.root.deref(self.allocator);
        right_tree.root = split_B.right;
        defer right_tree.deinit();

        try left_tree.append(right_tree);

        const old_root = self.tree.root;
        self.tree.root = left_tree.root.ref();
        old_root.deref(self.allocator);
    }

    pub fn rewrapAll(self: *Self, new_wrap_width: usize, rope: anytype) !void {
        self.wrap_width = new_wrap_width;
        const old_tree = self.tree;
        self.tree = try TreeType.init(self.allocator, {});
        old_tree.deinit();

        const total_lines = rope.tree.root.summary.line_len + 1;
        self.wrapped_bitset.deinit();
        self.wrapped_bitset = try std.DynamicBitSet.initEmpty(self.allocator, total_lines);

        var i: usize = 0;
        while (i < total_lines) : (i += 1) {
            try self.tree.push(LineWrapEntry{
                .raw_chars = 10,
                .display_rows = 1,
            });
        }

        var limit: usize = 100;
        if (limit > total_lines) limit = total_lines;
        i = 0;
        while (i < limit) : (i += 1) {
            try self.wrapLine(i, rope);
        }
    }

    pub fn updateLine(self: *Self, row: usize, rope: anytype) !void {
        try self.wrapLine(row, rope);
    }
};

pub fn expandTabs(allocator: std.mem.Allocator, text: []const u8, tab_size: usize, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    var col: usize = 0;
    for (text) |char| {
        if (char == '\t') {
            const spaces = tab_size - (col % tab_size);
            try out.appendNTimes(allocator, ' ', spaces);
            col += spaces;
        } else {
            try out.append(allocator, char);
            col += 1;
        }
    }
}

pub fn rawToExpanded(text: []const u8, raw_col: usize, tab_size: usize) usize {
    var exp_col: usize = 0;
    var i: usize = 0;
    while (i < raw_col and i < text.len) : (i += 1) {
        const char = text[i];
        if (char == '\t') {
            exp_col += tab_size - (exp_col % tab_size);
        } else {
            exp_col += 1;
        }
    }
    return exp_col;
}

pub fn expandedToRaw(text: []const u8, exp_col: usize, tab_size: usize) usize {
    var cur_exp: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (cur_exp >= exp_col) return i;
        const char = text[i];
        const next_exp = if (char == '\t') cur_exp + (tab_size - (cur_exp % tab_size)) else cur_exp + 1;
        if (next_exp > exp_col) {
            return i;
        }
        cur_exp = next_exp;
        i += 1;
    }
    return i;
}
