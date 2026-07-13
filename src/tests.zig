const std = @import("std");
const st = @import("SumTree.zig");
const SumTree = st.SumTree;

fn collectLeafSlices(allocator: std.mem.Allocator, node: anytype, chunks: []const u8, bucket: *std.ArrayList(u8)) anyerror!void {
    if (node.isLeaf()) {
        const len = node.summary.dimensions[0];
        try bucket.appendSlice(allocator, chunks[node.start .. node.start + len]);
    } else {
        for (node.children.slice()) |child| {
            try collectLeafSlices(allocator, child, chunks, bucket);
        }
    }
}

test "SumTree basic functionality" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    
    // 1. Init and push
    const tree = try S.init(allocator);
    defer tree.deinit();

    try tree.push("hello ");
    try tree.push("world");
    try std.testing.expectEqual(@as(usize, 11), tree.root.summary.dimensions[0]);
    try std.testing.expectEqualSlices(u8, "hello world", tree.chunks.items);

    // 2. Clone (sharing check)
    const tree_clone = try tree.clone();
    defer tree_clone.deinit();

    try std.testing.expectEqual(@as(usize, 11), tree_clone.root.summary.dimensions[0]);
    try std.testing.expect(tree.root == tree_clone.root); // points to the same root!
    try std.testing.expect(tree.root.rc == 2); // ref count is 2!

    // 3. Mutation check on clone (COW)
    try tree_clone.push("!");
    // tree_clone should be modified: length 12
    try std.testing.expectEqual(@as(usize, 12), tree_clone.root.summary.dimensions[0]);
    // tree should be unaffected: length 11
    try std.testing.expectEqual(@as(usize, 11), tree.root.summary.dimensions[0]);
    // root pointers should be different now!
    try std.testing.expect(tree.root != tree_clone.root);
    // original root ref count should be decremented back to 1
    try std.testing.expect(tree.root.rc == 1);

    // 4. Append check
    const tree2 = try S.init(allocator);
    defer tree2.deinit();
    try tree2.push(" hello from tree2");

    const tree_appended = try tree.clone();
    defer tree_appended.deinit();
    try tree_appended.append(tree2);
    try std.testing.expectEqual(@as(usize, 28), tree_appended.root.summary.dimensions[0]);

    // 5. Replace (insert / delete) check
    // "hello world" -> replace "world" with "there" at index 6, len 5
    const tree_replace = try tree.clone();
    defer tree_replace.deinit();
    try tree_replace.replace(6, 5, "there");
    
    // Total size should be 11 (hello there)
    try std.testing.expectEqual(@as(usize, 11), tree_replace.root.summary.dimensions[0]);

    // Let's verify the text of tree_replace using a cursor and slice
    var cursor = S.Cursor.init(tree_replace);
    const sliced = try cursor.slice(11);
    defer sliced.deinit();
    
    try std.testing.expectEqual(@as(usize, 11), sliced.root.summary.dimensions[0]);

    var bucket = std.ArrayList(u8).empty;
    defer bucket.deinit(allocator);
    try collectLeafSlices(allocator, sliced.root, sliced.chunks.items, &bucket);
    try std.testing.expectEqualSlices(u8, "hello there", bucket.items);
}

test "SumTree edge cases" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);

    const tree = try S.init(allocator);
    defer tree.deinit();

    // Push empty text (should be no-op)
    try tree.push("");
    try std.testing.expectEqual(@as(usize, 0), tree.root.summary.dimensions[0]);

    // Replace on empty tree (insert)
    try tree.replace(0, 0, "initial");
    try std.testing.expectEqual(@as(usize, 7), tree.root.summary.dimensions[0]);

    var bucket = std.ArrayList(u8).empty;
    defer bucket.deinit(allocator);
    try collectLeafSlices(allocator, tree.root, tree.chunks.items, &bucket);
    try std.testing.expectEqualSlices(u8, "initial", bucket.items);
}
