const std = @import("std");
const sum_tree = @import("SumTree.zig");
const SumTree = sum_tree.SumTree;
const BoundedArray = sum_tree.BoundedArray;
const Bias = sum_tree.Bias;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Point = struct {
    row: usize,
    column: usize,
};

pub const RopeChunk = struct {
    text: BoundedArray(u8, 128) = .{},

    pub const Summary = struct {
        pub const Context = void;
        char_len: usize = 0,
        line_len: usize = 0,
        utf16_len: usize = 0,

        pub fn zero(cx: Context) @This() {
            _ = cx;
            return .{};
        }

        pub fn add(self: *@This(), other: @This(), cx: Context) void {
            _ = cx;
            self.char_len += other.char_len;
            self.line_len += other.line_len;
            self.utf16_len += other.utf16_len;
        }

        pub fn addSummary(self: *@This(), other: @This(), cx: Context) void {
            self.add(other, cx);
        }
    };

    pub fn summary(self: RopeChunk, cx: Summary.Context) Summary {
        _ = cx;
        const slice = self.text.slice();
        var lines: usize = 0;
        for (slice) |b| {
            if (b == '\n') lines += 1;
        }

        var utf16: usize = 0;
        var i: usize = 0;
        while (i < slice.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(slice[i]) catch 1;
            utf16 += if (cp_len == 4) @as(usize, 2) else 1;
            i += cp_len;
        }

        return .{
            .char_len = slice.len,
            .line_len = lines,
            .utf16_len = utf16,
        };
    }
};

pub const CharDimension = struct {
    val: usize = 0,
    pub fn zero(cx: void) @This() { _ = cx; return .{}; }
    pub fn addSummary(self: *@This(), s: RopeChunk.Summary, cx: void) void {
        _ = cx;
        self.val += s.char_len;
    }
};

pub const LineDimension = struct {
    val: usize = 0,
    pub fn zero(cx: void) @This() { _ = cx; return .{}; }
    pub fn addSummary(self: *@This(), s: RopeChunk.Summary, cx: void) void {
        _ = cx;
        self.val += s.line_len;
    }
};

pub const Utf16Dimension = struct {
    val: usize = 0,
    pub fn zero(cx: void) @This() { _ = cx; return .{}; }
    pub fn addSummary(self: *@This(), s: RopeChunk.Summary, cx: void) void {
        _ = cx;
        self.val += s.utf16_len;
    }
};

pub const CharSeekTarget = struct {
    target: usize,
    pub fn cmp(self: @This(), pos: anytype, cx: anytype) std.math.Order {
        _ = cx;
        const T = @TypeOf(pos);
        if (@hasField(T, "char_len")) {
            return std.math.order(self.target, pos.char_len);
        } else if (@hasField(T, "val")) {
            return std.math.order(self.target, pos.val);
        }
        @compileError("Unsupported position type for CharSeekTarget");
    }
};

pub const LineSeekTarget = struct {
    target: usize,
    pub fn cmp(self: @This(), pos: anytype, cx: anytype) std.math.Order {
        _ = cx;
        const T = @TypeOf(pos);
        if (@hasField(T, "line_len")) {
            return std.math.order(self.target, pos.line_len);
        } else if (@hasField(T, "val")) {
            return std.math.order(self.target, pos.val);
        }
        @compileError("Unsupported position type for LineSeekTarget");
    }
};

pub const Utf16SeekTarget = struct {
    target: usize,
    pub fn cmp(self: @This(), pos: anytype, cx: anytype) std.math.Order {
        _ = cx;
        const T = @TypeOf(pos);
        if (@hasField(T, "utf16_len")) {
            return std.math.order(self.target, pos.utf16_len);
        } else if (@hasField(T, "val")) {
            return std.math.order(self.target, pos.val);
        }
        @compileError("Unsupported position type for Utf16SeekTarget");
    }
};

pub const Rope = struct {
    const Self = @This();
    const S = SumTree(RopeChunk);

    allocator: Allocator,
    tree: *S,

    pub fn init(allocator: Allocator) !*Self {
        const rope = try allocator.create(Self);
        rope.tree = try S.init(allocator, {});
        rope.allocator = allocator;
        return rope;
    }

    pub fn deinit(self: *Self) void {
        self.tree.deinit();
        self.allocator.destroy(self);
    }

    pub fn clone(self: *Self) !*Self {
        const copy = try self.allocator.create(Self);
        copy.tree = try self.tree.clone();
        copy.allocator = self.allocator;
        return copy;
    }

    pub fn insert(self: *Self, offset: usize, content: []const u8) !void {
        try self.replace(offset, 0, content);
    }

    pub fn delete(self: *Self, offset: usize, len: usize) !void {
        try self.replace(offset, len, "");
    }

    pub fn replace(self: *Self, offset: usize, len: usize, content: []const u8) !void {
        var cursor = S.Cursor(CharDimension).init(self.tree);
        const left_target = CharSeekTarget{ .target = offset };
        const left_slice = try cursor.slice(left_target, .right);
        errdefer left_slice.deinit();

        var split_left_chunk: ?RopeChunk = null;
        var split_right_chunk: ?RopeChunk = null;

        if (cursor.item()) |entry| {
            const chunk_start = cursor.position.val;
            if (offset > chunk_start and offset < chunk_start + entry.text.len) {
                const split_idx = offset - chunk_start;
                var c1 = RopeChunk{};
                c1.text.appendSlice(entry.text.slice()[0..split_idx]);
                split_left_chunk = c1;

                var c2 = RopeChunk{};
                c2.text.appendSlice(entry.text.slice()[split_idx..]);
                split_right_chunk = c2;

                cursor.next();
            }
        }

        if (split_left_chunk) |c| {
            try left_slice.push(c);
        }

        const delete_end = offset + len;
        const end_target = CharSeekTarget{ .target = delete_end };
        cursor.seekTo(end_target, .right);

        var del_right_chunk: ?RopeChunk = null;
        if (cursor.item()) |entry| {
            const chunk_start = cursor.position.val;
            if (delete_end > chunk_start and delete_end < chunk_start + entry.text.len) {
                const split_idx = delete_end - chunk_start;
                var c2 = RopeChunk{};
                c2.text.appendSlice(entry.text.slice()[split_idx..]);
                del_right_chunk = c2;
                cursor.next();
            }
        }

        var i: usize = 0;
        while (i < content.len) {
            const chunk_size = @min(content.len - i, 128);
            var c = RopeChunk{};
            c.text.appendSlice(content[i .. i + chunk_size]);
            try left_slice.push(c);
            i += chunk_size;
        }

        if (del_right_chunk) |c| {
            try left_slice.push(c);
        } else if (split_right_chunk) |c| {
            if (len == 0) {
                try left_slice.push(c);
            }
        }



        const suffix_slice = try cursor.suffix();
        defer suffix_slice.deinit();

        try left_slice.append(suffix_slice);

        if (self.tree.enable_history) {
            try self.tree.startTransaction();
        }

        const old_root = self.tree.root;
        self.tree.root = left_slice.root.ref();
        old_root.deref(self.allocator);
        left_slice.deinit();

        if (self.tree.enable_history) {
            try self.tree.saveHistory();
        }
    }

    pub fn undo(self: *Self) !void {
        try self.tree.undo();
    }

    pub fn redo(self: *Self) !void {
        try self.tree.redo();
    }

    pub fn setEnableHistory(self: *Self, enable: bool) void {
        self.tree.enable_history = enable;
    }

    pub fn text(self: *const Self, buffer: *std.ArrayList(u8)) !void {
        buffer.clearRetainingCapacity();
        try self.collectText(buffer);
    }

    pub fn collectText(self: *const Self, buffer: *std.ArrayList(u8)) !void {
        try self.collectNodeText(self.tree.root, buffer);
    }

    fn collectNodeText(self: *const Self, node: *S.Node, buffer: *std.ArrayList(u8)) !void {
        switch (node.children) {
            .leaf => |leaf| {
                for (leaf.slice()) |chunk| {
                    try buffer.appendSlice(self.allocator, chunk.text.slice());
                }
            },
            .internal => |internal| {
                for (internal.slice()) |child| {
                    try self.collectNodeText(child, buffer);
                }
            },
        }
    }

    pub fn pointToOffset(self: *Self, point: Point) usize {
        var cursor = S.Cursor(RopeChunk.Summary).init(self.tree);
        const target = LineSeekTarget{ .target = point.row };
        cursor.seekTo(target, .left);

        const current_chunk = cursor.item() orelse {
            return self.tree.root.summary.char_len;
        };

        const needed_newlines = point.row - cursor.position.line_len;
        const local_char_offset = findNewlineOffset(current_chunk.text.slice(), needed_newlines);
        return cursor.position.char_len + local_char_offset + point.column;
    }

    pub fn offsetToPoint(self: *Self, offset: usize) Point {
        var cursor = S.Cursor(RopeChunk.Summary).init(self.tree);
        const target = CharSeekTarget{ .target = offset };
        cursor.seekTo(target, .left);

        const current_chunk = cursor.item() orelse {
            return Point{ .row = self.tree.root.summary.line_len, .column = 0 };
        };

        const local_offset = offset - cursor.position.char_len;
        var row = cursor.position.line_len;

        for (current_chunk.text.slice()[0..local_offset]) |c| {
            if (c == '\n') {
                row += 1;
            }
        }

        const line_start = self.pointToOffset(Point{ .row = row, .column = 0 });
        const col = offset - line_start;

        return Point{ .row = row, .column = col };
    }

    pub fn collectRangeText(self: *const Self, start: usize, len: usize, buffer: *std.ArrayList(u8)) !void {
        if (len == 0) return;
        var cursor = S.Cursor(RopeChunk.Summary).init(self.tree);
        const target = CharSeekTarget{ .target = start };
        cursor.seekTo(target, .left);

        var remaining = len;
        while (remaining > 0) {
            const entry = cursor.item() orelse break;
            const chunk_start = cursor.position.char_len;
            const chunk_len = entry.text.len;

            const overlap_start = @max(start, chunk_start);
            const overlap_end = @min(start + len, chunk_start + chunk_len);

            if (overlap_start < overlap_end) {
                const local_start = overlap_start - chunk_start;
                const local_len = overlap_end - overlap_start;
                try buffer.appendSlice(self.allocator, entry.text.slice()[local_start .. local_start + local_len]);
                remaining -= local_len;
            }
            cursor.next();
        }
    }

    pub fn lineText(self: *Self, row: usize, buffer: *std.ArrayList(u8)) !void {
        buffer.clearRetainingCapacity();

        const total_newlines = self.tree.root.summary.line_len;
        if (row > total_newlines) return;

        const start_offset = self.pointToOffset(Point{ .row = row, .column = 0 });
        const end_offset = if (row >= total_newlines)
            self.tree.root.summary.char_len
        else
            self.pointToOffset(Point{ .row = row + 1, .column = 0 });

        if (end_offset <= start_offset) return;

        try self.collectRangeText(start_offset, end_offset - start_offset, buffer);
    }

    pub fn lineTextFromCursor(self: *Self, cursor: anytype, buffer: *std.ArrayList(u8)) !void {
        buffer.clearRetainingCapacity();

        if (cursor.stack.len == 0) return;

        const start_offset = cursor.getPosition(CharDimension).val;
        const pt = self.offsetToPoint(start_offset);
        const row = pt.row;
        const total_newlines = self.tree.root.summary.line_len;

        const end_offset = if (row >= total_newlines)
            self.tree.root.summary.char_len
        else
            self.pointToOffset(Point{ .row = row + 1, .column = 0 });

        if (end_offset <= start_offset) return;

        try self.collectRangeText(start_offset, end_offset - start_offset, buffer);
    }

    fn findNewlineOffset(slice: []const u8, count: usize) usize {
        if (count == 0) return 0;
        var seen: usize = 0;
        for (slice, 0..) |c, idx| {
            if (c == '\n') {
                seen += 1;
                if (seen == count) {
                    return idx + 1;
                }
            }
        }
        return slice.len;
    }
};
