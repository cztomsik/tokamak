const std = @import("std");
const string = @import("string.zig");
const meta = @import("meta.zig");
const serde = @import("serde.zig");
const testing = @import("testing.zig");

pub const Schema = union(enum) {
    null,
    boolean,
    integer,
    number,
    string,
    object: []const Property,
    array: *const Schema,
    oneOf: []const Schema, // intentional camelCase (ident)
    tuple: []const Schema,

    pub fn forType(comptime T: type) Schema {
        if (meta.hasDecl(T, "jsonSchema")) {
            return T.jsonSchema;
        }

        return switch (T) {
            []const u8, string.String, string.ShortString => .string,
            else => switch (@typeInfo(T)) {
                .null => .null,
                .bool => .boolean,
                .int => .integer,
                .float => .number,
                .@"enum" => .string,
                .optional => |o| .{ .oneOf = &.{ .null, Schema.forType(o.child) } },
                .@"union" => .{ .object = &.{} }, // TODO
                .@"struct" => |s| if (s.is_tuple) .{ .tuple = comptime brk: {
                    const fields = std.meta.fields(T);
                    var kinds: [fields.len]Schema = undefined;
                    for (fields, 0..) |f, i| kinds[i] = Schema.forType(f.type);
                    const res = kinds;
                    break :brk &res;
                } } else .{
                    .object = comptime brk: {
                        const fields = std.meta.fields(T);
                        var props: [fields.len]Property = undefined;
                        for (fields, 0..) |f, i| props[i] = .{ .name = f.name, .schema = &Schema.forType(f.type) };
                        const res = props;
                        break :brk &res;
                    },
                },
                .array => |a| .{ .array = &Schema.forType(a.child) },
                .pointer => |p| {
                    if (p.size == .slice) {
                        return .{ .array = &Schema.forType(p.child) };
                    } else {
                        @compileError("Unsupported ptr type " ++ @typeName(T));
                    }
                },
                else => @compileError("Unsupported type " ++ @typeName(T)),
            },
        };
    }

    pub fn serialize(self: Schema, w: anytype) !void {
        switch (self) {
            .oneOf => |schemas| try serde.serialize(w, .{ .oneOf = schemas }),
            .array => |schema| try serde.serialize(w, .{ .type = .array, .items = schema }),
            .tuple => |items| try serde.serialize(w, .{ .type = .array, .items = items }),
            .object => |props| {
                try w.write(.struct_begin, {});

                try w.write(.struct_field, "type");
                try w.write(.string, "object");

                try w.write(.struct_field, "properties");
                try w.write(.struct_begin, {});
                for (props) |p| {
                    try w.write(.struct_field, p.name);
                    try serde.serialize(w, p.schema);
                }
                try w.write(.struct_end, {});

                try w.write(.struct_field, "required");
                try w.write(.array_begin, {});
                for (props) |p| {
                    try w.write(.string, p.name);
                }
                try w.write(.array_end, {});

                try w.write(.struct_field, "additionalProperties");
                try w.write(.bool, false);

                try w.write(.struct_end, {});
            },
            inline else => |_, t| try serde.serialize(w, .{ .type = t }),
        }
    }
};

pub const Property = struct {
    name: []const u8,
    schema: *const Schema,
};

fn expectSchema(comptime T: type, schema: Schema) !void {
    try std.testing.expectEqualDeep(schema, Schema.forType(T));
}

test "Schema.forType()" {
    try expectSchema(bool, .boolean);
    try expectSchema(u32, .integer);
    try expectSchema(i32, .integer);
    try expectSchema(f32, .number);
    try expectSchema([]const u8, .string);
    try expectSchema(struct { a: u32 }, .{ .object = &.{.{ .name = "a", .schema = &.integer }} });
    try expectSchema(struct { u32, f32 }, .{ .tuple = &.{ .integer, .number } });
}

fn expectJsonSchema(comptime T: type, expected: []const u8) !void {
    try serde.json.expectJson(Schema.forType(T), expected);
}

test "schema.serialize()" {
    try expectJsonSchema(u32,
        \\{
        \\  "type": "integer"
        \\}
    );

    try expectJsonSchema(struct { a: u32 },
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": {
        \\      "type": "integer"
        \\    }
        \\  },
        \\  "required": [
        \\    "a"
        \\  ],
        \\  "additionalProperties": false
        \\}
    );

    try expectJsonSchema(struct { a: ?u32 },
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": {
        \\      "oneOf": [
        \\        {
        \\          "type": "null"
        \\        },
        \\        {
        \\          "type": "integer"
        \\        }
        \\      ]
        \\    }
        \\  },
        \\  "required": [
        \\    "a"
        \\  ],
        \\  "additionalProperties": false
        \\}
    );

    // TODO: this is from Draft 4 - 2019-09 which is still used a lot
    try expectJsonSchema(struct { u32, f32 },
        \\{
        \\  "type": "array",
        \\  "items": [
        \\    {
        \\      "type": "integer"
        \\    },
        \\    {
        \\      "type": "number"
        \\    }
        \\  ]
        \\}
    );
}
