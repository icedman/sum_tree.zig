# SumTree Implementation Notes & Future Improvements

This document outlines key observations on the current `SumTree` B+ tree implementation and identifies missing features or optimization opportunities for production use.

---

## 1. Backing Memory Compaction (Garbage Collection)
### Current Behavior
* When elements are erased via `erase()`, leaf nodes are either pruned or have their `start` offset advanced to truncate the deleted range.
* However, the actual string/chunk data remains in `self.chunks` (the backing flat array list).
* Over time, repeated insertions and deletions will cause `self.chunks` to grow indefinitely, leading to memory leaks/bloat.

### Missing Feature
* **Compaction / Garbage Collection**:
  A compaction algorithm is needed to periodically (or on-demand) rebuild `self.chunks`.
  * **How it would work**: Loop through all active leaf nodes in order (e.g. using `nextLeaf`), copy their active data slices into a new `ArrayList(ValueT)`, and update each leaf node's `start` index to point to its new location in the compacted array.

---

## 2. Advanced B+ Tree Balancing
### Sibling Redistribution
* Currently, if an internal node falls below the threshold, it is merged with its sibling if they have capacity.
* In standard B+ trees, if two siblings cannot merge (because their combined count exceeds `MAX_NODE_CHILDREN`), they **borrow/redistribute** children from each other to balance the load. This keeps the tree height optimal and prevents frequent split/merge oscillations.

### Leaf Node Merging
* Currently, leaf nodes are split when inserting in the middle, but they are **never merged** or balanced on deletion.
* If many deletions occur, the tree will end up with a large number of very small leaf nodes (e.g. leaf nodes containing only 1 byte).
* This degrades seek times and wastes metadata memory.
* **Missing Feature**: Implement merging of adjacent leaf nodes under the same parent when their combined length/capacity drops below a target threshold.

---

## 3. Cursor Validity & Stability
### Current Behavior
* A `TreeCursor` holds a direct pointer to a `TreeNode` (`cursor.node`).
* When tree operations (like `insert` or `erase`) split, join, or prune nodes, the node pointed to by an active cursor might be detached or deleted.
* Any subsequent seek/read using that cursor results in undefined behavior or outdated references.

### Missing Feature
* **Stable Cursors / Cursor Tracking**:
  * **Option A**: Keep a registry of active cursors in the `SumTree` struct and update their `node` and `offset` pointers whenever a B+ tree node splits, merges, or prunes.
  * **Option B**: Represent cursors as logical paths or index keys (e.g., path from root or aggregate offset) rather than raw pointers, resolving them dynamically to leaf nodes only when needed.

---

## 4. Multi-threading & Concurrent Access
* The current tree has no synchronization primitives.
* Simultaneous reads (seeks) and writes (insert/erase) from different threads will cause data races, memory errors, or infinite loops.
* **Missing Feature**: Add read-write locks (`std.Thread.RwLock`) to the `SumTree` to support safe concurrent reads while serializing writes.

---

## 5. Iterators
* Currently, to traverse all values in the tree, users must manually create cursors, seek, and loop using the internal helper `nextLeaf`.
* **Missing Feature**: Provide a clean, idiomatic Zig iterator struct:
  ```zig
  var it = tree.iterator();
  while (it.next()) |chunk| { ... }
  ```
