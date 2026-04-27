// Code snippets showing how to use Zig-generated data types.
//
// Run with: zig build run

const std = @import("std");
const skir = @import("skir_client.zig");
const user_mod = @import("skirout/user.zig");
const service_mod = @import("skirout/service.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // =========================================================================
    // STRUCT TYPES
    // =========================================================================

    // Skir generates a plain Zig struct for each struct in the .skir schema.
    const john: user_mod.User = .{
        .user_id = 42,
        .name = "John Doe",
        .quote = "Coffee is just a socially acceptable form of rage.",
        .pets = &.{.{
            .name = "Dumbo",
            .height_in_meters = 1.0,
            .picture = "🐘",
            ._unrecognized = null,
        }},
        .subscription_status = .Free,
        ._unrecognized = null,
    };

    std.debug.print("{s}\n", .{john.name});
    // John Doe

    // Default value for a generated struct.
    const jane = user_mod.User.default;
    std.debug.print("{s}\n", .{jane.name});
    // (empty string)
    std.debug.print("{d}\n", .{jane.user_id});
    // 0

    // Modified copy (value semantics).
    var evil_john = john;
    evil_john.name = "Evil John";
    evil_john.quote = "I solemnly swear I am up to no good.";

    std.debug.print("{s}\n", .{evil_john.name});
    // Evil John
    std.debug.print("{d}\n", .{evil_john.user_id});
    // 42

    // =========================================================================
    // ENUM TYPES
    // =========================================================================

    const trial_payload: user_mod.SubscriptionStatus.Trial_ = .{
        .start_time = .{ .unix_millis = 1_744_974_198_000 },
        ._unrecognized = null,
    };

    const some_statuses = [_]user_mod.SubscriptionStatus{
        user_mod.SubscriptionStatus.unknown,
        .Free,
        .Premium,
        .{ .Trial = &trial_payload },
    };
    _ = some_statuses;

    // =========================================================================
    // ENUM MATCHING
    // =========================================================================

    std.debug.print("{s}\n", .{subscriptionInfoText(john.subscription_status)});
    // Free user
    std.debug.print("{s}\n", .{subscriptionInfoText(user_mod.SubscriptionStatus.unknown)});
    // Unknown subscription status
    std.debug.print("{s}\n", .{subscriptionInfoText(.{ .Trial = &trial_payload })});
    // On trial since (some timestamp)

    // =========================================================================
    // SERIALIZATION
    // =========================================================================

    const user_serializer = user_mod.User.serializer();

    const john_dense_json = try user_serializer.serialize(allocator, john, .{ .format = .denseJson });
    defer allocator.free(john_dense_json);
    std.debug.print("{s}\n", .{john_dense_json});
    // [42,"John Doe","Coffee is just a socially acceptable form of rage.",[["Dumbo",1,"🐘"]],1]

    const john_readable_json = try user_serializer.serialize(allocator, john, .{ .format = .readableJson });
    defer allocator.free(john_readable_json);
    std.debug.print("{s}\n", .{john_readable_json});
    // {
    //   "user_id": 42,
    //   "name": "John Doe",
    //   ...
    // }

    const john_binary = try user_serializer.serialize(allocator, john, .{ .format = .binary });
    defer allocator.free(john_binary);

    // deserialize() auto-detects the format (dense JSON, readable JSON, or
    // binary) from the input bytes — the same call works for all three.
    // Pass an arena allocator; the entire deserialized value is freed at once
    // by calling arena.deinit().
    var deserialize_arena = std.heap.ArenaAllocator.init(allocator);
    defer deserialize_arena.deinit();

    // Deserialize from dense JSON.
    const from_dense = try user_serializer.deserialize(deserialize_arena.allocator(), john_dense_json, .{});
    std.debug.print("{s}\n", .{from_dense.name});
    // John Doe

    // Deserialize from readable JSON — same call, different bytes.
    const from_readable = try user_serializer.deserialize(deserialize_arena.allocator(), john_readable_json, .{});
    std.debug.print("{s}\n", .{from_readable.name});
    // John Doe

    // Deserialize from binary — same call again.
    const from_binary = try user_serializer.deserialize(deserialize_arena.allocator(), john_binary, .{});
    std.debug.print("{s}\n", .{from_binary.name});
    // John Doe

    // =========================================================================
    // PRIMITIVE SERIALIZERS
    // =========================================================================

    try printSerialized("bool", skir.boolSerializer(), true);
    try printSerialized("int32", skir.int32Serializer(), @as(i32, 3));
    try printSerialized("int64", skir.int64Serializer(), @as(i64, 9_223_372_036_854_775_807));
    try printSerialized("hash64", skir.hash64Serializer(), @as(u64, 18_446_744_073_709_551_615));
    try printSerialized("timestamp", skir.timestampSerializer(), skir.Timestamp{ .unix_millis = 1_743_682_787_000 });
    try printSerialized("float32", skir.float32Serializer(), @as(f32, 3.14));
    try printSerialized("float64", skir.float64Serializer(), @as(f64, 3.14));
    try printSerialized("string", skir.stringSerializer(), "Foo");
    try printSerialized("bytes", skir.bytesSerializer(), @as([]const u8, &.{ 1, 2, 3 }));

    // =========================================================================
    // COMPOSITE SERIALIZERS
    // =========================================================================

    const opt_string_ser = skir.optionalSerializer(skir.stringSerializer());
    try printSerialized("optional some", opt_string_ser, @as(?[]const u8, "foo"));
    try printSerialized("optional none", opt_string_ser, @as(?[]const u8, null));

    const bool_array_ser = skir.arraySerializer(skir.boolSerializer());
    try printSerialized("bool array", bool_array_ser, @as([]const bool, &.{ true, false }));

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    const tarzan = user_mod.tarzan_const;
    std.debug.print("{s}\n", .{tarzan.name});
    // Tarzan

    const tarzan_json = try user_serializer.serialize(allocator, tarzan, .{ .format = .readableJson });
    defer allocator.free(tarzan_json);
    std.debug.print("{s}\n", .{tarzan_json});
    // {
    //   "user_id": 123,
    //   "name": "Tarzan",
    //   ...
    // }

    // =========================================================================
    // KEYED ARRAYS
    // =========================================================================

    var users = [_]user_mod.User{ john, jane, evil_john, tarzan };
    var registry = user_mod.UserRegistry{
        .users = skir.KeyedArray(user_mod.User.By_UserId).init(allocator, users[0..]),
        ._unrecognized = null,
    };
    // For a KeyedArray built manually like this, call deinit() to free its
    // index storage. If the KeyedArray comes from deserialize() with an arena,
    // the index memory is released when that arena is deinitialized.
    defer registry.users.deinit();

    const found_43 = try registry.users.findByKey(43);
    std.debug.print("{}\n", .{found_43 == null});
    // true

    const found_42 = try registry.users.findByKey(42);
    if (found_42) |u| {
        std.debug.print("{s}\n", .{u.name});
        // Evil John (last duplicate wins)
    }

    const found_or_default = try registry.users.findByKeyOrDefault(999);
    std.debug.print("{d}\n", .{found_or_default.pets.len});
    // 0

    // =========================================================================
    // REFLECTION
    // =========================================================================

    const type_descriptor = user_serializer.typeDescriptor();
    switch (type_descriptor) {
        .struct_record => |sd| {
            std.debug.print("{s} has {d} fields\n", .{ sd.name, sd.fields.len });
            // User has 5 fields
            if (sd.fieldByName("name")) |f| {
                std.debug.print("field 'name' number={d}\n", .{f.number});
                // field 'name' number=1
            }
        },
        else => {},
    }

    const enum_type_descriptor = user_mod.SubscriptionStatus.serializer().typeDescriptor();
    switch (enum_type_descriptor) {
        .enum_record => |ed| {
            std.debug.print("{s} has {d} variants\n", .{ ed.name, ed.variants.len });
            // SubscriptionStatus has 3 variants
            if (ed.variantByName("trial")) |variant| {
                std.debug.print("variant trial number={d}\n", .{variant.number()});
                // variant trial number=2
            }
        },
        else => {},
    }
}

fn subscriptionInfoText(status: user_mod.SubscriptionStatus) []const u8 {
    return switch (status) {
        .Unknown => "Unknown subscription status",
        .Free => "Free user",
        .Trial => |trial| blk: {
            _ = trial;
            break :blk "On trial since (some timestamp)";
        },
        .Premium => "Premium user",
    };
}

fn printSerialized(label: []const u8, serializer: anytype, value: @TypeOf(serializer).Value) !void {
    const allocator = std.heap.page_allocator;
    const dense = try serializer.serialize(allocator, value, .{ .format = .denseJson });
    defer allocator.free(dense);
    std.debug.print("{s}: {s}\n", .{ label, dense });
}
