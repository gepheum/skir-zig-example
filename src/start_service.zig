const std = @import("std");
const skir = @import("skir_client.zig");
const service_mod = @import("skirout/service.zig");
const user_mod = @import("skirout/user.zig");

const StoredUser = struct {
    arena: std.heap.ArenaAllocator,
    user: user_mod.User,
};

const UserStore = struct {
    mutex: std.Thread.Mutex = .{},
    backing_allocator: std.mem.Allocator,
    map: std.AutoHashMap(i32, StoredUser),

    fn init(allocator: std.mem.Allocator) UserStore {
        return .{
            .backing_allocator = allocator,
            .map = std.AutoHashMap(i32, StoredUser).init(allocator),
        };
    }

    fn deinit(self: *UserStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.arena.deinit();
        }
        self.map.deinit();
    }
};

// Method impls match the signature expected by Service(*UserStore).addMethod:
//   fn(std.mem.Allocator, Request, *UserStore) MethodResult(Response)

fn getUser(
    allocator: std.mem.Allocator,
    request: service_mod.GetUserRequest,
    store: *UserStore,
) skir.MethodResult(service_mod.GetUserResponse) {
    _ = allocator;
    store.mutex.lock();
    defer store.mutex.unlock();
    const maybe_stored = store.map.getPtr(request.user_id);
    return .{ .ok = .{ .user = if (maybe_stored) |s| s.user else null } };
}

fn addUser(
    allocator: std.mem.Allocator,
    request: service_mod.AddUserRequest,
    store: *UserStore,
) skir.MethodResult(service_mod.AddUserResponse) {
    _ = allocator;

    if (request.user.user_id == 0) {
        return .{ .service_error = .{
            .status_code = ._400_BadRequest,
            .message = "invalid user id",
        } };
    }

    // Clone into a fresh arena before taking the lock.
    var arena = std.heap.ArenaAllocator.init(store.backing_allocator);
    const user = request.user.clone(arena.allocator()) catch {
        arena.deinit();
        return .{ .unknown_error = "failed to clone user" };
    };

    store.mutex.lock();
    const old = store.map.fetchPut(user.user_id, .{ .arena = arena, .user = user }) catch {
        store.mutex.unlock();
        arena.deinit();
        return .{ .unknown_error = "failed to insert user" };
    };
    store.mutex.unlock();

    // Free the displaced entry's arena outside the lock.
    if (old) |entry| entry.value.arena.deinit();

    std.debug.print("Added user {s} (id={d})\n", .{ user.name, user.user_id });

    return .{ .ok = service_mod.AddUserResponse.default };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user_store = UserStore.init(allocator);
    defer user_store.deinit();

    var service = try skir.Service(*UserStore).init(allocator);
    defer service.deinit();

    _ = try service.addMethod(
        service_mod.GetUserRequest,
        service_mod.GetUserResponse,
        &service_mod.get_user_method(),
        getUser,
    );
    _ = try service.addMethod(
        service_mod.AddUserRequest,
        service_mod.AddUserResponse,
        &service_mod.add_user_method(),
        addUser,
    );

    const listen_address = try std.net.Address.parseIp("0.0.0.0", 8787);
    var server = try listen_address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening on http://localhost:8787/myapi\n", .{});

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        try handleConnection(allocator, &service, &user_store, conn.stream);
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    service: *const skir.Service(*UserStore),
    user_store: *UserStore,
    stream: std.net.Stream,
) !void {
    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    const request_bytes = try readRequest(request_allocator, stream);
    if (request_bytes.len == 0) {
        return;
    }

    const headers_end = std.mem.indexOf(u8, request_bytes, "\r\n\r\n") orelse {
        try writePlainTextResponse(stream, 400, "Bad Request", "bad request: malformed HTTP request");
        return;
    };

    const header_block = request_bytes[0..headers_end];
    const body = request_bytes[headers_end + 4 ..];

    var header_lines = std.mem.splitSequence(u8, header_block, "\r\n");
    const request_line = header_lines.next() orelse {
        try writePlainTextResponse(stream, 400, "Bad Request", "bad request: missing request line");
        return;
    };

    var line_parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = line_parts.next() orelse {
        try writePlainTextResponse(stream, 400, "Bad Request", "bad request: malformed request line");
        return;
    };
    const target = line_parts.next() orelse {
        try writePlainTextResponse(stream, 400, "Bad Request", "bad request: malformed request line");
        return;
    };

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/")) {
        try writePlainTextResponse(stream, 200, "OK", "Hello, World!");
        return;
    }

    if (!std.mem.startsWith(u8, target, "/myapi")) {
        try writePlainTextResponse(stream, 404, "Not Found", "not found");
        return;
    }

    const body_for_service = if (std.mem.eql(u8, method, "GET"))
        try skir.getPercentDecodedQueryFromUrl(request_allocator, target)
    else if (std.mem.eql(u8, method, "POST"))
        body
    else {
        try writePlainTextResponse(stream, 405, "Method Not Allowed", "method not allowed");
        return;
    };

    const raw_response = try service.handleRequest(request_allocator, body_for_service, user_store);
    try writeRawResponse(stream, raw_response);
}

fn readRequest(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var all = std.ArrayList(u8).empty;
    var buffer: [8192]u8 = undefined;

    while (true) {
        const n = try stream.read(&buffer);
        if (n == 0) break;
        try all.appendSlice(allocator, buffer[0..n]);

        if (all.items.len >= 4 and std.mem.indexOf(u8, all.items, "\r\n\r\n") != null) {
            break;
        }

        if (all.items.len > 1024 * 1024) {
            return error.RequestTooLarge;
        }
    }

    const headers_end = std.mem.indexOf(u8, all.items, "\r\n\r\n") orelse {
        return all.toOwnedSlice(allocator);
    };

    const header_block = all.items[0..headers_end];
    const content_length = parseContentLength(header_block);
    const wanted_len = headers_end + 4 + content_length;

    while (all.items.len < wanted_len) {
        const n = try stream.read(&buffer);
        if (n == 0) break;
        try all.appendSlice(allocator, buffer[0..n]);
        if (all.items.len > 1024 * 1024) {
            return error.RequestTooLarge;
        }
    }

    return all.toOwnedSlice(allocator);
}

fn parseContentLength(header_block: []const u8) usize {
    var it = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = it.next();

    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(key, "content-length")) {
            continue;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.fmt.parseInt(usize, value, 10) catch 0;
    }

    return 0;
}

fn writeRawResponse(stream: std.net.Stream, raw: skir.RawResponse) !void {
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "{s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ raw.status_line, raw.content_type, raw.data.len },
    );
    try stream.writeAll(header);
    try stream.writeAll(raw.data);
}

fn writePlainTextResponse(
    stream: std.net.Stream,
    status_code: u16,
    status_text: []const u8,
    body: []const u8,
) !void {
    var line_buf: [64]u8 = undefined;
    const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}", .{ status_code, status_text });

    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "{s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status_line, body.len },
    );

    try stream.writeAll(header);
    try stream.writeAll(body);
}
