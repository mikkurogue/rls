//! Store global server
//! Main event loop

const Server = @This();

const std = @import("std");
const types = @import("lsp.zig");
// Public fields:

allocator: std.mem.Allocator,
// TODO: make config struct
status: Status = .uninitialized,

/// Document URI's for doc src
var documents: std.StringHashMapUnmanaged([]const u8) = .{};

pub const LSPError = error{
    OutOfMemory,
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    /// Error code indicating that a server received a notification or
    /// request before the server has received the `initialize` request.
    ServerNotInitialized,
    /// A request failed but it was syntactically correct, e.g the
    /// method name was known and the parameters were valid. The error
    /// message should contain human readable information about why
    /// the request failed.
    ///
    /// @since 3.17.0
    RequestFailed,
    /// The server cancelled the request. This error code should
    /// only be used for requests that explicitly support being
    /// server cancellable.
    ///
    /// @since 3.17.0
    ServerCancelled,
    /// The server detected that the content of a document got
    /// modified outside normal conditions. A server should
    /// NOT send this error code if it detects a content change
    /// in it unprocessed messages. The result even computed
    /// on an older state might still be useful for the client.
    ///
    /// If a client decides that a result is not of any use anymore
    /// the client should cancel the request.
    ContentModified,
    /// The client has canceled a request and a server as detected
    /// the cancel.
    RequestCancelled,
};
/// The possible statuses of the LSP
pub const Status = enum {
    /// LSP has not received initialize request
    uninitialized,
    /// LSP awaiting `initialized` notification
    initializing,
    /// LSP initialized and waiting requests
    initialized,
    /// LSP has been shutdown
    shutdown,
    /// LSP received exit notification and is shutdown
    exit_success,
    /// LSP received exit notificatoin but is not shutdown
    exit_failure,
};

fn send_to_client_response(server: *Server, id: types.RequestId, result: anytype) LSPError![]u8 {
    //TODO:
    //validate result type is possible response
    //validate response is from client to server
    //validate result type

    return try server.send_to_client_internal(id, null, null, "result", result);
}

fn send_to_client_request(server: *Server, id: types.RequestId, method: []const u8, params: anytype) LSPError![]u8 {
    // TODO: std.debug.assert(isRequestMethod(method));
    // TODO:
    // validate method is server to client
    // validate params type

    return try server.send_to_client_internal(id, method, null, "params", params);
}

fn send_to_client_notification(server: *Server, id: types.RequestId, method: []const u8, params: anytype) LSPError![]u8 {
    // TODO: std.debug.assert(isNotificationMethod(method));

    // TODO:
    // validate method is server to client
    // validate params type

    return try server.send_to_client_internal(id, method, null, "params", params);
}

fn send_to_client_response_error(server: *Server, id: types.RequestId, err: ?types.ResponseError) LSPError![]u8 {
    return try server.send_to_client_internal(id, null, err, "", null);
}

fn send_to_client_internal(
    server: *Server,
    maybe_id: ?types.RequestId,
    maybe_method: ?[]const u8,
    maybe_err: ?types.ResponseError,
    extra_name: []const u8,
    extra: anytype,
) LSPError![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};

    errdefer buffer.deinit(server.allocator);

    var writer = buffer.writer(server.allocator);
    try writer.writeAll(
        \\{"jsonrpc:":"2.0"
    );
    if (maybe_id) |id| {
        try writer.writeAll(
            \\, "id":
        );
        try std.json.stringify(id, .{}, writer);
    }
    if (maybe_method) |method| {
        try writer.writeAll(
            \\,"method":
        );
        try std.json.stringify(method, .{}, writer);
    }

    switch (@TypeOf(extra)) {
        void => {},
        ?void => {
            try writer.print(
                \\ "{s}":null
            , .{extra_name});
        },
        else => {
            try writer.print(
                \\,"{s}":null
            , .{extra_name});
            // NOTE: for the lsp rpc we must also have null/optional fields passed
            try std.json.stringify(extra, .{ .emit_null_optional_fields = false }, writer);
        },
    }

    if (maybe_err) |err| {
        try writer.writeAll(
            \\,"error":
        );
        try std.json.stringify(err, .{}, writer);
    }

    try writer.writeByte('}');

    server.transport.write_json_message(buffer.items) catch |err| {
        std.log.err("failed to write response: {}", .{err});
    };
    return buffer.toOwnedSlice(server.allocator);
}

fn show_message(
    server: *Server,
    message_type: types.MessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(server.allocator, fmt, args) catch return;
    defer server.allocator.free(message);

    switch (message_type) {
        .Error => std.log.err("{s}", message),
        .Warning => std.log.warn("{s}", message),
        .Info => std.log.info("{s}", message),
        .Log => std.log.debug("{s}", message),
    }

    switch (server.status) {
        .initializing, .initialized => {},
        .uninitialized, .shutdown, .exit_success, .exit_failure => return,
    }

    if (server.send_to_client_notification("window/showMessage", types.ShowMessageParams{ .type = message_type, .message = message })) |json_message| {
        server.allocator.free(json_message);
    } else |err| {
        std.log.warn("failed to show message: {}", .{err});
    }
}

fn initialize_handler(server: *Server, request: types.InitializeParams) !types.InitializeResult {
    if (request.clientInfo) |info| {
        std.log.info("client is '{s} - {s}'", .{ info.name, info.version orelse "<unknown>" });
    }

    const capabilities = try std.json.stringifyAlloc(server.allocator, request.capabilities, .{});
    defer server.allocator.free(capabilities);

    server.client_capabilities.deinit();
    server.client_capabilities = std.json.parseFromSlice(
        types.ClientCapabilities,
        server.allocator,
        capabilities,
        .{ .allocate = .alloc_always },
    ) catch return error.InternalError;

    server.status = .initializing;

    return Server{
        .serverInfo = .{
            .name = "rls",
            .version = "0.0.1",
        },
        .capabilities = .{
            .positionEncoding = switch (server.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-" => .@"utf-32",
            },
            .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Full,
                .save = .{ .bool = true },
            } },
            .completionProvider = .{
                .triggerCharacters = &[_][]const u8{ ".", ":", "@", "]", "/" },
            },
            .hoverProvider = .{ .bool = true },
            .definitionProvider = .{ .bool = true },
            .referencesProvider = .{ .bool = true },
            .documentFormattingProvider = .{ .bool = true }, // check if this is needed
            .semanticTokensProvider = .{
                .SemanticTokensOptions = .{
                    .full = .{ .bool = true },
                    .legend = .{
                        .tokenTypes = std.meta.fieldNames(types.SemanticTokenTypes),
                        .tokenModifiers = std.meta.fieldNames(types.SemanticTokenModifiers),
                    },
                },
            },
            .inlayHintProvider = .{
                .bool = true,
            },
        },
    };
}

// https://github.com/Techatrix/zig-lsp-sample/blob/192ef5d54507c14f10287ab186ee8c304a5f8b19/src/Server.zig#L243
// Continue from here tomorrow
