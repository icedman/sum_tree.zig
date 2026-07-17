const std = @import("std");
const root = @import("root.zig");
const SumTree = root.SumTree;
const Bias = root.Bias;
const BoundedArray = root.BoundedArray;
const Rope = root.Rope;
const Point = root.Point;
const TreeMap = root.TreeMap;
const TreeSet = root.TreeSet;

// -------------------------------------------------------------
// Test Helpers for generic SumTree
// -------------------------------------------------------------
const TestItem = struct {
    val: u32,

    pub const Summary = struct {
        pub const Context = void;
        sum: u32 = 0,

        pub fn zero(cx: Context) @This() {
            _ = cx;
            return .{};
        }

        pub fn add(self: *@This(), other: @This(), cx: Context) void {
            _ = cx;
            self.sum += other.sum;
        }
    };

    pub fn summary(self: TestItem, cx: Summary.Context) Summary {
        _ = cx;
        return .{ .sum = self.val };
    }
};

const SumDimension = struct {
    val: u32 = 0,
    pub fn zero(cx: void) @This() {
        _ = cx;
        return .{};
    }
    pub fn addSummary(self: *@This(), s: TestItem.Summary, cx: void) void {
        _ = cx;
        self.val += s.sum;
    }
};

const SumSeekTarget = struct {
    target: u32,
    pub fn cmp(self: @This(), pos: SumDimension, cx: void) std.math.Order {
        _ = cx;
        return std.math.order(self.target, pos.val);
    }
};

test "generic SumTree basic functionality" {
    const allocator = std.testing.allocator;
    const S = SumTree(TestItem);

    const tree = try S.init(allocator, {});
    defer tree.deinit();

    try std.testing.expect(tree.isEmpty());

    try tree.push(TestItem{ .val = 10 });
    try tree.push(TestItem{ .val = 20 });
    try std.testing.expectEqual(@as(u32, 30), tree.root.summary.sum);
    try std.testing.expect(!tree.isEmpty());

    // Clone tree
    const tree_clone = try tree.clone();
    defer tree_clone.deinit();

    try std.testing.expectEqual(@as(u32, 30), tree_clone.root.summary.sum);
    try std.testing.expect(tree.root == tree_clone.root);
    try std.testing.expect(tree.root.rc == 2);

    // Mutation on clone
    try tree_clone.push(TestItem{ .val = 15 });
    try std.testing.expectEqual(@as(u32, 45), tree_clone.root.summary.sum);
    try std.testing.expectEqual(@as(u32, 30), tree.root.summary.sum);
    try std.testing.expect(tree.root != tree_clone.root);
    try std.testing.expect(tree.root.rc == 1);
}

test "generic SumTree Cursor and slicing" {
    const allocator = std.testing.allocator;
    const S = SumTree(TestItem);

    const tree = try S.init(allocator, {});
    defer tree.deinit();

    try tree.push(TestItem{ .val = 5 });
    try tree.push(TestItem{ .val = 10 });
    try tree.push(TestItem{ .val = 15 });
    try tree.push(TestItem{ .val = 20 });

    var cursor = S.Cursor(SumDimension).init(tree);
    const target = SumSeekTarget{ .target = 15 };
    
    // Seek to position 15 with .right bias
    cursor.seekTo(target, .right);
    try std.testing.expectEqual(@as(u32, 15), cursor.position.val);
    try std.testing.expectEqual(@as(u32, 15), cursor.item().?.val);

    // Slice prefix up to 15 using a fresh cursor starting at 0
    var slice_cursor = S.Cursor(SumDimension).init(tree);
    const sliced = try slice_cursor.slice(target, .right);
    defer sliced.deinit();

    try std.testing.expectEqual(@as(u32, 15), sliced.root.summary.sum);

    // Suffix from the sliced cursor (now positioned at 15)
    const suffix = try slice_cursor.suffix();
    defer suffix.deinit();
    try std.testing.expectEqual(@as(u32, 35), suffix.root.summary.sum);
}

test "generic SumTree undo/redo transaction history" {
    const allocator = std.testing.allocator;
    const S = SumTree(TestItem);

    const tree = try S.init(allocator, {});
    defer tree.deinit();

    tree.enable_history = true;

    try tree.push(TestItem{ .val = 1 });
    try std.testing.expectEqual(@as(u32, 1), tree.root.summary.sum);

    try tree.push(TestItem{ .val = 2 });
    try std.testing.expectEqual(@as(u32, 3), tree.root.summary.sum);

    try tree.undo();
    try std.testing.expectEqual(@as(u32, 1), tree.root.summary.sum);

    try tree.redo();
    try std.testing.expectEqual(@as(u32, 3), tree.root.summary.sum);

    try tree.undo();
    try tree.undo();
    try std.testing.expectEqual(@as(u32, 0), tree.root.summary.sum);
}

// -------------------------------------------------------------
// Rope Tests
// -------------------------------------------------------------
test "Rope basic editing, coordinate mapping, and lineText" {
    const allocator = std.testing.allocator;

    const rope = try Rope.init(allocator);
    defer rope.deinit();

    // 1. Insert multi-line text
    try rope.insert(0, "line one\nline two\nline three\nline four");

    // Verify character and newline counts
    try std.testing.expectEqual(@as(usize, 38), rope.tree.root.summary.char_len);
    try std.testing.expectEqual(@as(usize, 3), rope.tree.root.summary.line_len);

    // 2. Test pointToOffset
    try std.testing.expectEqual(@as(usize, 0), rope.pointToOffset(Point{ .row = 0, .column = 0 }));
    try std.testing.expectEqual(@as(usize, 5), rope.pointToOffset(Point{ .row = 0, .column = 5 }));
    try std.testing.expectEqual(@as(usize, 9), rope.pointToOffset(Point{ .row = 1, .column = 0 }));
    try std.testing.expectEqual(@as(usize, 14), rope.pointToOffset(Point{ .row = 1, .column = 5 }));

    // 3. Test offsetToPoint
    var pt = rope.offsetToPoint(0);
    try std.testing.expectEqual(@as(usize, 0), pt.row);
    try std.testing.expectEqual(@as(usize, 0), pt.column);

    pt = rope.offsetToPoint(5);
    try std.testing.expectEqual(@as(usize, 0), pt.row);
    try std.testing.expectEqual(@as(usize, 5), pt.column);

    pt = rope.offsetToPoint(9);
    try std.testing.expectEqual(@as(usize, 1), pt.row);
    try std.testing.expectEqual(@as(usize, 0), pt.column);

    pt = rope.offsetToPoint(14);
    try std.testing.expectEqual(@as(usize, 1), pt.row);
    try std.testing.expectEqual(@as(usize, 5), pt.column);

    // 4. Test lineText
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try rope.lineText(0, &buf);
    try std.testing.expectEqualSlices(u8, "line one\n", buf.items);

    try rope.lineText(1, &buf);
    try std.testing.expectEqualSlices(u8, "line two\n", buf.items);

    try rope.lineText(3, &buf);
    try std.testing.expectEqualSlices(u8, "line four", buf.items);

    // 4.5. Test lineTextFromCursor
    const RopeModule = @import("Rope.zig");
    const S = SumTree(RopeModule.RopeChunk);
    var rope_cursor = S.Cursor(RopeModule.CharDimension).init(rope.tree);

    rope_cursor.seekTo(RopeModule.CharSeekTarget{ .target = 5 }, .left);
    try rope.lineTextFromCursor(&rope_cursor, &buf);
    try std.testing.expectEqualSlices(u8, "one\n", buf.items);

    rope_cursor.seekTo(RopeModule.CharSeekTarget{ .target = 9 }, .left);
    try rope.lineTextFromCursor(&rope_cursor, &buf);
    try std.testing.expectEqualSlices(u8, "line two\n", buf.items);

    rope_cursor.seekTo(RopeModule.CharSeekTarget{ .target = 35 }, .left);
    try rope.lineTextFromCursor(&rope_cursor, &buf);
    try std.testing.expectEqualSlices(u8, "our", buf.items);

    // 5. Test collectRangeText directly
    buf.clearRetainingCapacity();
    try rope.collectRangeText(5, 10, &buf);
    try std.testing.expectEqualSlices(u8, "one\nline t", buf.items);

    buf.clearRetainingCapacity();
    try rope.collectRangeText(0, 38, &buf);
    try std.testing.expectEqualSlices(u8, "line one\nline two\nline three\nline four", buf.items);

    buf.clearRetainingCapacity();
    try rope.collectRangeText(10, 0, &buf);
    try std.testing.expectEqualSlices(u8, "", buf.items);

    // 6. Test multi-line edits (insert and delete when not on the first column)
    // Current text: "line one\nline two\nline three\nline four"
    // Let's insert "X" at row 1, col 5 (after "line ")
    const offset1 = rope.pointToOffset(Point{ .row = 1, .column = 5 });
    try rope.insert(offset1, "X");

    buf.clearRetainingCapacity();
    try rope.text(&buf);
    try std.testing.expectEqualSlices(u8, "line one\nline Xtwo\nline three\nline four", buf.items);

    // Let's delete the "X" we just inserted
    const offset2 = rope.pointToOffset(Point{ .row = 1, .column = 5 });
    try rope.delete(offset2, 1);

    buf.clearRetainingCapacity();
    try rope.text(&buf);
    try std.testing.expectEqualSlices(u8, "line one\nline two\nline three\nline four", buf.items);
}

// -------------------------------------------------------------
// TreeMap & TreeSet Tests
// -------------------------------------------------------------
test "TreeMap basic lookups, insertions, and replacements" {
    const allocator = std.testing.allocator;
    const Map = TreeMap(i32, []const u8);

    const map = try Map.init(allocator);
    defer map.deinit();

    try std.testing.expect(map.isEmpty());

    try map.insert(10, "ten");
    try map.insert(20, "twenty");
    try map.insert(15, "fifteen");

    try std.testing.expect(!map.isEmpty());
    try std.testing.expect(map.containsKey(10));
    try std.testing.expect(map.containsKey(20));
    try std.testing.expect(map.containsKey(15));
    try std.testing.expect(!map.containsKey(30));

    try std.testing.expectEqualStrings("ten", map.get(10).?);
    try std.testing.expectEqualStrings("twenty", map.get(20).?);
    try std.testing.expectEqualStrings("fifteen", map.get(15).?);

    // Test replace
    const old = try map.insertOrReplace(15, "fifteen-new");
    try std.testing.expectEqualStrings("fifteen", old.?);
    try std.testing.expectEqualStrings("fifteen-new", map.get(15).?);

    // Test first / last
    try std.testing.expectEqual(@as(i32, 10), map.first().?.key);
    try std.testing.expectEqual(@as(i32, 20), map.last().?.key);
}

test "TreeMap iteration" {
    const allocator = std.testing.allocator;
    const Map = TreeMap(i32, []const u8);

    const map = try Map.init(allocator);
    defer map.deinit();

    try map.insert(1, "one");
    try map.insert(3, "three");
    try map.insert(2, "two");

    var it = map.iterator();
    const e1 = it.next().?;
    try std.testing.expectEqual(@as(i32, 1), e1.key);
    const e2 = it.next().?;
    try std.testing.expectEqual(@as(i32, 2), e2.key);
    const e3 = it.next().?;
    try std.testing.expectEqual(@as(i32, 3), e3.key);
    try std.testing.expect(it.next() == null);
}

test "TreeMap closest" {
    const allocator = std.testing.allocator;
    const Map = TreeMap(i32, []const u8);

    const map = try Map.init(allocator);
    defer map.deinit();

    try map.insert(10, "ten");
    try map.insert(20, "twenty");
    try map.insert(30, "thirty");

    // closest <= key
    try std.testing.expect(map.closest(5) == null);
    try std.testing.expectEqual(@as(i32, 10), map.closest(10).?.key);
    try std.testing.expectEqual(@as(i32, 10), map.closest(15).?.key);
    try std.testing.expectEqual(@as(i32, 20), map.closest(25).?.key);
    try std.testing.expectEqual(@as(i32, 30), map.closest(35).?.key);
}

test "TreeMap removals" {
    const allocator = std.testing.allocator;
    const Map = TreeMap(i32, []const u8);

    const map = try Map.init(allocator);
    defer map.deinit();

    try map.insert(1, "one");
    try map.insert(2, "two");
    try map.insert(3, "three");

    const r2 = try map.remove(2);
    try std.testing.expectEqualStrings("two", r2.?);
    try std.testing.expect(!map.containsKey(2));

    try map.insert(4, "four");
    try map.insert(5, "five");
    
    // Remove range [1..4) -> leaves 4 and 5
    try map.removeRange(1, 4);
    try std.testing.expect(!map.containsKey(1));
    try std.testing.expect(!map.containsKey(3));
    try std.testing.expect(map.containsKey(4));
    try std.testing.expect(map.containsKey(5));
}

test "TreeSet basic functionality" {
    const allocator = std.testing.allocator;
    const Set = TreeSet(i32);

    const set = try Set.init(allocator);
    defer set.deinit();

    try set.insert(10);
    try set.insert(20);
    try set.insert(10); // duplicate

    try std.testing.expect(set.contains(10));
    try std.testing.expect(set.contains(20));
    try std.testing.expect(!set.contains(15));

    try std.testing.expect(try set.remove(10));
    try std.testing.expect(!set.contains(10));
    try std.testing.expect(!try set.remove(10)); // already gone
}

test "Rope single chunk delete crash recreation" {
    const allocator = std.testing.allocator;
    const rope = try Rope.init(allocator);
    defer rope.deinit();

    try rope.insert(0, "line one\nline two\nline three\nline four");
    
    // Press 'x' at offset 14
    try rope.delete(14, 1);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try rope.text(&buf);
    try std.testing.expectEqualSlices(u8, "line one\nline wo\nline three\nline four", buf.items);
}

test "Rope multi chunk delete crash recreation" {
    const allocator = std.testing.allocator;
    const rope = try Rope.init(allocator);
    defer rope.deinit();

    // Insert 1000 'a's
    var content: [1000]u8 = undefined;
    @memset(&content, 'a');
    try rope.insert(0, &content);

    // Delete 1 character at offset 150
    try rope.delete(150, 1);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try rope.text(&buf);
    try std.testing.expectEqual(@as(usize, 999), buf.items.len);
}

test "Rope comprehensive randomized fuzzing" {
    const allocator = std.testing.allocator;
    const rope = try Rope.init(allocator);
    defer rope.deinit();

    var ref: std.ArrayList(u8) = .empty;
    defer ref.deinit(allocator);

    var ref_history: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (ref_history.items) |*item| {
            item.deinit(allocator);
        }
        ref_history.deinit(allocator);
    }
    var ref_history_index: usize = 0;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    rope.setEnableHistory(true);

    // Initial state in history
    const initial_ref = try ref.clone(allocator);
    try ref_history.append(allocator, initial_ref);

    var op: usize = 0;
    while (op < 1000) : (op += 1) {
        const action = rand.intRangeLessThan(u8, 0, 100);
        std.debug.print("Op {}: Action={}, len={}\n", .{op, action, ref.items.len});

        if (action < 45) { // 45% Insert
            const offset = if (ref.items.len == 0) 0 else rand.intRangeAtMost(usize, 0, ref.items.len);
            const insert_len = rand.intRangeAtMost(usize, 1, 150);
            const content_buf = try allocator.alloc(u8, insert_len);
            defer allocator.free(content_buf);
            for (content_buf) |*c| {
                const choice = rand.intRangeLessThan(u8, 0, 10);
                if (choice == 0) {
                    c.* = '\n';
                } else {
                    c.* = rand.intRangeAtMost(u8, ' ', '~');
                }
            }

            std.debug.print("  -> INSERT at {}, len={}, text='{s}'\n", .{offset, insert_len, content_buf});
            try rope.insert(offset, content_buf);

            // Update ref
            try ref.insertSlice(allocator, offset, content_buf);

            // Save history
            while (ref_history.items.len > ref_history_index + 1) {
                var item = ref_history.pop().?;
                item.deinit(allocator);
            }
            const copy = try ref.clone(allocator);
            try ref_history.append(allocator, copy);
            ref_history_index = ref_history.items.len - 1;

        } else if (action < 80) { // 35% Delete
            if (ref.items.len > 0) {
                const offset = rand.intRangeLessThan(usize, 0, ref.items.len);
                const del_len = rand.intRangeAtMost(usize, 1, @min(ref.items.len - offset, 80));

                std.debug.print("  -> DELETE at {}, len={}\n", .{offset, del_len});
                try rope.delete(offset, del_len);

                // Update ref
                try ref.replaceRange(allocator, offset, del_len, "");

                // Save history
                while (ref_history.items.len > ref_history_index + 1) {
                    var item = ref_history.pop().?;
                    item.deinit(allocator);
                }
                const copy = try ref.clone(allocator);
                try ref_history.append(allocator, copy);
                ref_history_index = ref_history.items.len - 1;
            }
        } else if (action < 90) { // 10% Undo
            if (ref_history_index > 0) {
                try rope.undo();
                ref_history_index -= 1;
                ref.clearRetainingCapacity();
                try ref.appendSlice(allocator, ref_history.items[ref_history_index].items);
            }
        } else { // 10% Redo
            if (ref_history_index < ref_history.items.len - 1) {
                try rope.redo();
                ref_history_index += 1;
                ref.clearRetainingCapacity();
                try ref.appendSlice(allocator, ref_history.items[ref_history_index].items);
            }
        }

        // --- VERIFY ROPE CONTENT ---
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);
        try rope.text(&text_buf);
        try std.testing.expectEqualSlices(u8, ref.items, text_buf.items);

        // Verify char count
        try std.testing.expectEqual(ref.items.len, rope.tree.root.summary.char_len);

        // Verify newline count
        var expected_newlines: usize = 0;
        for (ref.items) |c| {
            if (c == '\n') expected_newlines += 1;
        }
        try std.testing.expectEqual(expected_newlines, rope.tree.root.summary.line_len);

        // Verify random point/coordinate maps
        if (ref.items.len > 0) {
            const test_offset = rand.intRangeLessThan(usize, 0, ref.items.len);
            const pt = rope.offsetToPoint(test_offset);
            const check_offset = rope.pointToOffset(pt);
            try std.testing.expectEqual(test_offset, check_offset);

            // Verify lineText
            const test_row = rand.intRangeAtMost(usize, 0, expected_newlines);
            var line_text_buf: std.ArrayList(u8) = .empty;
            defer line_text_buf.deinit(allocator);
            try rope.lineText(test_row, &line_text_buf);

            // Compute expected line text from reference string
            var start_idx: usize = 0;
            var current_row: usize = 0;
            while (current_row < test_row) {
                if (ref.items[start_idx] == '\n') {
                    current_row += 1;
                }
                start_idx += 1;
            }
            var end_idx = start_idx;
            while (end_idx < ref.items.len and ref.items[end_idx] != '\n') {
                end_idx += 1;
            }
            if (end_idx < ref.items.len) {
                end_idx += 1; // include newline
            }
            try std.testing.expectEqualSlices(u8, ref.items[start_idx..end_idx], line_text_buf.items);
        }
    }
}

test "WrapMap basic operations" {
    const allocator = std.testing.allocator;
    const WrapMap = root.WrapMap;

    const rope = try Rope.init(allocator);
    defer rope.deinit();

    // Line 0: length 12 -> wrapped to width 5: display rows = 3 (hello, worl, d\n)
    // Line 1: length 5 -> wrapped to width 5: display rows = 1 (test\n)
    try rope.insert(0, "hello world\ntest\n");

    var wrap_map = try WrapMap.init(allocator, 5);
    defer wrap_map.deinit();

    try wrap_map.rewrapAll(5, rope);

    // Expecting 2 physical lines in rope:
    // Line 0 is "hello world\n" (len 12)
    // Line 1 is "test\n" (len 5)
    // Line 2 is "" (len 0)
    try std.testing.expectEqual(@as(usize, 3), wrap_map.calculateDisplayRows(11)); // "hello world" (len 11 visible)
    try std.testing.expectEqual(@as(usize, 1), wrap_map.calculateDisplayRows(4));  // "test" (len 4 visible)

    // Test bufferToDisplay translation
    // Line 0, char 0 ("h") -> Display row 0, col 0
    const dp0 = try wrap_map.bufferToDisplay(.{ .row = 0, .column = 0 }, rope);
    try std.testing.expectEqual(@as(usize, 0), dp0.row);
    try std.testing.expectEqual(@as(usize, 0), dp0.col);

    // Line 0, char 6 ("w") -> Display row 1, col 1 (since 'hello ' is 6 chars, 6 / 5 = 1 row offset, 6 % 5 = 1 col offset)
    const dp1 = try wrap_map.bufferToDisplay(.{ .row = 0, .column = 6 }, rope);
    try std.testing.expectEqual(@as(usize, 1), dp1.row);
    try std.testing.expectEqual(@as(usize, 1), dp1.col);

    // Test displayToBuffer translation
    // Display row 1, col 1 -> Line 0, char 6
    const bp1 = try wrap_map.displayToBuffer(.{ .row = 1, .col = 1 }, rope);
    try std.testing.expectEqual(@as(usize, 0), bp1.row);
    try std.testing.expectEqual(@as(usize, 6), bp1.column);

    // Display row 3, col 2 -> Line 1, char 2 ("s")
    const bp2 = try wrap_map.displayToBuffer(.{ .row = 3, .col = 2 }, rope);
    try std.testing.expectEqual(@as(usize, 1), bp2.row);
    try std.testing.expectEqual(@as(usize, 2), bp2.column);

    // Test with tab characters
    const rope_tabs = try Rope.init(allocator);
    defer rope_tabs.deinit();
    // "\tA" at tab_size=4 is "    A" -> length 5 (4 spaces + "A")
    try rope_tabs.insert(0, "\tA\n");

    var wrap_map_tabs = try WrapMap.init(allocator, 8);
    defer wrap_map_tabs.deinit();
    try wrap_map_tabs.rewrapAll(8, rope_tabs);

    // "\t" starts at col 0, visual width 4
    // "A" is raw column 1, visual column 4
    const dp_tab = try wrap_map_tabs.bufferToDisplay(.{ .row = 0, .column = 1 }, rope_tabs);
    try std.testing.expectEqual(@as(usize, 0), dp_tab.row);
    try std.testing.expectEqual(@as(usize, 4), dp_tab.col);

    const bp_tab = try wrap_map_tabs.displayToBuffer(.{ .row = 0, .col = 4 }, rope_tabs);
    try std.testing.expectEqual(@as(usize, 0), bp_tab.row);
    try std.testing.expectEqual(@as(usize, 1), bp_tab.column);
}

test "SelectionManager basic operations and normalization" {
    const allocator = std.testing.allocator;
    const SelectionManager = @import("Selection.zig").SelectionManager;

    var sm = SelectionManager.init(allocator);
    defer sm.deinit();

    // 1. Add disjoint selections
    try sm.addSelection(10, 5); // start=5, end=10 (reversed)
    try sm.addSelection(15, 20); // start=15, end=20

    try std.testing.expectEqual(@as(usize, 2), sm.selections.items.len);
    try std.testing.expect(sm.isOffsetSelected(7));
    try std.testing.expect(sm.isOffsetSelected(17));
    try std.testing.expect(!sm.isOffsetSelected(12));

    // 2. Add overlapping selection that merges
    try sm.addSelection(8, 16); // overlaps both! [5, 10] and [15, 20] -> should merge into [5, 20]
    try std.testing.expectEqual(@as(usize, 1), sm.selections.items.len);
    try std.testing.expectEqual(@as(usize, 5), sm.selections.items[0].start());
    try std.testing.expectEqual(@as(usize, 20), sm.selections.items[0].end());
}
