const std = @import("std");

pub const MessageType = enum { request, response, notification };

const Message = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?i64 = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    err: ?std.json.Value = null,

    // TODO: add message parsing
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) Server {
        return Server{
            .allocator = allocator,
        };
    }

    /// Send a request to the client
    pub fn send_request() !void {}

    /// Send a response to the client
    pub fn send_response() !void {}

    /// send a notification to the client
    pub fn send_notification() !void {}

    /// send error to client like lsp timeout etc
    pub fn send_error() !void {}
};
