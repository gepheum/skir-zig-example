const std = @import("std");
const skir = @import("skir_client.zig");
const service_mod = @import("skirout/service.zig");
const user_mod = @import("skirout/user.zig");

const UserStore = std.AutoHashMap(i32, user_mod.User);

var g_store: *UserStore = undefined;
var g_store_allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = UserStore.init(allocator);
    defer {
        var it = store.iterator();
        while (it.next()) |entry| {
            freeUser(allocator, entry.value_ptr.*);
        }
        store.deinit();
    }

    g_store = &store;
    g_store_allocator = allocator;

    var service = try skir.Service(void).init(allocator);
    defer service.deinit();

    _ = try service.addMethod(
        service_mod.GetUserRequest,
        service_mod.GetUserResponse,
        &service_mod.get_user_method(),
        getUserImpl,
    );
    _ = try service.addMethod(
        service_mod.AddUserRequest,
        service_mod.AddUserResponse,
        &service_mod.add_user_method(),
        addUserImpl,
    );

    const listen_address = try std.net.Address.parseIp("0.0.0.0", 8787);
    var server = try listen_address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening on http://localhost:8787/myapi\n", .{});

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        try handleConnection(allocator, &service, conn.stream);
    }
}

fn getUserImpl(
    allocator: std.mem.Allocator,
    request: service_mod.GetUserRequest,
    _: void,
) skir.MethodResult(service_mod.GetUserResponse) {
    _ = allocator;
    const maybe_user = g_store.get(request.user_id);
    return .{ .ok = .{ .user = maybe_user } };
}

fn addUserImpl(
    allocator: std.mem.Allocator,
    request: service_mod.AddUserRequest,
    _: void,
) skir.MethodResult(service_mod.AddUserResponse) {
    _ = allocator;

    if (request.user.user_id == 0) {
        return .{ .service_error = .{
            .status_code = ._400_BadRequest,
            .message = "invalid user id",
        } };
    }

    const copied_user = cloneUser(g_store_allocator, request.user) catch {
        return .{ .unknown_error = "failed to clone user" };
    };

    const old = g_store.fetchPut(copied_user.user_id, copied_user) catch {
        freeUser(g_store_allocator, copied_user);
        return .{ .unknown_error = "failed to insert user" };
    };

    if (old) |entry| {
        freeUser(g_store_allocator, entry.value);
    }

    std.debug.print("Added user {s} (id={d})\n", .{ copied_user.name, copied_user.user_id });

    return .{ .ok = service_mod.AddUserResponse.default };
}

fn handleConnection(
    allocator: std.mem.Allocator,
    service: *const skir.Service(void),
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

    const raw_response = try service.handleRequest(request_allocator, body_for_service, {});
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

fn cloneUser(allocator: std.mem.Allocator, user: user_mod.User) !user_mod.User {
    const name = try allocator.dupe(u8, user.name);
    errdefer allocator.free(name);

    const quote = try allocator.dupe(u8, user.quote);
    errdefer allocator.free(quote);

    var pets = try allocator.alloc(user_mod.User.Pet, user.pets.len);
    errdefer allocator.free(pets);

    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            allocator.free(pets[i].name);
            allocator.free(pets[i].picture);
        }
    }

    while (i < user.pets.len) : (i += 1) {
        const pet = user.pets[i];
        pets[i] = .{
            .name = try allocator.dupe(u8, pet.name),
            .height_in_meters = pet.height_in_meters,
            .picture = try allocator.dupe(u8, pet.picture),
        };
    }

    return .{
        .user_id = user.user_id,
        .name = name,
        .quote = quote,
        .pets = pets,
        .subscription_status = user.subscription_status,
    };
}

fn freeUser(allocator: std.mem.Allocator, user: user_mod.User) void {
    allocator.free(user.name);
    allocator.free(user.quote);
    for (user.pets) |pet| {
        allocator.free(pet.name);
        allocator.free(pet.picture);
    }
    allocator.free(user.pets);
}
