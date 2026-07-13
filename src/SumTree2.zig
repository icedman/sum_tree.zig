const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const BSelf = @This();
        data: [capacity]T = undefined,
        len: usize = 0,

        pub fn empty() BSelf {
            return .{};
        }

        pub fn append(self: *BSelf, item: T) void {
            self.data[self.len] = item;
            self.len += 1;
        }

        pub fn insert(self: *BSelf, idx: usize, item: T) void {
            var i: usize = self.len;
            while (i > idx) : (i -= 1) {
                self.data[i] = self.data[i - 1];
            }
            self.data[idx] = item;
            self.len += 1;
        }

        pub fn slice(self: BSelf) []const T {
            return self.data[0..self.len];
        }

        pub fn sliceMut(self: *BSelf) []T {
            return self.data[0..self.len];
        }
    };
}

pub fn SumTree2(comptime ValueT: type) type {
    return struct {
        const Self = @This();
        pub const MAX_CHILDREN = 8;
        pub const MIN_CHILDREN = MAX_CHILDREN / 2;

        pub const Summary = struct {
            dimensions: [1]usize = .{0},

            pub fn zero() Summary {
                return .{ .dimensions = .{0} };
            }

            pub fn add(self: *Summary, other: Summary) void {
                self.dimensions[0] += other.dimensions[0];
            }
        };

        pub const Node = struct {
            rc: usize = 1,
            height: usize = 0,
            summary: Summary = Summary.zero(),
            start: usize = 0,
            children: BoundedArray(*Node, MAX_CHILDREN) = .{},

            pub fn initLeaf(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .rc = 1,
                    .height = 0,
                    .summary = Summary.zero(),
                    .start = 0,
                    .children = .{},
                };
                return node;
            }

            pub fn initInternal(allocator: Allocator, height: usize) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .rc = 1,
                    .height = height,
                    .summary = Summary.zero(),
                    .start = 0,
                    .children = .{},
                };
                return node;
            }

            pub fn isLeaf(self: Node) bool {
                return self.height == 0;
            }

            pub fn ref(self: *Node) *Node {
                self.rc += 1;
                return self;
            }

            pub fn deref(self: *Node, allocator: Allocator) void {
                self.rc -= 1;
                if (self.rc == 0) {
                    if (self.height > 0) {
                        for (self.children.slice()) |child| {
                            child.deref(allocator);
                        }
                    }
                    allocator.destroy(self);
                }
            }

            pub fn clone(self: *Node, allocator: Allocator) !*Node {
                const copy = try allocator.create(Node);
                copy.* = .{
                    .rc = 1,
                    .height = self.height,
                    .summary = self.summary,
                    .start = self.start,
                    .children = self.children,
                };
                if (self.height > 0) {
                    for (copy.children.slice()) |child| {
                        _ = child.ref();
                    }
                }
                return copy;
            }

            pub fn summarize(self: *Node) void {
                self.summary = Summary.zero();
                if (self.isLeaf()) {
                    // Leaf summary is preserved directly (updated during split/slice)
                } else {
                    for (self.children.slice()) |child| {
                        self.summary.add(child.summary);
                    }
                }
            }
        };

        allocator: Allocator,
        root: *Node,
        chunks: *std.ArrayList(u8),
        managed_chunks: bool = true,

        pub fn init(allocator: Allocator) !*Self {
            const tree = try allocator.create(Self);
            const root = try Node.initLeaf(allocator);
            const chunks = try allocator.create(std.ArrayList(u8));
            chunks.* = std.ArrayList(u8).empty;

            tree.* = .{
                .allocator = allocator,
                .root = root,
                .chunks = chunks,
                .managed_chunks = true,
            };
            return tree;
        }

        pub fn deinit(self: *Self) void {
            self.root.deref(self.allocator);
            if (self.managed_chunks) {
                self.chunks.deinit(self.allocator);
                self.allocator.destroy(self.chunks);
            }
            self.allocator.destroy(self);
        }

        pub fn clone(self: *Self) !*Self {
            const copy = try self.allocator.create(Self);
            copy.* = .{
                .allocator = self.allocator,
                .root = self.root.ref(),
                .chunks = self.chunks,
                .managed_chunks = false,
            };
            return copy;
        }

        fn makeMut(self: *Self, node_ptr: **Node) !void {
            const node = node_ptr.*;
            if (node.rc > 1) {
                const copy = try node.clone(self.allocator);
                node.deref(self.allocator);
                node_ptr.* = copy;
            }
        }

        fn joinNodes(self: *Self, left_ptr: **Node, right_ptr: **Node) !?*Node {
            var left = left_ptr.*;
            var right = right_ptr.*;

            if (left.height == right.height) {
                if (left.height == 0) {
                    const left_L = left.summary.dimensions[0];
                    if (left.start + left_L == right.start) {
                        try self.makeMut(left_ptr);
                        left_ptr.*.summary.dimensions[0] += right.summary.dimensions[0];
                        right.deref(self.allocator);
                        return null;
                    } else {
                        return right;
                    }
                } else {
                    const total_children = left.children.len + right.children.len;
                    if (total_children <= MAX_CHILDREN) {
                        try self.makeMut(left_ptr);
                        left = left_ptr.*;
                        for (right.children.slice()) |child| {
                            left.children.append(child.ref());
                        }
                        left.summarize();
                        right.deref(self.allocator);
                        return null;
                    } else {
                        try self.makeMut(left_ptr);
                        left = left_ptr.*;

                        var all_children = BoundedArray(*Node, MAX_CHILDREN * 2).empty();
                        for (left.children.slice()) |child| {
                            all_children.append(child.ref());
                        }
                        for (right.children.slice()) |child| {
                            all_children.append(child.ref());
                        }

                        const midpoint = all_children.len / 2;

                        for (left.children.slice()) |child| {
                            child.deref(self.allocator);
                        }
                        left.children.len = 0;
                        for (all_children.slice()[0..midpoint]) |child| {
                            left.children.append(child);
                        }
                        left.summarize();

                        const split_sibling = try Node.initInternal(self.allocator, left.height);
                        for (all_children.slice()[midpoint..]) |child| {
                            split_sibling.children.append(child);
                        }
                        split_sibling.summarize();

                        right.deref(self.allocator);
                        return split_sibling;
                    }
                }
            } else if (left.height > right.height) {
                try self.makeMut(left_ptr);
                left = left_ptr.*;

                const last_idx = left.children.len - 1;
                var last_child = left.children.data[last_idx];
                const split_child = try self.joinNodes(&last_child, &right);
                left.children.data[last_idx] = last_child;

                if (split_child) |sc| {
                    if (left.children.len < MAX_CHILDREN) {
                        left.children.append(sc);
                        left.summarize();
                        return null;
                    } else {
                        var all_children = BoundedArray(*Node, MAX_CHILDREN + 1).empty();
                        for (left.children.slice()) |child| {
                            all_children.append(child.ref());
                        }
                        all_children.append(sc);

                        const midpoint = all_children.len / 2;

                        for (left.children.slice()) |child| {
                            child.deref(self.allocator);
                        }
                        left.children.len = 0;
                        for (all_children.slice()[0..midpoint]) |child| {
                            left.children.append(child);
                        }
                        left.summarize();

                        const split_sibling = try Node.initInternal(self.allocator, left.height);
                        for (all_children.slice()[midpoint..]) |child| {
                            split_sibling.children.append(child);
                        }
                        split_sibling.summarize();

                        return split_sibling;
                    }
                } else {
                    left.summarize();
                    return null;
                }
            } else {
                try self.makeMut(right_ptr);
                right = right_ptr.*;

                var first_child = right.children.data[0];
                const split_child = try self.joinNodes(&left, &first_child);
                right.children.data[0] = first_child;

                if (split_child) |sc| {
                    if (right.children.len < MAX_CHILDREN) {
                        var idx = right.children.len;
                        while (idx > 0) : (idx -= 1) {
                            right.children.data[idx] = right.children.data[idx - 1];
                        }
                        right.children.data[0] = sc;
                        right.children.len += 1;
                        right.summarize();
                        return null;
                    } else {
                        var all_children = BoundedArray(*Node, MAX_CHILDREN + 1).empty();
                        all_children.append(sc);
                        for (right.children.slice()) |child| {
                            all_children.append(child.ref());
                        }

                        const midpoint = all_children.len / 2;

                        var left_half = BoundedArray(*Node, MAX_CHILDREN).empty();
                        var right_half = BoundedArray(*Node, MAX_CHILDREN).empty();
                        for (all_children.slice()[0..midpoint]) |child| {
                            left_half.append(child);
                        }
                        for (all_children.slice()[midpoint..]) |child| {
                            right_half.append(child);
                        }

                        for (right.children.slice()) |child| {
                            child.deref(self.allocator);
                        }

                        right.children.len = 0;
                        for (left_half.slice()) |child| {
                            right.children.append(child);
                        }
                        right.summarize();

                        const split_sibling = try Node.initInternal(self.allocator, right.height);
                        for (right_half.slice()) |child| {
                            split_sibling.children.append(child);
                        }
                        split_sibling.summarize();

                        return split_sibling;
                    }
                } else {
                    right.summarize();
                    return null;
                }
            }
        }

        pub fn append(self: *Self, other: *Self) !void {
            var r = other.root.ref();
            const split_node = try self.joinNodes(&self.root, &r);
            if (split_node) |sn| {
                const new_root = try Node.initInternal(self.allocator, self.root.height + 1);
                new_root.children.append(self.root);
                new_root.children.append(sn);
                new_root.summarize();
                self.root = new_root;
            }
        }

        pub fn appendNode(self: *Self, other: **Node) !void {
            const split_node = try self.joinNodes(&self.root, other);
            if (split_node) |sn| {
                const new_root = try Node.initInternal(self.allocator, self.root.height + 1);
                new_root.children.append(self.root);
                new_root.children.append(sn);
                new_root.summarize();
                self.root = new_root;
            }
        }

        pub fn push(self: *Self, text: []const u8) !void {
            if (text.len == 0) return;
            const start_idx = self.chunks.items.len;
            try self.chunks.appendSlice(self.allocator, text);

            const new_leaf = try Node.initLeaf(self.allocator);
            new_leaf.start = start_idx;
            new_leaf.summary.dimensions[0] = text.len;

            var nl = new_leaf;
            try self.appendNode(&nl);
        }

        pub fn replace(self: *Self, start: usize, len: usize, text: []const u8) !void {
            var cursor = Cursor.init(self);
            const prefix = try cursor.slice(start);
            defer prefix.deinit();

            cursor.seekTo(start + len);
            const suffix = try cursor.suffix();
            defer suffix.deinit();

            const old_root = self.root;
            self.root = try Node.initLeaf(self.allocator);
            old_root.deref(self.allocator);

            try self.append(prefix);
            try self.push(text);
            try self.append(suffix);
        }

        pub const Cursor = struct {
            tree: *SumTree2(ValueT),
            stack: BoundedArray(StackEntry, 16) = .{},
            offset: usize = 0,

            pub const StackEntry = struct {
                node: *Node,
                index: usize,
                offset: usize,
            };

            pub fn init(tree: *SumTree2(ValueT)) Cursor {
                var c = Cursor{
                    .tree = tree,
                };
                c.reset();
                return c;
            }

            pub fn reset(self: *Cursor) void {
                self.stack.len = 0;
                self.offset = 0;
                if (self.tree.root.summary.dimensions[0] > 0) {
                    self.stack.append(.{
                        .node = self.tree.root,
                        .index = 0,
                        .offset = 0,
                    });
                    self.descendToLeaf();
                }
            }

            fn descendToLeaf(self: *Cursor) void {
                while (true) {
                    const top = &self.stack.data[self.stack.len - 1];
                    if (top.node.isLeaf()) break;
                    const child = top.node.children.data[top.index];
                    self.stack.append(.{
                        .node = child,
                        .index = 0,
                        .offset = self.offset,
                    });
                }
            }

            pub fn seekTo(self: *Cursor, target: usize) void {
                self.reset();
                if (self.stack.len == 0) return;

                self.stack.len = 0;
                self.offset = 0;

                var curr = self.tree.root;
                while (true) {
                    if (curr.isLeaf()) {
                        const top = StackEntry{
                            .node = curr,
                            .index = 0,
                            .offset = self.offset,
                        };
                        self.stack.append(top);
                        const remaining = target - self.offset;
                        const leaf_size = curr.summary.dimensions[0];
                        if (remaining >= leaf_size) {
                            self.offset += leaf_size;
                        } else {
                            self.offset = target;
                        }
                        break;
                    } else {
                        var child_offset = self.offset;
                        var found_child = false;
                        for (curr.children.slice(), 0..) |child, idx| {
                            const child_size = child.summary.dimensions[0];
                            if (target < child_offset + child_size) {
                                self.stack.append(.{
                                    .node = curr,
                                    .index = idx,
                                    .offset = self.offset,
                                });
                                self.offset = child_offset;
                                curr = child;
                                found_child = true;
                                break;
                            }
                            child_offset += child_size;
                        }
                        if (!found_child) {
                            const last_idx = curr.children.len - 1;
                            const last_child = curr.children.data[last_idx];
                            self.stack.append(.{
                                .node = curr,
                                .index = last_idx,
                                .offset = self.offset,
                            });
                            self.offset = child_offset - last_child.summary.dimensions[0];
                            curr = last_child;
                        }
                    }
                }
            }

            pub fn slice(self: *Cursor, length: usize) !*SumTree2(ValueT) {
                const slice_tree = try SumTree2(ValueT).init(self.tree.allocator);
                errdefer slice_tree.deinit();

                slice_tree.chunks.deinit(slice_tree.allocator);
                slice_tree.allocator.destroy(slice_tree.chunks);
                slice_tree.chunks = self.tree.chunks;
                slice_tree.managed_chunks = false;

                if (length == 0 or self.stack.len == 0) {
                    return slice_tree;
                }

                var remaining = length;
                while (remaining > 0 and self.stack.len > 0) {
                    const leaf_entry = &self.stack.data[self.stack.len - 1];
                    const leaf_node = leaf_entry.node;
                    const leaf_size = leaf_node.summary.dimensions[0];
                    const leaf_offset = self.offset - leaf_entry.offset;
                    const available = leaf_size - leaf_offset;

                    if (remaining <= available) {
                        const slice_leaf = try Node.initLeaf(self.tree.allocator);
                        slice_leaf.start = leaf_node.start + leaf_offset;
                        slice_leaf.summary.dimensions[0] = remaining;

                        var sl = slice_leaf;
                        try slice_tree.appendNode(&sl);
                        self.offset += remaining;
                        remaining = 0;
                        break;
                    } else {
                        const slice_leaf = try Node.initLeaf(self.tree.allocator);
                        slice_leaf.start = leaf_node.start + leaf_offset;
                        slice_leaf.summary.dimensions[0] = available;

                        var sl = slice_leaf;
                        try slice_tree.appendNode(&sl);
                        self.offset += available;
                        remaining -= available;

                        self.stack.len -= 1;
                        var descended = false;
                        while (self.stack.len > 0) {
                            var top = &self.stack.data[self.stack.len - 1];
                            if (top.index + 1 < top.node.children.len) {
                                top.index += 1;
                                const sibling = top.node.children.data[top.index];
                                const sibling_size = sibling.summary.dimensions[0];

                                if (remaining >= sibling_size) {
                                    var sib = sibling.ref();
                                    try slice_tree.appendNode(&sib);
                                    self.offset += sibling_size;
                                    remaining -= sibling_size;
                                } else {
                                    self.stack.append(.{
                                        .node = sibling,
                                        .index = 0,
                                        .offset = self.offset,
                                    });
                                    while (true) {
                                        const new_top = &self.stack.data[self.stack.len - 1];
                                        if (new_top.node.isLeaf()) break;
                                        const child = new_top.node.children.data[0];
                                        self.stack.append(.{
                                            .node = child,
                                            .index = 0,
                                            .offset = self.offset,
                                        });
                                    }
                                    descended = true;
                                    break;
                                }
                            } else {
                                self.stack.len -= 1;
                            }
                        }
                        if (!descended and remaining > 0) {
                            break;
                        }
                    }
                }

                return slice_tree;
            }

            pub fn suffix(self: *Cursor) !*SumTree2(ValueT) {
                const total_size = self.tree.root.summary.dimensions[0];
                const remaining = if (total_size > self.offset) total_size - self.offset else 0;
                return self.slice(remaining);
            }
        };
    };
}
