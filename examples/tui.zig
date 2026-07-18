const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

pub const Key = union(enum) {
    char: struct {
        buf: [8]u8,
        len: u8,
    },
    escape,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    delete,
    backspace,
    enter,
    ctrl_c,
    ctrl_d,
    ctrl_q,
    ctrl_s,
    ctrl_z,
    ctrl_y,
    ctrl_r,
    other,
};

pub const Tui = struct {
    io: Io,
    allocator: Allocator,
    original_termios: std.posix.termios,
    stdin_file: File,
    stdin_buffer: [4096]u8,
    stdin_reader: File.Reader,
    stdout_file: File,
    stdout_buffer: [4096]u8,
    stdout_writer: File.Writer,
    writer: *Io.Writer,

    pub fn init(io: Io, allocator: Allocator) !*Tui {
        const stdin_file = File.stdin();
        const stdout_file = File.stdout();

        const fd = std.posix.STDIN_FILENO;
        const original_termios = try std.posix.tcgetattr(fd);
        var raw = original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);

        const self = try allocator.create(Tui);
        errdefer allocator.destroy(self);

        self.* = Tui{
            .io = io,
            .allocator = allocator,
            .original_termios = original_termios,
            .stdin_file = stdin_file,
            .stdin_buffer = undefined,
            .stdin_reader = undefined,
            .stdout_file = stdout_file,
            .stdout_buffer = undefined,
            .stdout_writer = undefined,
            .writer = undefined,
        };

        self.stdin_reader = stdin_file.reader(io, &self.stdin_buffer);
        self.stdout_writer = stdout_file.writer(io, &self.stdout_buffer);
        self.writer = &self.stdout_writer.interface;

        return self;
    }

    pub fn deinit(self: *Tui) void {
        const fd = std.posix.STDIN_FILENO;
        std.posix.tcsetattr(fd, .FLUSH, self.original_termios) catch {};
        self.allocator.destroy(self);
    }

    pub fn getScreenSize(self: *Tui) !struct { width: usize, height: usize } {
        _ = self;
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.row == 0 or ws.col == 0) {
            return .{ .width = 80, .height = 24 };
        }
        return .{ .width = ws.col, .height = ws.row };
    }

    pub fn readKey(self: *Tui) !?Key {
        var buf: [8]u8 = undefined;
        var data_slice = [1][]u8{ &buf };
        const bytes_read = self.stdin_reader.interface.readVec(&data_slice) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        if (bytes_read == 0) return null;
        const seq = buf[0..bytes_read];

        if (seq[0] == 27) {
            if (seq.len > 1 and seq[1] == '[') {
                return switch (seq[2]) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    '1' => if (seq.len > 3 and seq[3] == '~') .home else .other,
                    '3' => if (seq.len > 3 and seq[3] == '~') .delete else .other,
                    '4' => if (seq.len > 3 and seq[3] == '~') .end else .other,
                    '5' => if (seq.len > 3 and seq[3] == '~') .page_up else .other,
                    '6' => if (seq.len > 3 and seq[3] == '~') .page_down else .other,
                    else => .other,
                };
            }
            return .escape;
        } else if (seq[0] < 32) {
            return switch (seq[0]) {
                3 => .ctrl_c,
                4 => .ctrl_d,
                17 => .ctrl_q,
                18 => .ctrl_r,
                19 => .ctrl_s,
                26 => .ctrl_z,
                25 => .ctrl_y,
                13, 10 => .enter,
                8, 127 => .backspace,
                else => .other,
            };
        } else {
            if (seq[0] == 127 or seq[0] == 8) {
                return .backspace;
            }
            var char_key = Key{ .char = .{ .buf = undefined, .len = @intCast(seq.len) } };
            @memcpy(char_key.char.buf[0..seq.len], seq);
            return char_key;
        }
    }

    pub fn clear(self: *Tui, render_buf: *std.ArrayList(u8)) !void {
        try render_buf.appendSlice(self.allocator, "\x1b[?25l"); // Hide cursor
        try render_buf.appendSlice(self.allocator, "\x1b[H"); // Move to top-left
    }

    pub fn flush(self: *Tui, render_buf: []const u8) !void {
        try self.writer.writeAll(render_buf);
        try self.writer.flush();
    }

    pub fn positionCursor(self: *Tui, render_buf: *std.ArrayList(u8), row: usize, col: usize) !void {
        try render_buf.print(self.allocator, "\x1b[{};{}H", .{ row, col });
        try render_buf.appendSlice(self.allocator, "\x1b[?25h"); // Show cursor
    }

    pub fn restore(self: *Tui) !void {
        try self.writer.writeAll("\x1b[2J\x1b[H");
        try self.writer.flush();
    }
};
