const std = @import("std");
const Rope = @import("Rope.zig").Rope;
const Allocator = std.mem.Allocator;

pub const Document = struct {
    allocator: Allocator,
    rope: *Rope,
    filename: ?[]const u8,

    pub fn init(allocator: Allocator, content: []const u8, filename: ?[]const u8) !*Document {
        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        const rope = try Rope.init(allocator);
        errdefer rope.deinit();

        try rope.insert(0, content);
        rope.setEnableHistory(true);

        doc.* = .{
            .allocator = allocator,
            .rope = rope,
            .filename = if (filename) |f| try allocator.dupe(u8, f) else null,
        };
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.rope.deinit();
        if (self.filename) |f| {
            self.allocator.free(f);
        }
        self.allocator.destroy(self);
    }
};
