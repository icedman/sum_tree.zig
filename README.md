# SumTree

`SumTree` is a generic, high-performance B+ tree container implemented in Zig. It aggregates flat backing chunks using hierarchical multidimensional summaries to support logarithmic seeks, range operations, snapshots, and undo/redo history tracking.

## Features

- **Hierarchical Summaries**: Fast seeks and updates over multi-dimensional metrics (e.g., character offsets, line counts).
- **Logarithmic Range Operations**: Fast insertions and deletions (`insert`, `erase`) with automatic node splitting, joining, and tree balancing.
- **Undo/Redo History**: Built-in transactional state snapshots allowing changes to be undone or redone.
- **Snapshots**: In-place cloning/mirroring of active trees using node timestamps to selectively sync changed subtrees.
- **Range & Conditional Collection**: Gather affected leaf nodes across a specified range or based on custom conditions (`collect`, `collectUntil`).
- **Idiomatic Iterators**: Clean sequential traversal of all leaf chunks in the tree.

---

## Usage Example

The following example demonstrates how to initialize the tree, perform inserts and deletes, and iterate over all chunks:

```zig
const std = @import("std");
const st = @import("SumTree.zig");
const SumTree = st.SumTree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize a SumTree for u8 character data
    const tree = try SumTree(u8).init(allocator);
    defer tree.deinit();

    // Enable history tracking for undo/redo
    tree.enable_history = true;

    // 2. Insert data using a cursor
    var cursor = tree.createCursor();
    cursor = try tree.insert("hello ", cursor);
    cursor = try tree.insert("world!", cursor);

    // Root summary shows total character length (dimension 0)
    std.debug.print("Tree length: {}\n", .{tree.root.summary.dimensions[0]}); // Output: 12

    // 3. Sequential traversal using Iterator
    var it = tree.iterator();
    std.debug.print("Chunks:\n", .{});
    while (it.next()) |chunk| {
        std.debug.print("  - \"{s}\"\n", .{chunk});
    }

    // 4. Undo and Redo operations
    try tree.undo(); // Reverts the "world!" insertion
    std.debug.print("After undo length: {}\n", .{tree.root.summary.dimensions[0]}); // Output: 6

    try tree.redo(); // Re-applies the "world!" insertion
    std.debug.print("After redo length: {}\n", .{tree.root.summary.dimensions[0]}); // Output: 12

    // 5. Collecting nodes matching a range
    var bucket = std.ArrayList(*SumTree(u8).TreeNode).empty;
    defer bucket.deinit(allocator);

    const start_cursor = tree.createCursor().seekRight(2, 0); // start at index 2 ('l')
    _ = try tree.collect(start_cursor, 6, &bucket); // collect for 6 characters

    std.debug.print("Collected {} nodes.\n", .{bucket.items.len});
}
```

## Running Tests

To run the unit tests:

```bash
zig build test
```
