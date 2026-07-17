const std = @import("std");
const Allocator = std.mem.Allocator;
const sum_tree = @import("SumTree.zig");
const SumTree = sum_tree.SumTree;
const Bias = sum_tree.Bias;

pub const LineWrapEntry = struct {
    raw_chars: usize,  // Count of raw buffer characters in this line (including '\n')
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

    pub fn init(allocator: Allocator, wrap_width: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .tree = try TreeType.init(allocator, {}),
            .wrap_width = wrap_width,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.tree.deinit();
        self.allocator.destroy(self);
    }

    pub fn calculateDisplayRows(self: *const Self, raw_len: usize) usize {
        if (raw_len == 0) return 1;
        return (raw_len + self.wrap_width - 1) / self.wrap_width;
    }

    pub fn bufferToDisplay(self: *Self, pt: BufferPoint) DisplayPoint {
        if (self.tree.isEmpty()) {
            return .{ .row = 0, .col = 0 };
        }
        var cursor = TreeType.Cursor(WrapDimension).init(self.tree);
        const target = BufferLineSeekTarget{ .target = pt.row };
        cursor.seekTo(target, .right);

        const start_pos = cursor.position;
        const offset = pt.column / self.wrap_width;
        const col = pt.column % self.wrap_width;

        return .{
            .row = start_pos.display_rows + offset,
            .col = col,
        };
    }

    pub fn displayToBuffer(self: *Self, pt: DisplayPoint) BufferPoint {
        if (self.tree.isEmpty()) {
            return .{ .row = 0, .column = 0 };
        }
        var cursor = TreeType.Cursor(WrapDimension).init(self.tree);
        const target = DisplayRowSeekTarget{ .target = pt.row };
        cursor.seekTo(target, .right);

        const start_pos = cursor.position;
        const item = cursor.item();

        const raw_row = start_pos.buffer_lines;

        if (item) |wrap_entry| {
            const line_row_offset = pt.row - start_pos.display_rows;
            const char_col = line_row_offset * self.wrap_width + pt.col;
            // Exclude the newline char at the end if it's there
            const visible_chars = if (wrap_entry.raw_chars > 0 and wrap_entry.raw_chars == wrap_entry.display_rows * self.wrap_width)
                wrap_entry.raw_chars
            else if (wrap_entry.raw_chars > 0)
                wrap_entry.raw_chars - 1
            else
                0;
            return .{
                .row = raw_row,
                .column = @min(char_col, visible_chars),
            };
        } else {
            const total_lines = self.tree.root.summary.buffer_lines;
            if (total_lines > 0) {
                cursor.reset();
                cursor.seekTo(BufferLineSeekTarget{ .target = total_lines - 1 }, .right);
                const last_entry = cursor.item().?;
                const visible_chars = if (last_entry.raw_chars > 0) last_entry.raw_chars - 1 else 0;
                return .{
                    .row = total_lines - 1,
                    .column = visible_chars,
                };
            }
            return .{ .row = 0, .column = 0 };
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
        defer split_A.right.deref(self.allocator);

        const left_tree = try TreeType.init(self.allocator, {});
        left_tree.root.deref(self.allocator);
        left_tree.root = split_A.left;
        defer left_tree.deinit();

        var right_cursor = TreeType.Cursor(WrapDimension).init(split_A.right);
        const len_target = BufferLineSeekTarget{ .target = old_lines_count };
        const split_B = try self.tree.splitNode(WrapDimension, split_A.right, len_target, .right, &right_cursor.position);
        errdefer split_B.left.deref(self.allocator);
        defer split_B.right.deref(self.allocator);

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

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        const total_lines = rope.tree.root.summary.line_len + 1;
        var i: usize = 0;
        while (i < total_lines) : (i += 1) {
            try rope.lineText(i, &buffer);
            const text = buffer.items;
            const visible_len = if (text.len > 0 and text[text.len - 1] == '\n') text.len - 1 else text.len;
            const display_rows = self.calculateDisplayRows(visible_len);
            try self.tree.push(LineWrapEntry{
                .raw_chars = text.len,
                .display_rows = display_rows,
            });
        }
    }
};
