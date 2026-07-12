const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const config = @import("config.zig");
const Config = config.Config;

const MAX_DIMENSIONS = 32;
const MAX_CHILDREN = 32;

/// Represents the bias direction for cursor seeking operations.
pub const Bias = enum {
    left,
    right,
};

/// Aggregated multidimensional metrics/metadata for a node and its descendants.
pub const Summary = struct {
    dimensions: [MAX_DIMENSIONS]usize = [_]usize{0} ** MAX_DIMENSIONS,
};

/// A node in the B+ tree.
/// Internal nodes have `children.items.len > 0`, while leaf nodes have no children
/// and instead reference a slice of the flat backing chunk list starting at `start`.
fn Node(comptime ValueT: type) type {
    return struct {
        const Self = @This();

        id: usize = 0,

        ref: *ValueT = undefined,
        parent: ?*Self = null,

        start: usize = 0,
        summary: Summary = .{},

        allocator: Allocator,
        children: ArrayList(*Self),

        /// Constructor: Allocates memory for a Node and initializes its children array list.
        pub fn init(allocator: Allocator) !*Self {
            const node = try allocator.create(Self);
            node.* = Self{
                .allocator = allocator,
                .children = try ArrayList(*Self).initCapacity(allocator, MAX_CHILDREN),
            };
            return node;
        }

        /// Destructor: Deinitializes the children list. Memory of nodes is freed by SumTree.
        pub fn deinit(self: *Self) void {
            self.children.deinit(self.allocator);
        }

        /// Attaches a child node to this node and updates the child's parent pointer.
        pub fn attach(self: *Self, child: *Self) !void {
            try self.children.append(self.allocator, child);
            child.parent = self;
        }

        /// Recalculates this node's summary by summing the summaries of all its children.
        pub fn summarize(self: *Self) void {
            var d: Summary = .{};
            for (self.children.items) |c| {
                for (0..Config.DIMENSIONS) |i| {
                    d.dimensions[i] += c.summary.dimensions[i];
                }
            }
            self.summary = d;
        }

        /// Recursively prunes any descendants and immediate children that have zero length.
        pub fn prune(self: *Self) void {
            // First recursively prune children
            for (self.children.items) |child| {
                child.prune();
            }

            // Remove zero-length children in-place from list
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (child.summary.dimensions[0] == 0) {
                    _ = self.children.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    };
}

/// A cursor pointing to a specific offset inside a node of the SumTree.
pub fn Cursor(comptime TreeT: type, comptime NodeT: type) type {
    return struct {
        const Self = @This();

        tree: *TreeT,
        node: *NodeT,
        offset: usize, // offset within the node
        absolute: usize = 0,

        /// Calculates the absolute position (offset from root index 0) of the cursor.
        pub fn resolveAbsolute(self: Self) usize {
            var abs = self.offset;
            var curr = self.node;
            while (curr.parent) |p| {
                if (std.mem.indexOfScalar(*NodeT, p.children.items, curr)) |idx| {
                    for (p.children.items[0..idx]) |sibling| {
                        abs += sibling.summary.dimensions[0];
                    }
                    curr = p;
                } else {
                    break;
                }
            }
            return abs;
        }

        /// Recalculates the node and offset for the cursor based on its current absolute position, by seeking from the root.
        pub fn recalculate(self: *Self) void {
            const root_cursor = self.tree.createCursor();
            const target_cursor = root_cursor.seekRight(self.absolute, 0);
            self.node = target_cursor.node;
            self.offset = target_cursor.offset;
            self.absolute = target_cursor.absolute;
        }

        /// Walks up and across the tree structure to find the next sibling leaf node.
        fn nextLeaf(node: *NodeT) ?*NodeT {
            var curr = node;
            while (curr.parent) |p| {
                if (std.mem.indexOfScalar(*NodeT, p.children.items, curr)) |idx| {
                    if (idx + 1 < p.children.items.len) {
                        var next_sibling = p.children.items[idx + 1];
                        // Walk down to the leftmost leaf child of the sibling subtree
                        while (next_sibling.children.items.len > 0) {
                            next_sibling = next_sibling.children.items[0];
                        }
                        return next_sibling;
                    }
                }
                curr = p;
            }
            return null;
        }

        /// Walks up and across the tree structure to find the previous sibling leaf node.
        fn prevLeaf(node: *NodeT) ?*NodeT {
            var curr = node;
            while (curr.parent) |p| {
                if (std.mem.indexOfScalar(*NodeT, p.children.items, curr)) |idx| {
                    if (idx > 0) {
                        var prev_sibling = p.children.items[idx - 1];
                        // Walk down to the rightmost leaf child of the sibling subtree
                        while (prev_sibling.children.items.len > 0) {
                            prev_sibling = prev_sibling.children.items[prev_sibling.children.items.len - 1];
                        }
                        return prev_sibling;
                    }
                }
                curr = p;
            }
            return null;
        }

        /// Moves the cursor left by the given distance in the specified metric.
        pub fn seekLeft(self: *const Self, distance: usize, metric: u8) Self {
            var curr_node = self.node;
            var curr_offset = self.offset;

            // Normalize: if the cursor is at an internal node, descend to the leftmost leaf
            while (curr_node.children.items.len > 0) {
                curr_node = curr_node.children.items[0];
                curr_offset = 0;
            }

            var remaining = distance;
            var curr_abs = self.absolute;

            // Seek across leaf siblings to the left
            while (remaining > 0) {
                if (curr_offset >= remaining) {
                    curr_offset -= remaining;
                    if (metric == 0) {
                        curr_abs -= remaining;
                    }
                    remaining = 0;
                } else {
                    remaining -= curr_offset;
                    if (metric == 0) {
                        curr_abs -= curr_offset;
                    }
                    if (prevLeaf(curr_node)) |prev_node| {
                        curr_node = prev_node;
                        curr_offset = prev_node.summary.dimensions[metric];
                    } else {
                        curr_offset = 0;
                        remaining = 0;
                    }
                }
            }

            var res = Self{
                .tree = self.tree,
                .node = curr_node,
                .offset = curr_offset,
                .absolute = 0,
            };
            if (metric == 0) {
                res.absolute = curr_abs;
            } else {
                res.absolute = res.resolveAbsolute();
            }
            return res;
        }
        
        /// Moves the cursor right by the given distance in the specified metric.
        pub fn seekRight(self: *const Self, distance: usize, metric: u8) Self {
            var curr_node = self.node;
            var curr_offset = self.offset;

            // Normalize: if the cursor is at an internal node, descend to the leftmost leaf
            while (curr_node.children.items.len > 0) {
                curr_node = curr_node.children.items[0];
                curr_offset = 0;
            }

            var remaining = distance;
            var curr_abs = self.absolute;

            // Seek across leaf siblings to the right
            while (remaining > 0) {
                const node_size = curr_node.summary.dimensions[metric];
                if (curr_offset + remaining <= node_size) {
                    curr_offset += remaining;
                    if (metric == 0) {
                        curr_abs += remaining;
                    }
                    remaining = 0;
                } else {
                    const step = node_size - curr_offset;
                    remaining -= step;
                    if (metric == 0) {
                        curr_abs += step;
                    }
                    if (nextLeaf(curr_node)) |next_node| {
                        curr_node = next_node;
                        curr_offset = 0;
                    } else {
                        curr_offset = node_size;
                        remaining = 0;
                    }
                }
            }

            var res = Self{
                .tree = self.tree,
                .node = curr_node,
                .offset = curr_offset,
                .absolute = 0,
            };
            if (metric == 0) {
                res.absolute = curr_abs;
            } else {
                res.absolute = res.resolveAbsolute();
            }
            return res;
        }
    };
}

/// The main B+ tree container class.
/// Aggregates flat backing chunks using hierarchical summaries, supporting logarithmic seeks and updates.
pub fn SumTree(comptime ValueT: type) type {
    return struct {
        const Self = @This();
        const TreeNode = Node(ValueT);
        const TreeCursor = Cursor(Self, TreeNode);
        const TreeChunk = ArrayList(ValueT);
        const Summarizer = *const fn ([]const ValueT) Summary;

        allocator: Allocator,
        chunks: TreeChunk,
        nodes: ArrayList(*TreeNode),
        root: *TreeNode = undefined,

        summarize: Summarizer = defaultSummarizer,

        /// Default summarizer: computes the length of the slice and stores it in dimension 0.
        fn defaultSummarizer(slice: []const ValueT) Summary {
            var sum = Summary{};
            sum.dimensions[0] = slice.len;
            return sum;
        }

        /// Constructor: Allocates and initializes the SumTree container with an empty root node.
        pub fn init(allocator: Allocator) !*Self {
            const tree = try allocator.create(Self);
            tree.* = Self{
                .allocator = allocator,
                .chunks = try TreeChunk.initCapacity(allocator, 32),
                .nodes = try ArrayList(*TreeNode).initCapacity(allocator, 32),
                .root = undefined,
            };
            tree.root = try tree.createNode(&.{});
            return tree;
        }

        /// Destructor: Destroys all allocated nodes and backing lists.
        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }
            self.nodes.deinit(self.allocator);
            self.chunks.deinit(self.allocator);
        }

        /// Allocates a new node, appends it to the tracked list, and assigns its start and summary.
        pub fn createNode(self: *Self, chunk: []const ValueT) !*TreeNode {
            const node = try TreeNode.init(self.allocator); 

            try self.nodes.append(self.allocator, node);

            node.id = self.nodes.items.len - 1;
            node.start = self.chunks.items.len;
            node.summary = self.summarize(chunk);
            return node;
        }

        /// Factory: Creates a cursor at the given node and offset.
        pub fn createCursorAt(self: *Self, node: ?*TreeNode, offset: usize) TreeCursor {
            var c = TreeCursor{
                .tree = self,
                .node = node orelse self.root,
                .offset = offset,
                .absolute = 0,
            };
            c.absolute = c.resolveAbsolute();
            return c;
        }

        /// Factory: Creates a default cursor at the root (offset 0).
        pub fn createCursor(self: *Self) TreeCursor {
            return self.createCursorAt(null, 0);
        }

        /// Split internal B+ tree node algorithm:
        /// When a node's children list exceeds MAX_NODE_CHILDREN, split it in half,
        /// move the second half to a sibling node, and propagate the split up to the root.
        fn splitInternalNode(self: *Self, target_node: *TreeNode) !void {
            if (target_node.children.items.len <= Config.MAX_NODE_CHILDREN) return;

            const half = target_node.children.items.len / 2;
            const sibling_node = try self.createNode(&.{});

            // Split children list in half
            const right_children = target_node.children.items[half..];
            for (right_children) |child| {
                try sibling_node.children.append(self.allocator, child);
                child.parent = sibling_node;
            }
            target_node.children.shrinkRetainingCapacity(half);

            // Re-summarize both halves
            target_node.summarize();
            sibling_node.summarize();

            if (target_node == self.root) {
                // Root split case: create a new root, attach old root and sibling, and summarize
                const new_root = try self.createNode(&.{});
                self.root = new_root;

                try new_root.attach(target_node);
                try new_root.attach(sibling_node);

                new_root.summarize();
            } else {
                // Non-root split case: insert sibling to parent, summarize parent, and propagate split
                const parent = target_node.parent.?;
                sibling_node.parent = parent;

                const idx = std.mem.indexOfScalar(*TreeNode, parent.children.items, target_node).?;
                try parent.children.insert(self.allocator, idx + 1, sibling_node);

                parent.summarize();

                try self.splitInternalNode(parent);
            }
        }

        /// Sibling joining B+ tree balancing algorithm:
        /// Joins/merges adjacent sibling internal nodes if their combined children count falls
        /// below 80% of MAX_NODE_CHILDREN. Also collapses the root if it is left with only 1 child.
        fn joinInternalNodes(self: *Self, target_node: *TreeNode) !void {
            if (target_node == self.root) {
                // Root collapse case: copy child's children directly to the root, keeping root pointer fixed
                if (self.root.children.items.len == 1) {
                    const child = self.root.children.items[0];
                    if (child.children.items.len > 0) {
                        self.root.children.clearRetainingCapacity();
                        for (child.children.items) |c| {
                            try self.root.children.append(self.allocator, c);
                            c.parent = self.root;
                        }
                        child.children.clearRetainingCapacity();
                        self.root.summarize();
                    }
                }
                return;
            }

            const parent = target_node.parent orelse return;
            const idx = std.mem.indexOfScalar(*TreeNode, parent.children.items, target_node) orelse return;

            // Sibling join check with left sibling
            if (idx > 0) {
                const left_sibling = parent.children.items[idx - 1];
                const total_count = target_node.children.items.len + left_sibling.children.items.len;
                if (total_count * 10 < 8 * Config.MAX_NODE_CHILDREN) {
                    for (target_node.children.items) |child| {
                        try left_sibling.children.append(self.allocator, child);
                        child.parent = left_sibling;
                    }
                    target_node.children.clearRetainingCapacity();
                    _ = parent.children.orderedRemove(idx);

                    left_sibling.summarize();
                    parent.summarize();

                    try self.joinInternalNodes(parent);
                    return;
                }
            }

            // Sibling join check with right sibling
            if (idx + 1 < parent.children.items.len) {
                const right_sibling = parent.children.items[idx + 1];
                const total_count = target_node.children.items.len + right_sibling.children.items.len;
                if (total_count * 10 < 8 * Config.MAX_NODE_CHILDREN) {
                    for (right_sibling.children.items) |child| {
                        try target_node.children.append(self.allocator, child);
                        child.parent = target_node;
                    }
                    right_sibling.children.clearRetainingCapacity();
                    _ = parent.children.orderedRemove(idx + 1);

                    target_node.summarize();
                    parent.summarize();

                    try self.joinInternalNodes(parent);
                    return;
                }
            }
        }

        /// Splits a leaf node at the given offset.
        /// Useful when inserting or erasing in the middle of a leaf chunk.
        fn splitLeafNode(self: *Self, target_node: *TreeNode, offset: usize) !*TreeNode {
            const L = target_node.summary.dimensions[0];
            if (target_node == self.root) {
                // Split root leaf case: create prefix/suffix leaves, attach to root, summarize, split root if needed
                const prefix_node = try self.createNode(&.{});
                prefix_node.start = target_node.start;
                prefix_node.summary = self.summarize(self.chunks.items[prefix_node.start .. (prefix_node.start + offset)]);

                const suffix_node = try self.createNode(&.{});
                suffix_node.start = target_node.start + offset;
                suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start .. (suffix_node.start + L - offset)]);

                try self.root.attach(prefix_node);
                try self.root.attach(suffix_node);
                
                prefix_node.parent.?.summarize();

                try self.splitInternalNode(self.root);
                
                return suffix_node;
            } else {
                // Non-root leaf split: insert suffix leaf to parent, update summaries, split parent if needed
                const parent_node = target_node.parent.?;
                const idx = std.mem.indexOfScalar(*TreeNode, parent_node.children.items, target_node).?;

                const suffix_node = try self.createNode(&.{});
                suffix_node.start = target_node.start + offset;
                suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start .. (suffix_node.start + L - offset)]);
                suffix_node.parent = parent_node;

                target_node.summary = self.summarize(self.chunks.items[target_node.start .. (target_node.start + offset)]);

                try parent_node.children.insert(self.allocator, idx + 1, suffix_node);
                
                var curr_parent = target_node.parent;
                while (curr_parent) |p| {
                    p.summarize();
                    curr_parent = p.parent;
                }

                try self.splitInternalNode(parent_node);
                
                return suffix_node;
            }
        }

        /// B+ tree insertion algorithm:
        /// Seeks cursor location, splits target leaf node if cursor is positioned in the middle,
        /// inserts the new chunk as a sibling node, and propagates splits and summarizations up to the root.
        pub fn insert(self: *Self, chunk: []const ValueT, cursor_: TreeCursor) !TreeCursor {
            var cursor = cursor_;
            cursor.absolute = cursor.resolveAbsolute();

            const target_cursor = cursor.seekRight(0, 0);
            const target_node = target_cursor.node;
            const offset = target_cursor.offset;
            const L = target_node.summary.dimensions[0];

            // Check if we can simply append to the target node
            if (offset == L and target_node.start + L == self.chunks.items.len) {
                try self.chunks.appendSlice(self.allocator, chunk);
                target_node.summary = self.summarize(self.chunks.items[target_node.start .. target_node.start + L + chunk.len]);

                var c = cursor;
                c.node = target_node;
                c.offset = target_node.summary.dimensions[0];
                c.absolute = c.resolveAbsolute();

                // Bubble up summarization updates
                var curr_parent = target_node.parent;
                while (curr_parent) |p| {
                    p.summarize();
                    curr_parent = p.parent;
                }
                return c;
            }

            const n = try self.createNode(chunk);

            if (target_node == self.root) {
                // If found node is root, split/insert directly as child
                if (offset > 0 and offset < L) {
                    const prefix_node = try self.createNode(&.{});
                    prefix_node.start = target_node.start;
                    prefix_node.summary = self.summarize(self.chunks.items[prefix_node.start .. (prefix_node.start + offset)]);

                    const suffix_node = try self.createNode(&.{});
                    suffix_node.start = target_node.start + offset;
                    suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start .. (suffix_node.start + L - offset)]);

                    try self.root.attach(prefix_node);
                    try self.root.attach(n);
                    try self.root.attach(suffix_node);
                } else if (offset == 0) {
                    const suffix_node = try self.createNode(&.{});
                    suffix_node.start = target_node.start;
                    suffix_node.summary = target_node.summary;

                    try self.root.attach(n);
                    try self.root.attach(suffix_node);
                } else {
                    const prefix_node = try self.createNode(&.{});
                    prefix_node.start = target_node.start;
                    prefix_node.summary = target_node.summary;

                    try self.root.attach(prefix_node);
                    try self.root.attach(n);
                }
                try self.splitInternalNode(self.root);
            } else {
                // Insert as sibling in parent list, split leaf if in the middle
                const parent_node = target_node.parent.?;
                const idx = std.mem.indexOfScalar(*TreeNode, parent_node.children.items, target_node).?;

                if (offset > 0 and offset < L) {
                    const suffix_node = try self.createNode(&.{});
                    suffix_node.start = target_node.start + offset;
                    suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start .. (suffix_node.start + L - offset)]);
                    suffix_node.parent = parent_node;

                    target_node.summary = self.summarize(self.chunks.items[target_node.start .. (target_node.start + offset)]);

                    try parent_node.children.insert(self.allocator, idx + 1, n);
                    n.parent = parent_node;
                    try parent_node.children.insert(self.allocator, idx + 2, suffix_node);
                } else if (offset == 0) {
                    try parent_node.children.insert(self.allocator, idx, n);
                    n.parent = parent_node;
                } else {
                    try parent_node.children.insert(self.allocator, idx + 1, n);
                    n.parent = parent_node;
                }
                try self.splitInternalNode(parent_node);
            }

            try self.chunks.appendSlice(self.allocator, chunk);

            var c = cursor;
            c.node = n;
            c.offset = n.summary.dimensions[0];

            // Bubble up summarization updates
            var curr_parent = n.parent;
            while (curr_parent) |p| {
                p.summarize();
                curr_parent = p.parent;
            }

            c.recalculate();
            return c;
        }

        /// B+ tree range deletion (erase) algorithm:
        /// Seeks cursor, splits first node if offset is in the middle, and loops forward
        /// zeroing out fully deleted leaves (dimensions[0] = 0) or truncating the start of partially deleted leaves.
        /// Balances and prunes/joins the tree structure on completion.
        pub fn erase(self: *Self, cursor_: TreeCursor, length: usize) !TreeCursor {
            var cursor = cursor_;
            cursor.absolute = cursor.resolveAbsolute();

            const target_cursor = cursor.seekRight(0, 0);
            var curr_node = target_cursor.node;
            var curr_offset = target_cursor.offset;
            var remaining = length;

            var affected_parents = ArrayList(*TreeNode).empty;
            defer affected_parents.deinit(self.allocator);

            // Normalize start of erase by splitting leaf if offset is in the middle
            const L = curr_node.summary.dimensions[0];
            if (curr_offset > 0 and curr_offset < L) {
                curr_node = try self.splitLeafNode(curr_node, curr_offset);
                curr_offset = 0;
            }

            // Loop across nodes to erase the range
            while (remaining > 0) {
                const node_size = curr_node.summary.dimensions[0];
                if (remaining >= node_size) {
                    // Full erase: zero out summary, record affected parent, bubble up summary updates
                    curr_node.summary = .{};
                    
                    if (curr_node.parent) |p| {
                        var found = false;
                        for (affected_parents.items) |item| {
                            if (item == p) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try affected_parents.append(self.allocator, p);
                        }
                    }

                    var curr_parent = curr_node.parent;
                    while (curr_parent) |p| {
                        p.summarize();
                        curr_parent = p.parent;
                    }

                    remaining -= node_size;
                    if (remaining > 0) {
                        if (TreeCursor.nextLeaf(curr_node)) |next_node| {
                            curr_node = next_node;
                        } else {
                            break;
                        }
                    }
                } else {
                    // Partial erase: truncate start offset, re-summarize, bubble up updates
                    curr_node.start += remaining;
                    curr_node.summary = self.summarize(self.chunks.items[curr_node.start .. (curr_node.start + node_size - remaining)]);
                    
                    var curr_parent = curr_node.parent;
                    while (curr_parent) |p| {
                        p.summarize();
                        curr_parent = p.parent;
                    }

                    remaining = 0;
                }
            }
            
            var c = TreeCursor{
                .tree = self,
                .node = curr_node,
                .offset = 0,
                .absolute = 0,
            };
            c.absolute = c.resolveAbsolute();

            // Prune zero-length nodes and join sibling nodes recursively
            for (affected_parents.items) |parent| {
                parent.prune();
                try self.joinInternalNodes(parent);
            }
            
            c.recalculate();
            return c;
        }
        

        pub fn dump(self: Self, node: *TreeNode, depth: usize) void {
            for (0..depth) |_| std.debug.print("  ", .{});
            // std.debug.print("?{*} -> {*}\n", .{ node, node.parent });
            std.debug.print("node {}: ", .{node.id});

            if (node.children.items.len == 0) {
                const len = node.summary.dimensions[0];
                if (len > 0) {
                    const slice = self.chunks.items[node.start..(node.start + len)];
                    std.debug.print("{s}\n", .{slice});
                }
            } else {
                std.debug.print("\n", .{});
            }

            for (node.children.items) |n| {
                self.dump(n, depth + 1);
            }
        }
    };
}

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

test "Node prune tests" {
    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

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
    root.prune();

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

fn randomWord(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, 10);
    for (0..len) |i| {
        buf[i] = rand.intRangeAtMost(u8, 'a', 'z');
    }
    return buf[0..len];
}

test "SumTree 200 words random insert and erase fuzz test" {
    const allocator = std.testing.allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer {
        tree.deinit();
        allocator.destroy(tree);
    }

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    // 1. Insertion Phase: 200 random words
    var word_buf: [16]u8 = undefined;
    for (0..200) |_| {
        const word = randomWord(rand, &word_buf);
        const total_len = tree.root.summary.dimensions[0];
        const pos = if (total_len == 0) 0 else rand.intRangeAtMost(usize, 0, total_len);

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.insert(word, cur);
    }

    // 2. Deletion Phase: 200 random erasures
    for (0..2000) |_| {
        const total_len = tree.root.summary.dimensions[0];
        if (total_len == 0) break;

        const pos = rand.intRangeLessThan(usize, 0, total_len);
        const len = rand.intRangeAtMost(usize, 1, @min(10, total_len - pos));

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.erase(cur, len);
    }
}








