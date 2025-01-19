const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Header = struct {
    content_length: usize,
    /// null implies "application/vscode-jsonrpc, charset=utf-8"
    /// check how this implies to neovim
    content_type: ?[]const u8 = null,

    pub fn deinit(self: *Header, allocator: Allocator) void {
        if (self.content_type) |ct| {
            allocator.free(ct);
        }
    }

    /// caller owns returned memory
    pub fn parse(allocator: Allocator, reader: anytype) !Header {
        var d = Header{
            .content_type = null,
            .content_length = undefined,
        };

        errdefer d.deinit(allocator);

        var has_content_length = false;
        while (true) {
            const header = try reader.readUntilDelimiterAlloc(allocator, '\n', 0x100);
            defer allocator.free(header);

            if (header.len == 0 or header[header.len - 1] != '\r') {
                return error.MissingCarriageReturn;
            }
            if (header.len == 1) break;

            const header_name = header[0 .. std.mem.indexOf(u8, header, ": ") orelse return error.MissingColor];
            const header_value = header[header_name.len + 2 .. header.len - 1];

            if (std.mem.eql(u8, header_name, "Content-Length")) {
                if (header_value.len == 0) {
                    return error.MissingHeaderValue;
                }

                d.content_length = std.fmt.parseInt(usize, header_value, 10) catch return error.InvalidContentLength;
                has_content_length = true;
            } else if (std.mem.eql(u8, header_name, "Content-Type")) {
                d.content_type = try allocator.dupe(u8, header_value);
            } else {
                return error.UnknownHeader;
            }
        }

        if (!has_content_length) {
            return error.MissingContentLength;
        }

        return d;
    }
};
