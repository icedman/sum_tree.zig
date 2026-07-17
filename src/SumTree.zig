const std = @import("std");
const Allocator = std.mem.Allocator;

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

        pub fn appendSlice(self: *BSelf, items: []const T) void {
            for (items) |item| {
                self.append(item);
            }
        }

        pub fn insert(self: *BSelf, idx: usize, item: T) void {
            var i: usize = self.len;
            while (i > idx) : (i -= 1) {
                self.data[i] = self.data[i - 1];
            }
            self.data[idx] = item;
            self.len += 1;
        }

        pub fn slice(self: *const BSelf) []const T {
            return self.data[0..self.len];
        }

        pub fn sliceMut(self: *BSelf) []T {
            return self.data[0..self.len];
        }
    };
}

pub const Bias = enum {
    left,
    right,
};

pub fn SumTree(comptime Item: type) type {
    const Summary = Item.Summary;
    return struct {
        const Self = @This();
        pub const MAX_CHILDREN = 8;
        pub const MIN_CHILDREN = MAX_CHILDREN / 2;

        pub const Node = struct {
            rc: usize = 1,
            height: usize = 0,
            summary: Summary,
            children: union(enum) {
                internal: BoundedArray(*Node, MAX_CHILDREN),
                leaf: BoundedArray(Item, MAX_CHILDREN),
            },

            pub fn initLeaf(allocator: Allocator, cx: Summary.Context) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .rc = 1,
                    .height = 0,
                    .summary = Summary.zero(cx),
                    .children = .{ .leaf = .{} },
                };
                return node;
            }

            pub fn initInternal(allocator: Allocator, height: usize, cx: Summary.Context) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .rc = 1,
                    .height = height,
                    .summary = Summary.zero(cx),
                    .children = .{ .internal = .{} },
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
                    switch (self.children) {
                        .internal => |internal| {
                            for (internal.slice()) |child| {
                                child.deref(allocator);
                            }
                        },
                        .leaf => {},
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
                    .children = self.children,
                };
                switch (copy.children) {
                    .internal => |internal| {
                        for (internal.slice()) |child| {
                            _ = child.ref();
                        }
                    },
                    .leaf => {},
                }
                return copy;
            }

            pub fn summarize(self: *Node, cx: Summary.Context) void {
                self.summary = Summary.zero(cx);
                switch (self.children) {
                    .internal => |internal| {
                        for (internal.slice()) |child| {
                            self.summary.add(child.summary, cx);
                        }
                    },
                    .leaf => |leaf| {
                        for (leaf.slice()) |it| {
                            self.summary.add(it.summary(cx), cx);
                        }
                    },
                }
            }
        };

        allocator: Allocator,
        root: *Node,
        cx: Summary.Context,

        enable_history: bool = false,
        history_index: usize = 0,
        in_transaction: bool = false,
        history: std.ArrayList(*Node),

        pub fn init(allocator: Allocator, cx: Summary.Context) !*Self {
            const tree = try allocator.create(Self);
            const root = try Node.initLeaf(allocator, cx);
            tree.* = .{
                .allocator = allocator,
                .root = root,
                .cx = cx,
                .history = std.ArrayList(*Node).empty,
            };
            return tree;
        }

        pub fn deinit(self: *Self) void {
            self.root.deref(self.allocator);
            for (self.history.items) |node| {
                node.deref(self.allocator);
            }
            self.history.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn clone(self: *Self) !*Self {
            const copy = try self.allocator.create(Self);
            copy.* = .{
                .allocator = self.allocator,
                .root = self.root.ref(),
                .cx = self.cx,
                .history = std.ArrayList(*Node).empty,
            };
            return copy;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.root.isLeaf() and self.root.children.leaf.len == 0;
        }

        pub fn startTransaction(self: *Self) !void {
            if (self.enable_history and self.history.items.len == 0) {
                try self.history.append(self.allocator, self.root.ref());
            }
        }

        pub fn saveHistory(self: *Self) !void {
            while (self.history.items.len > self.history_index + 1) {
                const node = self.history.pop().?;
                node.deref(self.allocator);
            }
            try self.history.append(self.allocator, self.root.ref());
            self.history_index = self.history.items.len - 1;
        }

        pub fn undo(self: *Self) !void {
            if (!self.enable_history) return error.HistoryDisabled;
            if (self.history_index == 0) return;

            self.history_index -= 1;
            const old = self.root;
            self.root = self.history.items[self.history_index].ref();
            old.deref(self.allocator);
        }

        pub fn redo(self: *Self) !void {
            if (!self.enable_history) return error.HistoryDisabled;
            if (self.history_index >= self.history.items.len - 1) return;

            self.history_index += 1;
            const old = self.root;
            self.root = self.history.items[self.history_index].ref();
            old.deref(self.allocator);
        }

        pub const SplitResult = struct {
            left: *Self,
            right: *Self,
        };

        const SplitNodes = struct {
            left: *Node,
            right: *Node,
        };

        pub fn split(self: *Self, comptime Dim: type, target: anytype, bias: Bias) !SplitResult {
            var position = Dim.zero(self.cx);
            const res = try self.splitNode(Dim, self.root, target, bias, &position);

            const left_tree = try self.allocator.create(Self);
            left_tree.* = .{
                .allocator = self.allocator,
                .root = res.left,
                .cx = self.cx,
                .history = std.ArrayList(*Node).empty,
            };

            const right_tree = try self.allocator.create(Self);
            right_tree.* = .{
                .allocator = self.allocator,
                .root = res.right,
                .cx = self.cx,
                .history = std.ArrayList(*Node).empty,
            };

            return .{ .left = left_tree, .right = right_tree };
        }

        fn collapseNode(self: *Self, node: *Node) !*Node {
            var curr = node;
            while (!curr.isLeaf() and curr.children.internal.len == 1) {
                const child = curr.children.internal.data[0].ref();
                curr.deref(self.allocator);
                curr = child;
            }
            if (!curr.isLeaf() and curr.children.internal.len == 0) {
                const empty_leaf = try Node.initLeaf(self.allocator, self.cx);
                curr.deref(self.allocator);
                curr = empty_leaf;
            }
            return curr;
        }

        fn splitNode(self: *Self, comptime Dim: type, node: *Node, target: anytype, bias: Bias, position: *Dim) anyerror!SplitNodes {
            const res = try self.splitNodeRec(Dim, node, target, bias, position);
            errdefer {
                res.left.deref(self.allocator);
                res.right.deref(self.allocator);
            }
            const left_collapsed = try self.collapseNode(res.left);
            errdefer left_collapsed.deref(self.allocator);
            const right_collapsed = try self.collapseNode(res.right);
            return .{ .left = left_collapsed, .right = right_collapsed };
        }

        fn splitNodeRec(self: *Self, comptime Dim: type, node: *Node, target: anytype, bias: Bias, position: *Dim) anyerror!SplitNodes {
            if (node.isLeaf()) {
                const left = try Node.initLeaf(self.allocator, self.cx);
                const right = try Node.initLeaf(self.allocator, self.cx);
                errdefer {
                    left.deref(self.allocator);
                    right.deref(self.allocator);
                }

                var split_idx: ?usize = null;
                for (node.children.leaf.slice(), 0..) |item, idx| {
                    var item_end = position.*;
                    item_end.addSummary(item.summary(self.cx), self.cx);
                    const order = target.cmp(item_end, self.cx);
                    if (order == .lt or (order == .eq and bias == .left)) {
                        split_idx = idx;
                        break;
                    } else {
                        left.children.leaf.append(item);
                        position.* = item_end;
                    }
                }

                if (split_idx) |idx| {
                    for (node.children.leaf.slice()[idx..]) |item| {
                        right.children.leaf.append(item);
                    }
                }

                left.summarize(self.cx);
                right.summarize(self.cx);
                return .{ .left = left, .right = right };
            } else {
                const left = try Node.initInternal(self.allocator, node.height, self.cx);
                const right = try Node.initInternal(self.allocator, node.height, self.cx);
                errdefer {
                    left.deref(self.allocator);
                    right.deref(self.allocator);
                }

                var split_idx: ?usize = null;
                var child_res: ?SplitNodes = null;

                for (node.children.internal.slice(), 0..) |child, idx| {
                    var child_end = position.*;
                    child_end.addSummary(child.summary, self.cx);
                    const order = target.cmp(child_end, self.cx);
                    if (order == .lt or (order == .eq and bias == .left)) {
                        split_idx = idx;
                        child_res = try self.splitNodeRec(Dim, child, target, bias, position);
                        break;
                    } else {
                        left.children.internal.append(child.ref());
                        position.* = child_end;
                    }
                }

                if (split_idx) |idx| {
                    if (child_res.?.left.isLeaf() and child_res.?.left.children.leaf.len > 0) {
                        left.children.internal.append(child_res.?.left);
                    } else if (!child_res.?.left.isLeaf() and child_res.?.left.children.internal.len > 0) {
                        left.children.internal.append(child_res.?.left);
                    } else {
                        child_res.?.left.deref(self.allocator);
                    }

                    if (child_res.?.right.isLeaf() and child_res.?.right.children.leaf.len > 0) {
                        right.children.internal.append(child_res.?.right);
                    } else if (!child_res.?.right.isLeaf() and child_res.?.right.children.internal.len > 0) {
                        right.children.internal.append(child_res.?.right);
                    } else {
                        child_res.?.right.deref(self.allocator);
                    }

                    for (node.children.internal.slice()[idx + 1 ..]) |child| {
                        right.children.internal.append(child.ref());
                    }
                }

                left.summarize(self.cx);
                right.summarize(self.cx);

                return .{ .left = left, .right = right };
            }
        }

        fn toMut(self: *Self, node: *Node) !*Node {
            if (node.rc > 1) {
                const copy = try node.clone(self.allocator);
                node.deref(self.allocator);
                return copy;
            }
            return node;
        }

        const JoinResult = struct {
            left: *Node,
            right: ?*Node,
        };

        fn joinNodes(self: *Self, left: *Node, right: *Node) !JoinResult {
            if (left.height == right.height) {
                if (left.height == 0) {
                    const total_items = left.children.leaf.len + right.children.leaf.len;
                    if (total_items <= MAX_CHILDREN) {
                        const mut_left = try self.toMut(left);
                        for (right.children.leaf.slice()) |item| {
                            mut_left.children.leaf.append(item);
                        }
                        mut_left.summarize(self.cx);
                        right.deref(self.allocator);
                        return .{ .left = mut_left, .right = null };
                    } else {
                        var all_items = BoundedArray(Item, MAX_CHILDREN * 2).empty();
                        for (left.children.leaf.slice()) |item| {
                            all_items.append(item);
                        }
                        for (right.children.leaf.slice()) |item| {
                            all_items.append(item);
                        }

                        const midpoint = all_items.len / 2;
                        const mut_left = try self.toMut(left);
                        mut_left.children.leaf.len = 0;
                        for (all_items.slice()[0..midpoint]) |item| {
                            mut_left.children.leaf.append(item);
                        }
                        mut_left.summarize(self.cx);

                        const split_sibling = try Node.initLeaf(self.allocator, self.cx);
                        for (all_items.slice()[midpoint..]) |item| {
                            split_sibling.children.leaf.append(item);
                        }
                        split_sibling.summarize(self.cx);

                        right.deref(self.allocator);
                        return .{ .left = mut_left, .right = split_sibling };
                    }
                } else {
                    const total_children = left.children.internal.len + right.children.internal.len;
                    if (total_children <= MAX_CHILDREN) {
                        const mut_left = try self.toMut(left);
                        for (right.children.internal.slice()) |child| {
                            mut_left.children.internal.append(child.ref());
                        }
                        mut_left.summarize(self.cx);
                        right.deref(self.allocator);
                        return .{ .left = mut_left, .right = null };
                    } else {
                        var all_children = BoundedArray(*Node, MAX_CHILDREN * 2).empty();
                        for (left.children.internal.slice()) |child| {
                            all_children.append(child.ref());
                        }
                        for (right.children.internal.slice()) |child| {
                            all_children.append(child.ref());
                        }

                        const midpoint = all_children.len / 2;
                        const mut_left = try self.toMut(left);
                        for (mut_left.children.internal.slice()) |child| {
                            child.deref(self.allocator);
                        }
                        mut_left.children.internal.len = 0;
                        for (all_children.slice()[0..midpoint]) |child| {
                            mut_left.children.internal.append(child);
                        }
                        mut_left.summarize(self.cx);

                        const split_sibling = try Node.initInternal(self.allocator, left.height, self.cx);
                        for (all_children.slice()[midpoint..]) |child| {
                            split_sibling.children.internal.append(child);
                        }
                        split_sibling.summarize(self.cx);

                        right.deref(self.allocator);
                        return .{ .left = mut_left, .right = split_sibling };
                    }
                }
            } else if (left.height > right.height) {
                const mut_left = try self.toMut(left);
                const last_idx = mut_left.children.internal.len - 1;
                const last_child = mut_left.children.internal.data[last_idx];

                const res = try self.joinNodes(last_child, right);
                mut_left.children.internal.data[last_idx] = res.left;

                if (res.right) |rn| {
                    if (mut_left.children.internal.len < MAX_CHILDREN) {
                        mut_left.children.internal.append(rn);
                        mut_left.summarize(self.cx);
                        return .{ .left = mut_left, .right = null };
                    } else {
                        var all_children = BoundedArray(*Node, MAX_CHILDREN + 1).empty();
                        for (mut_left.children.internal.slice()) |child| {
                            all_children.append(child.ref());
                        }
                        all_children.append(rn);

                        const midpoint = all_children.len / 2;
                        for (mut_left.children.internal.slice()) |child| {
                            child.deref(self.allocator);
                        }
                        mut_left.children.internal.len = 0;
                        for (all_children.slice()[0..midpoint]) |child| {
                            mut_left.children.internal.append(child);
                        }
                        mut_left.summarize(self.cx);

                        const split_sibling = try Node.initInternal(self.allocator, mut_left.height, self.cx);
                        for (all_children.slice()[midpoint..]) |child| {
                            split_sibling.children.internal.append(child);
                        }
                        split_sibling.summarize(self.cx);

                        return .{ .left = mut_left, .right = split_sibling };
                    }
                } else {
                    mut_left.summarize(self.cx);
                    return .{ .left = mut_left, .right = null };
                }
            } else {
                const mut_right = try self.toMut(right);
                const first_child = mut_right.children.internal.data[0];

                const res = try self.joinNodes(left, first_child);
                mut_right.children.internal.data[0] = res.left;

                if (res.right) |rn| {
                    if (mut_right.children.internal.len < MAX_CHILDREN) {
                        var idx = mut_right.children.internal.len;
                        while (idx > 1) : (idx -= 1) {
                            mut_right.children.internal.data[idx] = mut_right.children.internal.data[idx - 1];
                        }
                        mut_right.children.internal.data[1] = rn;
                        mut_right.children.internal.len += 1;
                        mut_right.summarize(self.cx);
                        return .{ .left = mut_right, .right = null };
                    } else {
                        var all_children = BoundedArray(*Node, MAX_CHILDREN + 1).empty();
                        all_children.append(res.left.ref());
                        all_children.append(rn);
                        for (mut_right.children.internal.slice()[1..]) |child| {
                            all_children.append(child.ref());
                        }

                        const midpoint = all_children.len / 2;
                        for (mut_right.children.internal.slice()) |child| {
                            child.deref(self.allocator);
                        }
                        mut_right.children.internal.len = 0;
                        for (all_children.slice()[0..midpoint]) |child| {
                            mut_right.children.internal.append(child);
                        }
                        mut_right.summarize(self.cx);

                        const split_sibling = try Node.initInternal(self.allocator, mut_right.height, self.cx);
                        for (all_children.slice()[midpoint..]) |child| {
                            split_sibling.children.internal.append(child);
                        }
                        split_sibling.summarize(self.cx);

                        return .{ .left = mut_right, .right = split_sibling };
                    }
                } else {
                    mut_right.summarize(self.cx);
                    return .{ .left = mut_right, .right = null };
                }
            }
        }

        pub fn append(self: *Self, other: *Self) !void {
            if (self.isEmpty()) {
                const old = self.root;
                self.root = other.root.ref();
                old.deref(self.allocator);
                return;
            }
            if (other.isEmpty()) {
                return;
            }

            const was_in = self.in_transaction;
            if (!was_in) {
                self.in_transaction = true;
                try self.startTransaction();
            }
            defer if (!was_in) {
                self.in_transaction = false;
                if (self.enable_history) self.saveHistory() catch {};
            };

            const res = try self.joinNodes(self.root.ref(), other.root.ref());
            const old = self.root;
            if (res.right) |rn| {
                const new_root = try Node.initInternal(self.allocator, res.left.height + 1, self.cx);
                new_root.children.internal.append(res.left);
                new_root.children.internal.append(rn);
                new_root.summarize(self.cx);
                self.root = new_root;
            } else {
                self.root = res.left;
            }
            old.deref(self.allocator);
            self.root = try self.collapseNode(self.root);
        }

        pub fn appendNode(self: *Self, other: **Node) !void {
            const other_is_empty = other.*.isLeaf() and other.*.children.leaf.len == 0;
            if (self.isEmpty()) {
                const old = self.root;
                self.root = other.*;
                old.deref(self.allocator);
                return;
            }
            if (other_is_empty) {
                other.*.deref(self.allocator);
                return;
            }

            const was_in = self.in_transaction;
            if (!was_in) {
                self.in_transaction = true;
                try self.startTransaction();
            }
            defer if (!was_in) {
                self.in_transaction = false;
                if (self.enable_history) self.saveHistory() catch {};
            };

            const res = try self.joinNodes(self.root.ref(), other.*);
            const old = self.root;
            if (res.right) |rn| {
                const new_root = try Node.initInternal(self.allocator, res.left.height + 1, self.cx);
                new_root.children.internal.append(res.left);
                new_root.children.internal.append(rn);
                new_root.summarize(self.cx);
                self.root = new_root;
            } else {
                self.root = res.left;
            }
            old.deref(self.allocator);
            self.root = try self.collapseNode(self.root);
        }

        pub fn push(self: *Self, item: Item) !void {
            const was_in = self.in_transaction;
            if (!was_in) {
                self.in_transaction = true;
                try self.startTransaction();
            }
            defer if (!was_in) {
                self.in_transaction = false;
                if (self.enable_history) self.saveHistory() catch {};
            };

            const new_leaf = try Node.initLeaf(self.allocator, self.cx);
            new_leaf.children.leaf.append(item);
            new_leaf.summarize(self.cx);

            var nl = new_leaf;
            try self.appendNode(&nl);
        }

        pub fn Cursor(comptime Dimension: type) type {
            return struct {
                const CSelf = @This();

                tree: *SumTree(Item),
                stack: BoundedArray(StackEntry, 32) = .{},
                position: Dimension,
                cx: Summary.Context,
                sought_val: ?usize = null,

                const StackEntry = struct {
                    node: *Node,
                    index: usize,
                    offset: Dimension,
                };

                pub fn init(tree: *SumTree(Item)) CSelf {
                    var c = CSelf{
                        .tree = tree,
                        .position = Dimension.zero(tree.cx),
                        .cx = tree.cx,
                    };
                    c.reset();
                    return c;
                }

                pub fn reset(self: *CSelf) void {
                    self.stack.len = 0;
                    self.position = Dimension.zero(self.cx);
                    self.sought_val = null;
                    if (!self.tree.isEmpty()) {
                        self.stack.append(.{
                            .node = self.tree.root,
                            .index = 0,
                            .offset = Dimension.zero(self.cx),
                        });
                        self.descendToLeaf();
                    }
                }

                fn descendToLeaf(self: *CSelf) void {
                    while (true) {
                        const top = &self.stack.data[self.stack.len - 1];
                        if (top.node.isLeaf()) break;
                        const child = top.node.children.internal.data[top.index];
                        self.stack.append(.{
                            .node = child,
                            .index = 0,
                            .offset = self.position,
                        });
                    }
                }

                pub fn item(self: *const CSelf) ?Item {
                    if (self.stack.len == 0) return null;
                    const top = &self.stack.data[self.stack.len - 1];
                    if (top.index >= top.node.children.leaf.len) return null;
                    return top.node.children.leaf.data[top.index];
                }

                pub fn next(self: *CSelf) void {
                    if (self.stack.len == 0) {
                        if (!self.tree.isEmpty()) {
                            self.stack.append(.{
                                .node = self.tree.root,
                                .index = 0,
                                .offset = Dimension.zero(self.cx),
                            });
                            self.descendToLeaf();
                            self.position = Dimension.zero(self.cx);
                        }
                        return;
                    }

                    var top = &self.stack.data[self.stack.len - 1];
                    const current_item = top.node.children.leaf.data[top.index];
                    self.position.addSummary(current_item.summary(self.cx), self.cx);
                    top.index += 1;

                    if (top.index < top.node.children.leaf.len) {
                        return;
                    }

                    while (self.stack.len > 0) {
                        self.stack.len -= 1;
                        if (self.stack.len == 0) {
                            self.position = Dimension.zero(self.cx);
                            self.position.addSummary(self.tree.root.summary, self.cx);
                            return;
                        }
                        var parent_top = &self.stack.data[self.stack.len - 1];
                        parent_top.index += 1;
                        if (parent_top.index < parent_top.node.children.internal.len) {
                            self.descendToLeaf();
                            return;
                        }
                    }
                }

                pub fn prev(self: *CSelf) void {
                    if (self.stack.len == 0) return;

                    var top = &self.stack.data[self.stack.len - 1];
                    if (top.index > 0) {
                        top.index -= 1;
                        self.recomputePosition();
                        return;
                    }

                    while (self.stack.len > 0) {
                        self.stack.len -= 1;
                        if (self.stack.len == 0) {
                            self.position = Dimension.zero(self.cx);
                            return;
                        }
                        var parent_top = &self.stack.data[self.stack.len - 1];
                        if (parent_top.index > 0) {
                            parent_top.index -= 1;
                            self.descendToRightmostLeaf();
                            return;
                        }
                    }
                }

                pub fn descendToRightmostLeaf(self: *CSelf) void {
                    while (true) {
                        const top = &self.stack.data[self.stack.len - 1];
                        if (top.node.isLeaf()) {
                            top.index = top.node.children.leaf.len - 1;
                            self.recomputePosition();
                            break;
                        }
                        const child = top.node.children.internal.data[top.index];
                        self.stack.append(.{
                            .node = child,
                            .index = child.children.internal.len - 1,
                            .offset = Dimension.zero(self.cx),
                        });
                    }
                }

                fn recomputePosition(self: *CSelf) void {
                    self.position = Dimension.zero(self.cx);
                    for (self.stack.sliceMut()) |*entry| {
                        entry.offset = self.position;
                        switch (entry.node.children) {
                            .internal => |internal| {
                                for (internal.slice()[0..entry.index]) |child| {
                                    self.position.addSummary(child.summary, self.cx);
                                }
                            },
                            .leaf => |leaf| {
                                for (leaf.slice()[0..entry.index]) |it| {
                                    self.position.addSummary(it.summary(self.cx), self.cx);
                                }
                            },
                        }
                    }
                }

                pub fn getPosition(self: *const CSelf, comptime Dim: type) Dim {
                    if (Dim == Dimension and self.sought_val != null) {
                        return Dim{ .val = self.sought_val.? };
                    }
                    var pos = Dim.zero(self.cx);
                    for (self.stack.slice()) |entry| {
                        switch (entry.node.children) {
                            .internal => |internal| {
                                for (internal.slice()[0..entry.index]) |child| {
                                    pos.addSummary(child.summary, self.cx);
                                }
                            },
                            .leaf => |leaf| {
                                for (leaf.slice()[0..entry.index]) |it| {
                                    pos.addSummary(it.summary(self.cx), self.cx);
                                }
                            },
                        }
                    }
                    return pos;
                }

                pub fn seekTo(self: *CSelf, target: anytype, bias: Bias) void {
                    self.reset();
                    if (self.stack.len == 0) return;

                    self.stack.len = 0;
                    self.position = Dimension.zero(self.cx);

                    var curr = self.tree.root;
                    while (true) {
                        if (curr.isLeaf()) {
                            self.stack.append(.{
                                .node = curr,
                                .index = 0,
                                .offset = self.position,
                            });
                            const top = &self.stack.data[self.stack.len - 1];
                            for (curr.children.leaf.slice(), 0..) |item_val, idx| {
                                var item_end = self.position;
                                item_end.addSummary(item_val.summary(self.cx), self.cx);
                                const order = target.cmp(item_end, self.cx);
                                if (order == .lt or (order == .eq and bias == .left)) {
                                    top.index = idx;
                                    break;
                                }
                                self.position = item_end;
                                top.index = idx + 1;
                            }
                            break;
                        } else {
                            var found_child = false;
                            for (curr.children.internal.slice(), 0..) |child, idx| {
                                var child_end = self.position;
                                child_end.addSummary(child.summary, self.cx);
                                const order = target.cmp(child_end, self.cx);
                                if (order == .lt or (order == .eq and bias == .left)) {
                                    self.stack.append(.{
                                        .node = curr,
                                        .index = idx,
                                        .offset = self.position,
                                    });
                                    curr = child;
                                    found_child = true;
                                    break;
                                }
                                self.position = child_end;
                            }
                            if (!found_child) {
                                const last_idx = curr.children.internal.len - 1;
                                self.stack.append(.{
                                    .node = curr,
                                    .index = last_idx,
                                    .offset = self.position,
                                });
                                curr = curr.children.internal.data[last_idx];
                                self.recomputePosition();
                            }
                        }
                    }
                    if (@hasField(@TypeOf(target), "target") and @hasField(Dimension, "val")) {
                        self.sought_val = @intCast(target.target);
                    }
                }

                pub fn slice(self: *CSelf, target: anytype, bias: Bias) !*SumTree(Item) {
                    const pos_A = self.position;

                    var pos_A_dim = Dimension.zero(self.cx);
                    const target_A = DimensionSeekTarget(Dimension){ .target = pos_A };
                    const split_A = try self.tree.splitNode(Dimension, self.tree.root, target_A, .right, &pos_A_dim);
                    errdefer split_A.left.deref(self.tree.allocator);
                    defer split_A.right.deref(self.tree.allocator);

                    const split_B = try self.tree.splitNode(Dimension, split_A.right, target, bias, &pos_A_dim);
                    errdefer split_B.left.deref(self.tree.allocator);
                    defer split_B.right.deref(self.tree.allocator);

                    const slice_tree = try SumTree(Item).init(self.tree.allocator, self.cx);
                    slice_tree.root.deref(self.tree.allocator);
                    slice_tree.root = split_B.left;

                    split_A.left.deref(self.tree.allocator);

                    self.seekTo(target, bias);
                    return slice_tree;
                }

                pub fn suffix(self: *CSelf) !*SumTree(Item) {
                    const end_target = EndSeekTarget{};
                    return self.slice(end_target, .right);
                }
            };
        }
    };
}

pub fn DimensionSeekTarget(comptime Dim: type) type {
    return struct {
        target: Dim,
        pub fn cmp(self: @This(), pos: Dim, cx: anytype) std.math.Order {
            _ = cx;
            if (@hasField(Dim, "val")) {
                return std.math.order(self.target.val, pos.val);
            }
            if (@hasField(Dim, "max_key")) {
                if (pos.max_key) |pk| {
                    if (self.target.max_key) |tk| {
                        const K = @TypeOf(pk);
                        const compareKeys = @import("TreeMap.zig").compareKeys;
                        return compareKeys(K, tk, pk);
                    }
                    return .lt;
                }
                return .gt;
            }
            @compileError("Unsupported Dimension type for split seek target");
        }
    };
}

const EndSeekTarget = struct {
    pub fn cmp(self: EndSeekTarget, cursor_pos: anytype, cx: anytype) std.math.Order {
        _ = self;
        _ = cursor_pos;
        _ = cx;
        return .gt;
    }
};
