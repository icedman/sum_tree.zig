const std = @import("std");
const Io = std.Io;

const sum_tree = @import("sum_tree");
const st = sum_tree.SumTree;
const SumTree = st.SumTree;
const Dimensions = st.Dimensions;

fn randomWord(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, 10);
    for (0..len) |i| {
        buf[i] = rand.intRangeAtMost(u8, 'a', 'z');
    }
    return buf[0..len];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const allocator = std.heap.page_allocator;
    const S = SumTree(u8);
    const tree = try S.init(allocator);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    // 1. Insertion Phase: 2000 random words
    var word_buf: [16]u8 = undefined;
    for (0..2000) |_| {
        const word = randomWord(rand, &word_buf);
        const total_len = tree.root.summary.dimensions[0];
        const pos = if (total_len == 0) 0 else rand.intRangeAtMost(usize, 0, total_len);

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.insert(word, cur);
    }

    // 2. Deletion Phase: 2000 random erasures
    for (0..1000) |_| {
        const total_len = tree.root.summary.dimensions[0];
        if (total_len == 0) break;

        const pos = rand.intRangeLessThan(usize, 0, total_len);
        const len = rand.intRangeAtMost(usize, 1, @min(10, total_len - pos));

        const cur = tree.createCursor().seekRight(pos, 0);
        _ = try tree.erase(cur, len);
    }

    // Open output.txt and visualize the tree to it
    const cwd = Io.Dir.cwd();
    const file = try cwd.createFile(io, "output.txt", .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &file_buffer);
    const writer = &file_writer.interface;

    try tree.visualizeWrite(tree.root, writer);
    try writer.flush();

    std.debug.print("Successfully ran 2000 words test and visualized to output.txt\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

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
