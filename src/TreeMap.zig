const std = @import("std");
const Allocator = std.mem.Allocator;
const sum_tree = @import("SumTree.zig");
const SumTree = sum_tree.SumTree;
const Bias = sum_tree.Bias;

pub fn compareKeys(comptime K: type, a: K, b: K) std.math.Order {
    switch (@typeInfo(K)) {
        .int, .float => {
            return std.math.order(a, b);
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                return std.mem.order(u8, a, b);
            }
            @compileError("TreeMap only supports default comparison for numbers and u8 slices. Please provide a custom comparator.");
        },
        else => {
            if (@hasDecl(K, "compare")) {
                return K.compare(a, b);
            }
            @compileError("TreeMap type " ++ @typeName(K) ++ " must declare a compare method or be a number/u8 slice.");
        },
    }
}

pub fn MapEntry(comptime K: type, comptime V: type) type {
    return struct {
        const MEntry = @This();
        key: K,
        value: V,

        pub const Summary = struct {
            pub const Context = void;
            max_key: ?K = null,

            pub fn zero(cx: Context) @This() {
                _ = cx;
                return .{};
            }

            pub fn add(self: *@This(), other: @This(), cx: Context) void {
                _ = cx;
                if (other.max_key) |k| {
                    self.max_key = k;
                }
            }
        };

        pub fn summary(self: MEntry, cx: Summary.Context) Summary {
            _ = cx;
            return .{ .max_key = self.key };
        }
    };
}

pub fn MapKeyDimension(comptime K: type) type {
    return struct {
        const Self = @This();
        max_key: ?K = null,

        pub fn zero(cx: void) Self {
            _ = cx;
            return .{};
        }

        pub fn addSummary(self: *Self, s: anytype, cx: void) void {
            _ = cx;
            if (s.max_key) |k| {
                self.max_key = k;
            }
        }
    };
}

pub fn MapSeekTarget(comptime K: type) type {
    return struct {
        const Self = @This();
        target: K,

        pub fn cmp(self: Self, pos: MapKeyDimension(K), cx: void) std.math.Order {
            _ = cx;
            if (pos.max_key) |key| {
                return compareKeys(K, self.target, key);
            }
            return .gt;
        }
    };
}

pub fn TreeMap(comptime K: type, comptime V: type) type {
    const Entry = MapEntry(K, V);
    const S = SumTree(Entry);
    const KeyDim = MapKeyDimension(K);
    const SeekTarget = MapSeekTarget(K);

    return struct {
        const Self = @This();

        tree: *S,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !*Self {
            const map = try allocator.create(Self);
            map.tree = try S.init(allocator, {});
            map.allocator = allocator;
            return map;
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
            self.allocator.destroy(self);
        }

        pub fn clone(self: *Self) !*Self {
            const copy = try self.allocator.create(Self);
            copy.tree = try self.tree.clone();
            copy.allocator = self.allocator;
            return copy;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.tree.isEmpty();
        }

        pub fn containsKey(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn get(self: *const Self, key: K) ?V {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const target = SeekTarget{ .target = key };
            cursor.seekTo(target, .left);
            if (cursor.item()) |entry| {
                if (compareKeys(K, entry.key, key) == .eq) {
                    return entry.value;
                }
            }
            return null;
        }

        pub fn insert(self: *Self, key: K, value: V) !void {
            _ = try self.insertOrReplace(key, value);
        }

        pub fn insertOrReplace(self: *Self, key: K, value: V) !?V {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const target = SeekTarget{ .target = key };
            const left_slice = try cursor.slice(target, .left);
            errdefer left_slice.deinit();

            var replaced_val: ?V = null;
            if (cursor.item()) |entry| {
                if (compareKeys(K, entry.key, key) == .eq) {
                    replaced_val = entry.value;
                    cursor.next();
                }
            }

            try left_slice.push(Entry{ .key = key, .value = value });

            const suffix_slice = try cursor.suffix();
            defer suffix_slice.deinit();

            try left_slice.append(suffix_slice);

            const old_root = self.tree.root;
            self.tree.root = left_slice.root.ref();
            old_root.deref(self.allocator);
            left_slice.deinit();

            return replaced_val;
        }

        pub fn remove(self: *Self, key: K) !?V {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const target = SeekTarget{ .target = key };
            const left_slice = try cursor.slice(target, .left);
            errdefer left_slice.deinit();

            var removed_val: ?V = null;
            if (cursor.item()) |entry| {
                if (compareKeys(K, entry.key, key) == .eq) {
                    removed_val = entry.value;
                    cursor.next();
                }
            }

            if (removed_val == null) {
                left_slice.deinit();
                return null;
            }

            const suffix_slice = try cursor.suffix();
            defer suffix_slice.deinit();

            try left_slice.append(suffix_slice);

            const old_root = self.tree.root;
            self.tree.root = left_slice.root.ref();
            old_root.deref(self.allocator);
            left_slice.deinit();

            return removed_val;
        }

        pub fn removeRange(self: *Self, start: K, end: K) !void {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const start_target = SeekTarget{ .target = start };
            const left_slice = try cursor.slice(start_target, .left);
            errdefer left_slice.deinit();

            const end_target = SeekTarget{ .target = end };
            cursor.seekTo(end_target, .left);

            const suffix_slice = try cursor.suffix();
            defer suffix_slice.deinit();

            try left_slice.append(suffix_slice);

            const old_root = self.tree.root;
            self.tree.root = left_slice.root.ref();
            old_root.deref(self.allocator);
            left_slice.deinit();
        }

        pub fn closest(self: *const Self, key: K) ?Entry {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const target = SeekTarget{ .target = key };
            cursor.seekTo(target, .right);
            // Move cursor back to get <= key
            cursor.prev();
            return cursor.item();
        }

        pub fn first(self: *const Self) ?Entry {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            return cursor.item();
        }

        pub fn last(self: *const Self) ?Entry {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            if (self.isEmpty()) return null;
            cursor.descendToRightmostLeaf();
            return cursor.item();
        }

        pub const Iterator = struct {
            cursor: S.Cursor(KeyDim),

            pub fn next(self: *Iterator) ?Entry {
                const item = self.cursor.item() orelse return null;
                self.cursor.next();
                return item;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .cursor = S.Cursor(KeyDim).init(self.tree),
            };
        }

        pub fn iterFrom(self: *const Self, key: K) Iterator {
            var cursor = S.Cursor(KeyDim).init(self.tree);
            const target = SeekTarget{ .target = key };
            cursor.seekTo(target, .left);
            return .{
                .cursor = cursor,
            };
        }
    };
}

pub fn TreeSet(comptime K: type) type {
    return struct {
        const Self = @This();
        map: *TreeMap(K, void),
        allocator: Allocator,

        pub fn init(allocator: Allocator) !*Self {
            const set = try allocator.create(Self);
            set.map = try TreeMap(K, void).init(allocator);
            set.allocator = allocator;
            return set;
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.allocator.destroy(self);
        }

        pub fn clone(self: *Self) !*Self {
            const copy = try self.allocator.create(Self);
            copy.map = try self.map.clone();
            copy.allocator = self.allocator;
            return copy;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.map.isEmpty();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.containsKey(key);
        }

        pub fn insert(self: *Self, key: K) !void {
            try self.map.insert(key, {});
        }

        pub fn remove(self: *Self, key: K) !bool {
            return (try self.map.remove(key)) != null;
        }

        pub const Iterator = struct {
            map_iter: TreeMap(K, void).Iterator,

            pub fn next(self: *Iterator) ?K {
                const entry = self.map_iter.next() orelse return null;
                return entry.key;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .map_iter = self.map.iterator(),
            };
        }

        pub fn iterFrom(self: *const Self, key: K) Iterator {
            return .{
                .map_iter = self.map.iterFrom(key),
            };
        }
    };
}
