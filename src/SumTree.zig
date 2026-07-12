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

        const Clone = struct {
            allocator: Allocator,
            id: usize = 0,    
            parent_id: usize = 0,    
            start: usize = 0,
            children: ArrayList(usize),
            summary: Summary = .{},

            pub fn init(allocator: Allocator) !*Clone {
                const clone = try allocator.create(Clone);
                clone.* = Clone{
                    .allocator = allocator,
                    .children = try ArrayList(usize).initCapacity(allocator, MAX_CHILDREN),
                };
                return clone;
            }

            pub fn deinit(self: *Clone) void {
                self.children.deinit(self.allocator);
            }
        };

        allocator: Allocator,

        ref: *ValueT = undefined, // unused
        parent: ?*Self = null,

        // cloneable data
        id: usize = 0,
        parent_id: usize = 0,
        start: usize = 0,
        children: ArrayList(*Self),
        summary: Summary = .{},

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

        /// Checks if this node is a leaf node (i.e. has no children).
        pub fn isLeaf(self: *const Self) bool {
            return self.children.items.len == 0;
        }

        /// Attaches a child node to this node and updates the child's parent pointer.
        pub fn attach(self: *Self, child: *Self) !void {
            try self.children.append(self.allocator, child);
            child.parent = self;
            child.parent_id = self.id;
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
        /// If a zero-length node is removed, merges adjacent sibling leaf nodes if they are contiguous based on start and L.
        pub fn prune(self: *Self, tree: anytype) anyerror!void {
            if (self.isLeaf()) return;

            // First recursively prune children
            for (self.children.items) |child| {
                try child.prune(tree);
            }

            const old_len = self.children.items.len;

            // Remove zero-length children in-place from list and merge contiguous siblings
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (child.summary.dimensions[0] == 0) {
                    try tree.cloneNode(self);
                    _ = self.children.orderedRemove(i);
                    tree.destroyNode(child);

                    // Check contiguous leaf merge between left and right siblings
                    if (i > 0 and i < self.children.items.len) {
                        const left = self.children.items[i - 1];
                        const right = self.children.items[i];
                        if (left.isLeaf() and right.isLeaf()) {
                            const left_L = left.summary.dimensions[0];
                            const right_L = right.summary.dimensions[0];
                            if (left.start + left_L == right.start) {
                                try tree.cloneNode(left);
                                left.summary = tree.summarize(tree.chunks.items[left.start .. left.start + left_L + right_L]);
                                try tree.cloneNode(self);
                                const sibling = self.children.orderedRemove(i);
                                tree.destroyNode(sibling);
                            }
                        }
                    }
                } else {
                    i += 1;
                }
            }

            if (self.children.items.len != old_len) {
                try tree.cloneNode(self);
                self.summarize();
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
                        while (!next_sibling.isLeaf()) {
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
                        while (!prev_sibling.isLeaf()) {
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
            while (!curr_node.isLeaf()) {
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
            while (!curr_node.isLeaf()) {
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

        enable_history: bool = false,

        allocator: Allocator,
        chunks: TreeChunk,

        timestamp: i64 = 0,

        nodes: ArrayList(*TreeNode),
        clones: ArrayList(*TreeNode.Clone),
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
                .clones = try ArrayList(*TreeNode.Clone).initCapacity(allocator, 32),
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
            for (self.clones.items) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }
            self.nodes.deinit(self.allocator);
            self.clones.deinit(self.allocator);
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
                try self.cloneNode(child);
                try sibling_node.children.append(self.allocator, child);
                child.parent = sibling_node;
            }
            try self.cloneNode(target_node);
            target_node.children.shrinkRetainingCapacity(half);

            // Re-summarize both halves
            target_node.summarize();
            sibling_node.summarize();

            if (target_node == self.root) {
                // Root split case: create a new root, attach old root and sibling, and summarize
                const new_root = try self.createNode(&.{});
                self.root = new_root;

                try self.cloneNode(target_node);
                try new_root.attach(target_node);
                try new_root.attach(sibling_node);

                new_root.summarize();
            } else {
                // Non-root split case: insert sibling to parent, summarize parent, and propagate split
                const parent = target_node.parent.?;
                sibling_node.parent = parent;

                const idx = std.mem.indexOfScalar(*TreeNode, parent.children.items, target_node).?;
                try self.cloneNode(parent);
                try parent.children.insert(self.allocator, idx + 1, sibling_node);

                parent.summarize();

                try self.splitInternalNode(parent);
            }
        }

        fn destroyNode(self: *Self, node: *TreeNode) void {
            // Retain dangling nodes for history purposes
            if (self.enable_history) {
                return;
            }

            for (node.children.items) |child| {
                self.destroyNode(child);
            }
            if (std.mem.indexOfScalar(*TreeNode, self.nodes.items, node)) |idx| {
                _ = self.nodes.orderedRemove(idx);
            }
            node.deinit();
            self.allocator.destroy(node);
        }

        fn cloneNode(self: *Self, target_node: *TreeNode) !void {
            if (!self.enable_history) {
                return;
            }

            const clone = try TreeNode.Clone.init(self.allocator);
            try self.clones.append(self.allocator, clone);
            clone.id = target_node.id;
            clone.parent_id = target_node.parent_id;
            clone.start = target_node.start;
            clone.summary = target_node.summary;
            for (target_node.children.items) |item| {
                try clone.children.append(self.allocator, item.id);
            }
        }

        fn collapseSingleChildNodes(self: *Self, target_node: *TreeNode) anyerror!void {
            if (target_node.isLeaf()) return;

            // First recurse on children to collapse them from bottom up
            var i: usize = 0;
            while (i < target_node.children.items.len) {
                const child = target_node.children.items[i];
                try self.collapseSingleChildNodes(child);
                i += 1;
            }

            // Now check if target_node itself has only one child
            if (target_node.children.items.len == 1) {
                const child = target_node.children.items[0];
                if (child.isLeaf()) {
                    // Copy child's properties to target_node
                    try self.cloneNode(target_node);
                    target_node.start = child.start;
                    target_node.summary = child.summary;

                    // Clear target_node's children to make it a leaf
                    target_node.children.clearRetainingCapacity();

                    // Destroy child node recursively and remove it from tracking list
                    self.destroyNode(child);
                } else {
                    // Promote child's children to target_node
                    try self.cloneNode(target_node);
                    target_node.children.clearRetainingCapacity();
                    for (child.children.items) |c| {
                        try self.cloneNode(c);
                        try target_node.children.append(self.allocator, c);
                        c.parent = target_node;
                    }
                    try self.cloneNode(child);
                    child.children.clearRetainingCapacity();

                    // Destroy the now-empty child node
                    self.destroyNode(child);
                }
            }
        }

        /// Sibling joining B+ tree balancing algorithm:
        /// Joins/merges adjacent sibling internal nodes if their combined children count falls
        /// below 80% of MAX_NODE_CHILDREN. Also collapses the root if it is left with only 1 child.
        fn joinInternalNodes(self: *Self, target_node: *TreeNode) !void {
            if (target_node.isLeaf()) return;
            if (target_node == self.root) {
                // Root collapse case: copy child's children directly to the root, keeping root pointer fixed
                if (self.root.children.items.len == 1) {
                    const child = self.root.children.items[0];
                    if (!child.isLeaf()) {
                        try self.cloneNode(self.root);
                        self.root.children.clearRetainingCapacity();
                        for (child.children.items) |c| {
                            try self.cloneNode(c);
                            try self.root.children.append(self.allocator, c);
                            c.parent = self.root;
                        }
                        try self.cloneNode(child);
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
                    try self.cloneNode(left_sibling);
                    for (target_node.children.items) |child| {
                        try self.cloneNode(child);
                        try left_sibling.children.append(self.allocator, child);
                        child.parent = left_sibling;
                    }
                    try self.cloneNode(target_node);
                    target_node.children.clearRetainingCapacity();

                    try self.cloneNode(parent);
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
                    try self.cloneNode(target_node);
                    for (right_sibling.children.items) |child| {
                        try self.cloneNode(child);
                        try target_node.children.append(self.allocator, child);
                        child.parent = target_node;
                    }
                    try self.cloneNode(right_sibling);
                    right_sibling.children.clearRetainingCapacity();

                    try self.cloneNode(parent);
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
                prefix_node.summary = self.summarize(self.chunks.items[prefix_node.start..(prefix_node.start + offset)]);

                const suffix_node = try self.createNode(&.{});
                suffix_node.start = target_node.start + offset;
                suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start..(suffix_node.start + L - offset)]);

                try self.cloneNode(self.root);
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
                suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start..(suffix_node.start + L - offset)]);
                suffix_node.parent = parent_node;

                try self.cloneNode(target_node);
                target_node.summary = self.summarize(self.chunks.items[target_node.start..(target_node.start + offset)]);

                try self.cloneNode(parent_node);
                try parent_node.children.insert(self.allocator, idx + 1, suffix_node);

                var curr_parent = target_node.parent;
                while (curr_parent) |p| {
                    try self.cloneNode(p);
                    p.summarize();
                    curr_parent = p.parent;
                }

                try self.splitInternalNode(parent_node);

                return suffix_node;
            }
        }

        fn updateTimestamp(self: *Self) void {
            var ts: std.posix.timespec = undefined;
            switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
                .SUCCESS => {
                    self.timestamp = @intCast(ts.sec);
                },
                else => {},
            }
        }

        /// B+ tree insertion algorithm:
        /// Seeks cursor location, splits target leaf node if cursor is positioned in the middle,
        /// inserts the new chunk as a sibling node, and propagates splits and summarizations up to the root.
        pub fn insert(self: *Self, chunk: []const ValueT, cursor_: TreeCursor) !TreeCursor {
            if (chunk.len == 0) {
                var cursor = cursor_;
                cursor.absolute = cursor.resolveAbsolute();
                return cursor;
            }

            self.updateTimestamp();

            if (chunk.len > Config.MAX_CHUNK_LENGTH) {
                var cur = cursor_;
                var start_idx: usize = 0;
                while (start_idx < chunk.len) {
                    const end_idx = @min(chunk.len, start_idx + Config.MAX_CHUNK_LENGTH);
                    const sub_chunk = chunk[start_idx..end_idx];
                    cur = try self.insert(sub_chunk, cur);
                    start_idx = end_idx;
                }
                return cur;
            }
            var cursor = cursor_;
            cursor.absolute = cursor.resolveAbsolute();

            const target_cursor = cursor.seekRight(0, 0);
            const target_node = target_cursor.node;
            const offset = target_cursor.offset;
            const L = target_node.summary.dimensions[0];

            // Check if we can simply append to the target node
            if (offset == L and target_node.start + L == self.chunks.items.len) {
                try self.chunks.appendSlice(self.allocator, chunk);
                try self.cloneNode(target_node);
                target_node.summary = self.summarize(self.chunks.items[target_node.start .. target_node.start + L + chunk.len]);

                var c = cursor;
                c.node = target_node;
                c.offset = target_node.summary.dimensions[0];
                c.absolute = c.resolveAbsolute();

                // Bubble up summarization updates
                var curr_parent = target_node.parent;
                while (curr_parent) |p| {
                    try self.cloneNode(p);
                    p.summarize();
                    curr_parent = p.parent;
                }
                return c;
            }

            const n = try self.createNode(chunk);

            if (target_node == self.root) {
                // If found node is root, split/insert directly as child
                try self.cloneNode(self.root);
                if (offset > 0 and offset < L) {
                    const prefix_node = try self.createNode(&.{});
                    prefix_node.start = target_node.start;
                    prefix_node.summary = self.summarize(self.chunks.items[prefix_node.start..(prefix_node.start + offset)]);

                    const suffix_node = try self.createNode(&.{});
                    suffix_node.start = target_node.start + offset;
                    suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start..(suffix_node.start + L - offset)]);

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
                    suffix_node.summary = self.summarize(self.chunks.items[suffix_node.start..(suffix_node.start + L - offset)]);
                    suffix_node.parent = parent_node;

                    try self.cloneNode(target_node);
                    target_node.summary = self.summarize(self.chunks.items[target_node.start..(target_node.start + offset)]);

                    try self.cloneNode(parent_node);
                    try parent_node.children.insert(self.allocator, idx + 1, n);
                    n.parent = parent_node;
                    try parent_node.children.insert(self.allocator, idx + 2, suffix_node);
                } else if (offset == 0) {
                    try self.cloneNode(parent_node);
                    try parent_node.children.insert(self.allocator, idx, n);
                    n.parent = parent_node;
                } else {
                    try self.cloneNode(parent_node);
                    try parent_node.children.insert(self.allocator, idx + 1, n);
                    n.parent = parent_node;
                }
                try self.splitInternalNode(parent_node);
            }

            try self.chunks.appendSlice(self.allocator, chunk);

            var c = cursor;
            c.node = n;
            c.offset = n.summary.dimensions[0];
            c.absolute = c.resolveAbsolute();

            // Bubble up summarization updates
            var curr_parent = n.parent;
            while (curr_parent) |p| {
                try self.cloneNode(p);
                p.summarize();
                curr_parent = p.parent;
            }

            return c;
        }

        /// B+ tree range deletion (erase) algorithm:
        /// Seeks cursor, splits first node if offset is in the middle, and loops forward
        /// zeroing out fully deleted leaves (dimensions[0] = 0) or truncating the start of partially deleted leaves.
        /// Balances and prunes/joins the tree structure on completion.
        pub fn erase(self: *Self, cursor_: TreeCursor, length: usize) !TreeCursor {
            self.updateTimestamp();

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
            if (curr_offset == L) {
                if (TreeCursor.nextLeaf(curr_node)) |next_node| {
                    curr_node = next_node;
                    curr_offset = 0;
                } else {
                    return cursor;
                }
            } else if (curr_offset > 0 and curr_offset < L) {
                curr_node = try self.splitLeafNode(curr_node, curr_offset);
                curr_offset = 0;
            }

            // Loop across nodes to erase the range
            while (remaining > 0) {
                const node_size = curr_node.summary.dimensions[0];
                if (remaining >= node_size) {
                    // Full erase: zero out summary, record affected parent, bubble up summary updates
                    try self.cloneNode(curr_node);
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
                        try self.cloneNode(p);
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
                    try self.cloneNode(curr_node);
                    curr_node.start += remaining;
                    curr_node.summary = self.summarize(self.chunks.items[curr_node.start..(curr_node.start + node_size - remaining)]);

                    var curr_parent = curr_node.parent;
                    while (curr_parent) |p| {
                        try self.cloneNode(p);
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

            // Prune zero-length nodes recursively from the root down
            try self.root.prune(self);

            // Join sibling nodes recursively
            for (affected_parents.items) |parent| {
                if (std.mem.indexOfScalar(*TreeNode, self.nodes.items, parent) != null) {
                    try self.joinInternalNodes(parent);
                }
            }

            // Collapse redundant single-child internal nodes recursively
            try self.collapseSingleChildNodes(self.root);

            var is_detached = true;
            if (std.mem.indexOfScalar(*TreeNode, self.nodes.items, curr_node) != null) {
                is_detached = false;
                if (curr_node.parent) |p| {
                    if (std.mem.indexOfScalar(*TreeNode, p.children.items, curr_node) == null) {
                        is_detached = true;
                    }
                } else if (curr_node != self.root) {
                    is_detached = true;
                }
            }
            if (is_detached) {
                c.recalculate();
            }
            return c;
        }

        pub fn dump(self: Self, node: *TreeNode, depth: usize) void {
            for (0..depth) |_| std.debug.print("  ", .{});
            // std.debug.print("?{*} -> {*}\n", .{ node, node.parent });
            std.debug.print("node {}: ", .{node.id});

            if (node.isLeaf()) {
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

        pub fn visualize(self: Self, node: *TreeNode) void {
            var active_paths = [_]bool{false} ** 64;
            self.visualizeHelper(node, 0, &active_paths, true);
        }

        fn visualizeHelper(self: Self, node: *TreeNode, depth: usize, active_paths: *[64]bool, is_last: bool) void {
            if (depth > 0) {
                for (0..depth - 1) |i| {
                    if (active_paths[i]) {
                        std.debug.print("│   ", .{});
                    } else {
                        std.debug.print("    ", .{});
                    }
                }
                if (is_last) {
                    std.debug.print("└── ", .{});
                } else {
                    std.debug.print("├── ", .{});
                }
            }

            std.debug.print("node {}: ", .{node.id});

            if (node.isLeaf()) {
                const len = node.summary.dimensions[0];
                if (len > 0) {
                    const slice = self.chunks.items[node.start..(node.start + len)];
                    if (slice.len > 10) {
                        std.debug.print("\"{s}...{s}\"\n", .{ slice[0..3], slice[slice.len - 3 ..] });
                    } else {
                        std.debug.print("\"{s}\"\n", .{slice});
                    }
                } else {
                    std.debug.print("\"\"\n", .{});
                }
            } else {
                std.debug.print("\n", .{});
            }

            if (depth < 64) {
                active_paths[depth] = !is_last;
            }

            const children_count = node.children.items.len;
            for (node.children.items, 0..) |child, idx| {
                const child_is_last = (idx == children_count - 1);
                self.visualizeHelper(child, depth + 1, active_paths, child_is_last);
            }
        }

        pub fn visualizeWrite(self: Self, node: *TreeNode, writer: anytype) anyerror!void {
            var active_paths = [_]bool{false} ** 64;
            try self.visualizeHelperWrite(node, 0, &active_paths, true, writer);
        }

        fn visualizeHelperWrite(self: Self, node: *TreeNode, depth: usize, active_paths: *[64]bool, is_last: bool, writer: anytype) anyerror!void {
            if (depth > 0) {
                for (0..depth - 1) |i| {
                    if (active_paths[i]) {
                        try writer.print("│   ", .{});
                    } else {
                        try writer.print("    ", .{});
                    }
                }
                if (is_last) {
                    try writer.print("└── ", .{});
                } else {
                    try writer.print("├── ", .{});
                }
            }

            try writer.print("node {}: ", .{node.id});

            if (node.isLeaf()) {
                const len = node.summary.dimensions[0];
                if (len > 0) {
                    const slice = self.chunks.items[node.start..(node.start + len)];
                    if (slice.len > 10) {
                        try writer.print("\"{s}...{s}\"\n", .{ slice[0..3], slice[slice.len - 3 ..] });
                    } else {
                        try writer.print("\"{s}\"\n", .{slice});
                    }
                } else {
                    try writer.print("\"\"\n", .{});
                }
            } else {
                try writer.print("\n", .{});
            }

            if (depth < 64) {
                active_paths[depth] = !is_last;
            }

            const children_count = node.children.items.len;
            for (node.children.items, 0..) |child, idx| {
                const child_is_last = (idx == children_count - 1);
                try self.visualizeHelperWrite(child, depth + 1, active_paths, child_is_last, writer);
            }
        }
    };
}
