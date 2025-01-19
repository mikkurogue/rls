const std = @import("std");
const Header = @import("Header.zig").Header;
const BufferedReader = std.io.BufferedReader;
const fs = std.fs;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Transport = struct {
    in: BufferedReader(4096, fs.File.Reader),
    out: fs.File.Writer,
    in_lock: Thread.Mutex = .{},
    out_lock: Thread.Mutex = .{},
    message_tracing: bool = false,

    const msg_logger = std.log.scoped(.message);

    pub fn init(in: fs.File.Reader, out: fs.File.Writer) Transport {
        return Transport{
            .in = std.io.bufferedReader(in),
            .out = out,
        };
    }

    pub fn read_json_message(self: *Transport, allocator: Allocator) ![]u8 {
        const json_message = jsonBlock: {
            self.in_lock.lock();
            defer self.in_lock.unlock();

            const reader = self.in.reader();
            const header = try Header.parse(allocator, reader);
            defer header.deinit(allocator);

            const json_message = try allocator.alloc(u8, header.content_length);
            errdefer allocator.free(json_message);
            try reader.readNoEof(json_message);
            break :jsonBlock json_message;
        };

        if (self.message_tracing) msg_logger.debug("received: {s}", .{json_message});

        return json_message;
    }

    pub fn write_json_message(self: *Transport, json_message: []const u8) !void {
        var buf: [64]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "Content-Length: {d}\r\n\r\n", .{json_message.len}) catch unreachable;
        {
            self.out_lock.lock();
            defer self.out_lock.unlock();

            try self.out.writeAll(prefix);
            try self.out.writeAll(json_message);
        }
        if (self.message_tracing) msg_logger.debug("sent: {s}", .{json_message});
    }
};
