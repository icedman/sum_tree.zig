const std = @import("std");
const Io = std.Io;

const sum_tree = @import("sum_tree");
const Rope = sum_tree.Rope;
const Point = sum_tree.Point;

fn randomWord(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, 10);
    for (0..len) |i| {
        buf[i] = rand.intRangeAtMost(u8, 'a', 'z');
    }
    return buf[0..len];
}

fn visualizeHelper(node: anytype, depth: usize, active_paths: *[64]bool, is_last: bool, writer: anytype) anyerror!void {
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

    try writer.print("node (rc={}, height={}): ", .{ node.rc, node.height });

    if (node.isLeaf()) {
        try writer.print("leaf (count={}, char_len={})\n", .{ node.children.leaf.len, node.summary.char_len });
        for (node.children.leaf.slice()) |chunk| {
            for (0..depth) |_| {
                try writer.print("    ", .{});
            }
            const text = chunk.text.slice();
            if (text.len > 15) {
                try writer.print("  - \"{s}...{s}\" (len={})\n", .{ text[0..5], text[text.len - 5 ..], text.len });
            } else {
                try writer.print("  - \"{s}\" (len={})\n", .{ text, text.len });
            }
        }
    } else {
        try writer.print("(total_len={})\n", .{node.summary.char_len});
    }

    if (depth < 64) {
        active_paths[depth] = !is_last;
    }

    if (!node.isLeaf()) {
        const children_count = node.children.internal.len;
        for (node.children.internal.slice(), 0..) |child, idx| {
            const child_is_last = (idx == children_count - 1);
            try visualizeHelper(child, depth + 1, active_paths, child_is_last, writer);
        }
    }
}

pub fn visualizeWrite(rope: *Rope, writer: anytype) anyerror!void {
    var active_paths = [_]bool{false} ** 64;
    try visualizeHelper(rope.tree.root, 0, &active_paths, true, writer);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const allocator = std.heap.page_allocator;
    const rope = try Rope.init(allocator);
    defer rope.deinit();

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    // 1. Insertion Phase: 2000 random words
    var word_buf: [16]u8 = undefined;
    for (0..2000) |_| {
        const word = randomWord(rand, &word_buf);
        const total_len = rope.tree.root.summary.char_len;
        const pos = if (total_len == 0) 0 else rand.intRangeAtMost(usize, 0, total_len);

        try rope.replace(pos, 0, word);
    }
    std.debug.print("Length after insertion: {}\n", .{rope.tree.root.summary.char_len});

    // 2. Deletion Phase: 1000 random erasures
    for (0..1000) |_| {
        const total_len = rope.tree.root.summary.char_len;
        if (total_len == 0) break;

        const pos = rand.intRangeLessThan(usize, 0, total_len);
        const len = rand.intRangeAtMost(usize, 1, @min(10, total_len - pos));

        try rope.replace(pos, len, "");
    }

    // Open output.txt and visualize the tree to it
    const cwd = Io.Dir.cwd();
    const file = try cwd.createFile(io, "output.txt", .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &file_buffer);
    const writer = &file_writer.interface;

    try visualizeWrite(rope, writer);
    try writer.flush();

    std.debug.print("Successfully ran 2000 words test and visualized to output.txt\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
