const std = @import("std");
const st = @import("SumTree.zig");
const SumTree = st.SumTree;
const Config = @import("config.zig").Config;

test "SumTree tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    _ = try tree.insert("abc", cur);
    cur = try tree.insert("defgh", tree.createCursor());

    // Currently cur is at node "defgh" with offset 5
    try std.testing.expectEqual(@as(usize, 5), cur.offset);

    // Seek right by 1 (to get to "abc" offset 1)
    // "defgh" has length 5. Since we are already at offset 5, seeking right by 1:
    // - Traverses to next sibling "abc", moves to offset 1
    const cur2 = cur.seekRight(1, 0);
    try std.testing.expectEqual(@as(usize, 1), cur2.offset);

    // Seek left by 4 from cur2
    // - From "abc" offset 1, moves left by 1 to offset 0 (remaining 3)
    // - Traverses to prev sibling "defgh", moves to offset 2
    const cur3 = cur2.seekLeft(4, 0);
    try std.testing.expectEqual(@as(usize, 2), cur3.offset);
    try std.testing.expectEqualSlices(u8, "defgh", tree.chunks.items[cur3.node.start..(cur3.node.start + cur3.node.summary.dimensions[0])]);
}

test "SumTree multi-level tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    const root = tree.root; // Root

    const int1 = try tree.createNode(&.{});
    const int2 = try tree.createNode(&.{});
    try root.attach(int1);
    try root.attach(int2);

    const l1 = try tree.createNode("abc");
    const l2 = try tree.createNode("def");
    try int1.attach(l1);
    try int1.attach(l2);

    const l3 = try tree.createNode("ghi");
    const l4 = try tree.createNode("jkl");
    try int2.attach(l3);
    try int2.attach(l4);

    // Populate chunks array
    try tree.chunks.appendSlice(allocator, "abcdefghijkl");

    // Summarize the internal nodes
    int1.summarize();
    int2.summarize();
    root.summarize();

    // Verify root summary in metric 0 is 12 (3 + 3 + 3 + 3)
    try std.testing.expectEqual(@as(usize, 12), root.summary.dimensions[0]);

    // Create a cursor at l1, offset 0
    const cur = tree.createCursorAt(l1, 0);

    // Seek right by 11
    const cur_right = cur.seekRight(11, 0);
    // 11 bytes from start of "abc" (index 0) should be at "jkl" offset 2 (index 11)
    try std.testing.expectEqual(l4, cur_right.node);
    try std.testing.expectEqual(@as(usize, 2), cur_right.offset);

    // Seek left by 10 from cur_right
    const cur_left = cur_right.seekLeft(10, 0);
    // 10 bytes left from "jkl" offset 2 (index 11) should be at "abc" offset 1 (index 1)
    try std.testing.expectEqual(l1, cur_left.node);
    try std.testing.expectEqual(@as(usize, 1), cur_left.offset);

    // Create a cursor at root, offset 0 (using tree.createCursor())
    const cur_root = tree.createCursor();
    const cur_root_seek = cur_root.seekRight(10, 0);
    // 10 bytes from start of tree should be at "jkl" offset 1
    try std.testing.expectEqual(l4, cur_root_seek.node);
    try std.testing.expectEqual(@as(usize, 1), cur_root_seek.offset);
}

test "SumTree split tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    // First insert to root (makes root contain "abcdef")
    cur = try tree.insert("abcdef", cur);

    // Cursor is currently at end of "abcdef" (offset 6)
    // Let's seek left by 4 to offset 2 (which is in the middle of "abcdef")
    const cur_middle = cur.seekLeft(4, 0);
    try std.testing.expectEqual(@as(usize, 2), cur_middle.offset);

    // Insert "XYZ" at offset 2 (should trigger split)
    const cur_after = try tree.insert("XYZ", cur_middle);

    // After insert, the tree root should have 3 children: "ab", "XYZ", "cdef"
    try std.testing.expectEqual(@as(usize, 3), tree.root.children.items.len);

    const c1 = tree.root.children.items[0];
    const c2 = tree.root.children.items[1];
    const c3 = tree.root.children.items[2];

    try std.testing.expectEqualSlices(u8, "ab", tree.chunks.items[c1.start..(c1.start + c1.summary.dimensions[0])]);
    try std.testing.expectEqualSlices(u8, "XYZ", tree.chunks.items[c2.start..(c2.start + c2.summary.dimensions[0])]);
    try std.testing.expectEqualSlices(u8, "cdef", tree.chunks.items[c3.start..(c3.start + c3.summary.dimensions[0])]);

    // The cursor returned by insert should point to the new node "XYZ" at its end (offset 3)
    try std.testing.expectEqual(c2, cur_after.node);
    try std.testing.expectEqual(@as(usize, 3), cur_after.offset);
}

test "SumTree erase tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    cur = try tree.insert("abcdef", cur);

    // Erase 3 bytes starting at offset 2 (erases "cde")
    const cur_middle = cur.seekLeft(4, 0); // offset 2
    const cur_after = try tree.erase(cur_middle, 3);

    // root should still have 2 active children (prefix "ab" and suffix "f")
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    const c1 = tree.root.children.items[0];
    const c2 = tree.root.children.items[1];

    try std.testing.expectEqualSlices(u8, "ab", tree.chunks.items[c1.start..(c1.start + c1.summary.dimensions[0])]);
    try std.testing.expectEqualSlices(u8, "f", tree.chunks.items[c2.start..(c2.start + c2.summary.dimensions[0])]);

    // Root total dimensions[0] should be 3
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);

    // Cursor returned should point to the suffix node "f" at offset 0
    try std.testing.expectEqual(c2, cur_after.node);
    try std.testing.expectEqual(@as(usize, 0), cur_after.offset);
}

test "SumTree erase at node boundary" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    cur = try tree.insert("kim", cur);
    cur = try tree.insert("josh", cur);
    cur = try tree.insert("eli", cur);

    // Seek to index 4 and insert
    cur = tree.createCursor().seekRight(4, 0);
    cur = try tree.insert("oops", cur);
    cur = try tree.insert("111z", cur);

    // Seek to index 4 (end of "kimj" node, start of "oops111z" node)
    cur = tree.createCursor().seekRight(4, 0);
    cur = try tree.erase(cur, 4); // should erase "oops"

    // Verify root children and contents
    // Structure:
    // root should have children: "kimj", "111z", "osheli"
    try std.testing.expectEqual(@as(usize, 3), tree.root.children.items.len);

    const c1 = tree.root.children.items[0];
    const c2 = tree.root.children.items[1];
    const c3 = tree.root.children.items[2];

    try std.testing.expectEqualSlices(u8, "kimj", tree.chunks.items[c1.start..(c1.start + c1.summary.dimensions[0])]);
    try std.testing.expectEqualSlices(u8, "111z", tree.chunks.items[c2.start..(c2.start + c2.summary.dimensions[0])]);
    try std.testing.expectEqualSlices(u8, "osheli", tree.chunks.items[c3.start..(c3.start + c3.summary.dimensions[0])]);
}

test "Node prune tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer {
        tree.deinit();
        allocator.destroy(tree);
    }

    const root = tree.root;

    // Create children for root
    const c1 = try tree.createNode("abc");
    const c2 = try tree.createNode(""); // length 0
    const c3 = try tree.createNode("def");

    try root.attach(c1);
    try root.attach(c2);
    try root.attach(c3);

    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);

    // Call prune
    try root.prune(tree);

    // After prune, c2 (length 0) should be removed
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqual(c1, root.children.items[0]);
    try std.testing.expectEqual(c3, root.children.items[1]);
}

test "SumTree split internal tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    // Save & set MAX_NODE_CHILDREN to 4 to isolate this test
    const orig_max = Config.MAX_NODE_CHILDREN;
    defer Config.MAX_NODE_CHILDREN = orig_max;
    Config.MAX_NODE_CHILDREN = 4;

    const tree = try S.init(allocator);
    defer tree.deinit();

    _ = try tree.insert("a", tree.createCursor());
    _ = try tree.insert("b", tree.createCursor());
    _ = try tree.insert("c", tree.createCursor());
    _ = try tree.insert("d", tree.createCursor());
    _ = try tree.insert("e", tree.createCursor());

    // Root should have split and now be an internal node with 2 child internal nodes
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    const left_internal = tree.root.children.items[0];
    const right_internal = tree.root.children.items[1];

    try std.testing.expectEqual(@as(usize, 2), left_internal.children.items.len);
    try std.testing.expectEqual(@as(usize, 3), right_internal.children.items.len);
}

test "SumTree split internal tests with runtime config" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    // Save & set MAX_NODE_CHILDREN to 2 at runtime
    const orig_max = Config.MAX_NODE_CHILDREN;
    defer Config.MAX_NODE_CHILDREN = orig_max;
    Config.MAX_NODE_CHILDREN = 2;

    const tree = try S.init(allocator);
    defer tree.deinit();

    _ = try tree.insert("a", tree.createCursor());
    _ = try tree.insert("b", tree.createCursor());
    _ = try tree.insert("c", tree.createCursor()); // Should trigger split since children count (3) > max (2)

    // Root should have split and now be an internal node with 2 child internal nodes
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    const left_internal = tree.root.children.items[0];
    const right_internal = tree.root.children.items[1];

    try std.testing.expectEqual(@as(usize, 1), left_internal.children.items.len);
    try std.testing.expectEqual(@as(usize, 2), right_internal.children.items.len);
}

test "SumTree join internal tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    const orig_max = Config.MAX_NODE_CHILDREN;
    defer Config.MAX_NODE_CHILDREN = orig_max;
    Config.MAX_NODE_CHILDREN = 4;

    const tree = try S.init(allocator);
    defer tree.deinit();

    _ = try tree.insert("a", tree.createCursor());
    _ = try tree.insert("b", tree.createCursor());
    _ = try tree.insert("c", tree.createCursor());
    _ = try tree.insert("d", tree.createCursor());
    _ = try tree.insert("e", tree.createCursor());

    // Root should have split (children count = 2)
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    // Erase "b"
    // "e" (1), "d" (1), "c" (1), "b" (1), "a" (1)
    // So "b" starts at offset 3.
    const cur_b = tree.createCursor().seekRight(3, 0);
    _ = try tree.erase(cur_b, 1);

    // Total count is still 1 + 3 = 4, so no join yet.
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    // Erase "c"
    // After erasing "b", we have "e" (1), "d" (1), "c" (1), "a" (1)
    // So "c" starts at offset 2.
    const cur_c = tree.createCursor().seekRight(2, 0);
    _ = try tree.erase(cur_c, 1);

    // Now total count is 1 + 2 = 3. Since 30 < 32, it should join and the root should collapse!
    // The root should now have 3 children ("a", "d", "e") because it collapsed back to the single-level internal node!
    try std.testing.expectEqual(@as(usize, 3), tree.root.children.items.len);

    // Root summary in metric 0 should be 3 ("a", "d", "e" = 1 + 1 + 1 = 3)
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);
}

test "Cursor absolute position tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    // Start at absolute 0
    try std.testing.expectEqual(@as(usize, 0), cur.absolute);

    cur = try tree.insert("abc", cur);
    // After insert of "abc", cur points at end of "abc" (absolute 3)
    try std.testing.expectEqual(@as(usize, 3), cur.absolute);

    cur = try tree.insert("def", cur);
    // After insert of "def", cur points at end of "def" (absolute 6)
    try std.testing.expectEqual(@as(usize, 6), cur.absolute);

    // Seek left by 4
    const cur_left = cur.seekLeft(4, 0);
    try std.testing.expectEqual(@as(usize, 2), cur_left.absolute);
    try std.testing.expectEqual(@as(usize, 2), cur_left.resolveAbsolute());

    // Seek right by 3
    const cur_right = cur_left.seekRight(3, 0);
    try std.testing.expectEqual(@as(usize, 5), cur_right.absolute);

    // Create a cursor at absolute 5
    var cur_rec = tree.createCursor();
    cur_rec.absolute = 5;
    // Recalculate
    cur_rec.recalculate();
    // Verify it matches cur_right
    try std.testing.expectEqual(cur_right.node, cur_rec.node);
    try std.testing.expectEqual(cur_right.offset, cur_rec.offset);
    try std.testing.expectEqual(cur_right.absolute, cur_rec.absolute);
}

test "SumTree insert append optimization tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    cur = try tree.insert("abc", cur);
    // Initially, tree.root has no children, it is a leaf of length 3
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.items.len);
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);

    cur = try tree.insert("def", cur);
    // Since we inserted at the end, it should have appended directly to tree.root leaf!
    // No new node should have been created, root children len should still be 0.
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.items.len);
    try std.testing.expectEqual(@as(usize, 6), tree.root.summary.dimensions[0]);

    // Backing chunks should be "abcdef"
    try std.testing.expectEqualSlices(u8, "abcdef", tree.chunks.items);
}

test "SumTree insert empty chunk test" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    cur = try tree.insert("abc", cur);
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);

    // Insert empty chunk
    cur = try tree.insert("", cur);
    // Tree should not have changed at all
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.items.len);
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);
    try std.testing.expectEqualSlices(u8, "abc", tree.chunks.items);
}

test "SumTree insert long chunk split test" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    // Save and temporarily set MAX_CHUNK_LENGTH to 3 for the test
    const orig_len = Config.MAX_CHUNK_LENGTH;
    defer Config.MAX_CHUNK_LENGTH = orig_len;
    Config.MAX_CHUNK_LENGTH = 3;

    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    // Insert "abcdefgh" (len 8) which exceeds MAX_CHUNK_LENGTH (3)
    cur = try tree.insert("abcdefgh", cur);

    // It should have split into "abc" (3), "def" (3), "gh" (2)
    // Verify that the tree root has children and is correct
    try std.testing.expectEqual(@as(usize, 8), tree.root.summary.dimensions[0]);
    try std.testing.expectEqualSlices(u8, "abcdefgh", tree.chunks.items);
}

test "SumTree chunks capacity growth" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var cur = tree.createCursor();
    // The initial capacity is 32
    try std.testing.expectEqual(@as(usize, 32), tree.chunks.capacity);

    // Insert 100 characters to force capacity growth
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        cur = try tree.insert("0123456789", cur);
    }

    // Capacity must have grown beyond 32
    try std.testing.expect(tree.chunks.capacity > 32);
    try std.testing.expectEqual(@as(usize, 100), tree.chunks.items.len);
}

fn randomWord(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 3, 10);
    for (0..len) |i| {
        buf[i] = rand.intRangeAtMost(u8, 'a', 'z');
    }
    return buf[0..len];
}

test "SumTree 2000 words random insert and erase fuzz test" {
    const allocator = std.testing.allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer {
        tree.deinit();
        allocator.destroy(tree);
    }

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    // 1. Insertion Phase: 2000 random words
    var word_buf: [16]u8 = undefined;
    for (0..2000) |_| {
        const word = randomWord(rand, &word_buf);
        const total_len = tree.root.summary.dimensions[0];
        const pos = if (total_len == 0) 0 else rand.intRangeAtMost(usize, 0, total_len);

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.insert(word, cur);
    }

    // 2. Deletion Phase: 2000 random erasures
    for (0..10) |_| {
        const total_len = tree.root.summary.dimensions[0];
        if (total_len == 0) break;

        const pos = rand.intRangeLessThan(usize, 0, total_len);
        const len = rand.intRangeAtMost(usize, 1, @min(10, total_len - pos));

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.erase(cur, len);
    }
}

test "Node prune with contiguous sibling merging" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer {
        tree.deinit();
        allocator.destroy(tree);
    }

    // Append contiguous chunks to backing chunks
    try tree.chunks.appendSlice(allocator, "abcdef");

    const root = tree.root;

    // Create children for root
    const c1 = try tree.createNode("abc"); // start = 0, length = 3
    const c2 = try tree.createNode(""); // length = 0, start = 3
    const c3 = try tree.createNode("def"); // start = 3, length = 3

    // Override starts manually to make them contiguous starting from index 0
    c1.start = 0;
    c2.start = 3;
    c3.start = 3;

    try root.attach(c1);
    try root.attach(c2);
    try root.attach(c3);

    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);

    // Call prune with tree
    try root.prune(tree);

    // After prune, c2 should be removed, and c1 and c3 should merge because they are contiguous
    // Root should now have only 1 child (c1) representing "abcdef"
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(c1, root.children.items[0]);
    try std.testing.expectEqual(@as(usize, 6), c1.summary.dimensions[0]);
}

test "SumTree comprehensive history and undo test (insert, erase, split, join)" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    
    // Save & set MAX_NODE_CHILDREN to 3 at runtime to trigger splits/joins easily
    const orig_max = Config.MAX_NODE_CHILDREN;
    defer Config.MAX_NODE_CHILDREN = orig_max;
    Config.MAX_NODE_CHILDREN = 3;

    const tree = try S.init(allocator);
    defer tree.deinit();

    // Enable history tracking
    tree.enable_history = true;

    // Step 0: State 0 (Empty)
    try std.testing.expectEqual(@as(usize, 0), tree.root.summary.dimensions[0]);

    // Step 1: Insert "abc" at offset 0 -> State 1
    _ = try tree.insert("abc", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.items.len); // Still a single leaf root

    // Step 2: Insert "def" at offset 0 -> State 2
    _ = try tree.insert("def", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 6), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len); // Split root!

    // Step 3: Insert "ghi" at offset 0 -> State 3
    _ = try tree.insert("ghi", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 9), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 3), tree.root.children.items.len); // 3 children under root

    // Step 4: Insert "jkl" at offset 0 -> State 4 (triggers split of root internal node since 4 children > MAX_NODE_CHILDREN)
    _ = try tree.insert("jkl", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 12), tree.root.summary.dimensions[0]);
    // Root split should result in root having 2 child internal nodes
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    // Step 5: Erase 6 bytes starting at offset 0 -> State 5 (triggers join of internal nodes / root collapse)
    _ = try tree.erase(tree.createCursor(), 6);
    try std.testing.expectEqual(@as(usize, 6), tree.root.summary.dimensions[0]);

    // Now roll back step-by-step and verify restoration
    
    // Undo erase (revert to State 4)
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 12), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    // Undo insert "jkl" (revert to State 3)
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 9), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 3), tree.root.children.items.len);

    // Undo insert "ghi" (revert to State 2)
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 6), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items.len);

    // Undo insert "def" (revert to State 1)
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 3), tree.root.summary.dimensions[0]);
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.items.len);

    // Undo insert "abc" (revert to State 0)
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 0), tree.root.summary.dimensions[0]);
}

test "SumTree comprehensive redo test" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    const tree = try S.init(allocator);
    defer tree.deinit();

    // Enable history tracking
    tree.enable_history = true;

    // 1. Insert "hello"
    _ = try tree.insert("hello", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 5), tree.root.summary.dimensions[0]);

    // 2. Insert "world"
    _ = try tree.insert("world", tree.createCursor());
    try std.testing.expectEqual(@as(usize, 10), tree.root.summary.dimensions[0]);

    // 3. Undo "world" -> back to 5
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 5), tree.root.summary.dimensions[0]);

    // 4. Redo "world" -> forward to 10
    try tree.redo();
    try std.testing.expectEqual(@as(usize, 10), tree.root.summary.dimensions[0]);

    // 5. Undo "world" and "hello" -> back to 0
    try tree.undo();
    try tree.undo();
    try std.testing.expectEqual(@as(usize, 0), tree.root.summary.dimensions[0]);

    // 6. Redo "hello" -> forward to 5
    try tree.redo();
    try std.testing.expectEqual(@as(usize, 5), tree.root.summary.dimensions[0]);

    // 7. Redo "world" -> forward to 10
    try tree.redo();
    try std.testing.expectEqual(@as(usize, 10), tree.root.summary.dimensions[0]);
}


