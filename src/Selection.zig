const std = @import("std");

pub const Selection = struct {
    id: usize,
    head: usize, // cursor head position (absolute byte offset in the rope)
    tail: usize, // selection tail position (absolute byte offset in the rope)
    goal_column: ?usize = null, // visual column we want to maintain when moving vertically

    pub fn init(id: usize, head: usize, tail: usize) Selection {
        return .{
            .id = id,
            .head = head,
            .tail = tail,
        };
    }

    pub fn start(self: Selection) usize {
        return @min(self.head, self.tail);
    }

    pub fn end(self: Selection) usize {
        return @max(self.head, self.tail);
    }

    pub fn is_empty(self: Selection) bool {
        return self.head == self.tail;
    }

    pub fn contains(self: Selection, offset: usize) bool {
        if (self.is_empty()) return false;
        return offset >= self.start() and offset < self.end();
    }
};

pub const SelectionManager = struct {
    allocator: std.mem.Allocator,
    selections: std.ArrayList(Selection),
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) SelectionManager {
        return .{
            .allocator = allocator,
            .selections = std.ArrayList(Selection).init(allocator),
        };
    }

    pub fn deinit(self: *SelectionManager) void {
        self.selections.deinit();
    }

    pub fn clear(self: *SelectionManager) void {
        self.selections.clearRetainingCapacity();
    }

    pub fn addSelection(self: *SelectionManager, head: usize, tail: usize) !void {
        const id = self.next_id;
        self.next_id += 1;
        try self.selections.append(Selection.init(id, head, tail));
        self.normalize();
    }

    pub fn getPrimary(self: SelectionManager) ?Selection {
        if (self.selections.items.len == 0) return null;
        return self.selections.items[self.selections.items.len - 1];
    }

    pub fn setPrimary(self: *SelectionManager, head: usize, tail: usize) !void {
        self.clear();
        try self.addSelection(head, tail);
    }

    // Sorts and merges overlapping/adjacent selections to maintain disjoint selections
    pub fn normalize(self: *SelectionManager) void {
        if (self.selections.items.len <= 1) return;

        // Sort by start offset
        std.sort.block(Selection, self.selections.items, {}, sortSelections);

        var merged = std.ArrayList(Selection).init(self.allocator);
        defer merged.deinit();

        for (self.selections.items) |sel| {
            if (merged.items.len == 0) {
                merged.append(sel) catch {};
                continue;
            }

            var last = &merged.items[merged.items.len - 1];
            if (sel.start() <= last.end()) {
                const new_start = @min(last.start(), sel.start());
                const new_end = @max(last.end(), sel.end());
                const is_reversed = sel.head < sel.tail;
                const new_head = if (is_reversed) new_start else new_end;
                const new_tail = if (is_reversed) new_end else new_start;

                last.head = new_head;
                last.tail = new_tail;
            } else {
                merged.append(sel) catch {};
            }
        }

        self.selections.clearRetainingCapacity();
        self.selections.appendSlice(merged.items) catch {};
    }

    fn sortSelections(context: void, a: Selection, b: Selection) bool {
        _ = context;
        return a.start() < b.start();
    }

    pub fn isOffsetSelected(self: SelectionManager, offset: usize) bool {
        for (self.selections.items) |sel| {
            if (sel.contains(offset)) return true;
        }
        return false;
    }
};
