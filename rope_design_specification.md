# Rope.zig Design Specification

This document specifies the design for `Rope.zig` implemented on top of the persistent, Copy-on-Write (COW) `SumTree`. It mirrors the features of Zed's `rope` crate and integrates multi-metric seeks, point coordinates (rows and columns), and transactional history tracking.

---

## 1. Multi-Dimensional Summary Metrics

`Rope.zig` uses three independent dimensions stored in the `Summary.dimensions` array of `SumTree(u8)`:

1. **Metric 0: UTF-8 Bytes (Character Offset)**
   - Tracks the absolute character byte count.
   - Serves as the primary B+ tree extent for boundary slicing.
2. **Metric 1: Newline Count (Row Offset)**
   - Tracks the number of `\n` characters in each chunk.
   - Enables row-based seeks and point queries.
3. **Metric 2: UTF-16 Code Units**
   - Tracks the number of UTF-16 code units (indexing U+10000 to U+10FFFF as 2 code units for surrogate pairs).
   - Essential for interoperability with LSP and other editors.

### Metric Summarizers

We register two custom summarizers in the tree during `Rope.init`:
* **Newline Summarizer (Metric 1)**: Counts newlines using `std.mem.count(u8, chunk, "\n")`.
* **UTF-16 Summarizer (Metric 2)**: Counts UTF-16 code units by walking the UTF-8 byte sequences.

---

## 2. Coordinate Mapping & Point Systems

We define a 2D text coordinate point:
```zig
pub const Point = struct {
    row: usize,
    column: usize,
};
```

### Conversions using `offsetForMetric`

By extending `Cursor` with `offsetForMetric(target_metric)`, we can convert positions in $O(\log N)$ time:

1. **`pointToOffset(point: Point) usize`**
   - Seek a cursor by metric `1` (newlines) to `point.row`.
   - Query the character offset (metric `0`) of the start of the row using `cursor.offsetForMetric(0)`.
   - Return `row_start_char_offset + point.column`.
   
2. **`offsetToPoint(offset: usize) Point`**
   - Seek a cursor by metric `0` (characters) to `offset`.
   - The `row` index is the cumulative newline count at that position, queried via `cursor.offsetForMetric(1)`.
   - The start character offset of that row is queried by seeking a temporary cursor to `row` (metric 1) and getting its character offset.
   - `column = offset - start_row_char_offset`.

---

## 3. High-level Transactional APIs

`Rope.zig` exposes the following public APIs:

* **`init(allocator)` / `deinit()`**: Manage tree lifecycle and register custom summarizers.
* **`insert(offset, text)`**: Insert a string at a character offset (implemented as `replace(offset, 0, text)`).
* **`delete(offset, len)`**: Delete a character range (implemented as `replace(offset, len, "")`).
* **`replace(offset, len, text)`**: Atomic transactional replace, wrapped by `SumTree` history tracking.
* **`clone()`**: $O(1)$ snapshot creation leveraging B+ tree functional persistence.
* **`undo()` / `redo()`**: Revert/re-apply changes in $O(1)$ time.
* **`text(buffer)`**: Collect the entire rope content into a contiguous string.
