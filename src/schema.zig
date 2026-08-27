const std = @import("std");
const string = @import("string.zig");
const meta = @import("meta.zig");
const testing = @import("testing.zig");

pub const Property = struct {
    name: []const u8,
    schema: *const Schema,
    required: bool,
};

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

    pub fn schema(comptime T: type) Schema {
        if (meta.hasDecl(T, "jsonSchema")) {
            return T.jsonSchema;
        }

        // NOTE: This is because we want to return Schema as value but we can
        // only enforce comptime with pointers, so we need an extra indirection.
        return comptimeSchema(T).*;
    }

    fn comptimeSchema(comptime T: type) *const Schema {
        return comptime &switch (T) {
            []const u8, string.String, string.ShortString => .string,
            else => switch (@typeInfo(T)) {
                .null => .null,
                .bool => .boolean,
                .int => .integer,
                .float => .number,
                .@"enum" => .string,
                .optional => |o| .{ .oneOf = &.{ .null, schema(o.child) } },
                .@"union" => .{ .object = &.{} }, // TODO
                .@"struct" => |s| if (s.is_tuple) .{ .tuple = brk: {
                    var kinds: [s.field_types.len]Schema = undefined;
                    for (s.field_types, 0..) |ft, i| kinds[i] = schema(ft);
                    const res = kinds;
                    break :brk &res;
                } } else .{
                    .object = brk: {
                        var props: [s.field_names.len]Property = undefined;
                        for (s.field_names, s.field_types, s.field_attrs, 0..) |f, ft, fa, i| props[i] = .{ .name = f, .schema = &schema(ft), .required = fa.default_value_ptr == null };
                        const res = props;
                        break :brk &res;
                    },
                },
                .array => |a| .{ .array = comptimeSchema(a.child) },
                .pointer => |p| blk: {
                    if (p.size == .slice) {
                        break :blk .{ .array = comptimeSchema(p.child) };
                    } else {
                        @compileError("Unsupported ptr type " ++ @typeName(T));
                    }
                },
                else => @compileError("Unsupported type " ++ @typeName(T)),
            },
        };
    }

    pub fn jsonStringify(self: Schema, jw: anytype) !void {
        switch (self) {
            .oneOf => |oneOf| try jw.write(.{ .oneOf = oneOf }),
            .array => |items| try jw.write(.{ .type = .array, .items = items }),
            .tuple => |items| try jw.write(.{ .type = .array, .items = items }),
            .object => |props| {
                try jw.beginObject();

                try jw.objectField("type");
                try jw.write("object");

                try jw.objectField("properties");
                try serializeProperties(props, jw);

                try jw.objectField("required");
                try serializeRequired(props, jw);

                try jw.objectField("additionalProperties");
                try jw.write(false);

                try jw.endObject();
            },
            inline else => |_, t| try jw.write(.{ .type = t }),
        }
    }

    fn serializeProperties(props: []const Property, jw: anytype) !void {
        try jw.beginObject();
        for (props) |p| {
            try jw.objectField(p.name);
            try jw.write(p.schema);
        }
        try jw.endObject();
    }

    fn serializeRequired(props: []const Property, jw: anytype) !void {
        try jw.beginArray();
        for (props) |p| if (p.required) try jw.write(p.name);
        try jw.endArray();
    }
};

fn expectSchema(comptime T: type, schema: Schema) !void {
    try std.testing.expectEqualDeep(schema, Schema.schema(T));
}

test "Schema.schema()" {
    try expectSchema(bool, .boolean);
    try expectSchema(u32, .integer);
    try expectSchema(i32, .integer);
    try expectSchema(f32, .number);
    try expectSchema([]const u8, .string);
    try expectSchema(?[]const u8, .{ .oneOf = &.{ .null, .string } });
    try expectSchema(struct { a: u32 }, .{ .object = &.{.{ .name = "a", .schema = &.integer, .required = true }} });
    try expectSchema(struct { u32, f32 }, .{ .tuple = &.{ .integer, .number } });
}

fn expectJsonSchema(comptime T: type, expected: []const u8) !void {
    try testing.expectJson(Schema.schema(T), expected);
}

test "schema json" {
    try expectJsonSchema(?[]const u8,
        \\{
        \\  "oneOf": [
        \\    {
        \\      "type": "null"
        \\    },
        \\    {
        \\      "type": "string"
        \\    }
        \\  ]
        \\}
    );

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

    try expectJsonSchema(struct { text: []const u8 = "" },
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "text": {
        \\      "type": "string"
        \\    }
        \\  },
        \\  "required": [],
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
