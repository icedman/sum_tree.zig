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

## Undo/Redo & Transaction History

`SumTree` (and by extension `Rope`) has a powerful built-in history tracking mechanism supporting undo, redo, manual transaction grouping, and time-based auto-save coalescing.

### 1. Enabling History

To use history tracking on a `SumTree` or a `Rope`, you must explicitly enable it:

```zig
// For a SumTree directly:
tree.enable_history = true;

// For a Rope:
rope.setEnableHistory(true); // or rope.tree.enable_history = true;
```

### 2. Manual Transactions (Grouping Edits)

By default, every mutation (like `push` or `insert`) is treated as a single undo/redo transaction and committed immediately. You can group multiple edits into a single transaction so they are undone/redone as a single action:

```zig
// Start a manual transaction
try tree.startTransaction();

try tree.push(item1);
try tree.push(item2);

// Commit the transaction and save it to history
try tree.commitHistory(edit_offset);
```

If something goes wrong during the transaction, you can discard all changes since the transaction started:

```zig
// Roll back to the state before the current transaction started
tree.rollbackTransaction();
```

### 3. Auto-Save History (Time-based Coalescing)

If you are building an editor, you may want typing operations to be automatically coalesced/grouped into single undo steps based on time delays:

- **Enable Auto-Save**: Set `tree.auto_save_history = true;` (or `rope.tree.auto_save_history = true;`).
- **Set the Commit Delay**: Set the timeout delay using `tree.history_commit_delay` (in nanoseconds). The default is `2000 * std.time.ns_per_ms` (2 seconds).
- **Check Auto-Save Periodically**: In your editor tick loop or input handler, call `try tree.checkAutoSave();` (or `try rope.tree.checkAutoSave();`). This will automatically commit the current edits if the specified delay has passed since the last mutation.

Example setup:
```zig
tree.enable_history = true;
tree.auto_save_history = true;
tree.history_commit_delay = 1500 * std.time.ns_per_ms; // Coalesce edits within 1.5 seconds

// In your input loop:
try tree.push(typed_character);

// In your periodic tick / timer handler:
try tree.checkAutoSave();
```

---

## Running Tests

To run the unit tests:

```bash
zig build test
```
