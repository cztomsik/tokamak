const std = @import("std");
const string = @import("string.zig");
const meta = @import("meta.zig");
const serde = @import("serde.zig");
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
                    const fields = std.meta.fields(T);
                    var kinds: [fields.len]Schema = undefined;
                    for (fields, 0..) |f, i| kinds[i] = schema(f.type);
                    const res = kinds;
                    break :brk &res;
                } } else .{
                    .object = brk: {
                        const fields = std.meta.fields(T);
                        var props: [fields.len]Property = undefined;
                        for (fields, 0..) |f, i| props[i] = .{ .name = f.name, .schema = &schema(f.type), .required = f.default_value_ptr == null };
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

    pub fn serialize(self: Schema, w: anytype) !void {
        switch (self) {
            .oneOf => |oneOf| try serde.serialize(w, .{ .oneOf = oneOf }),
            .array => |items| try serde.serialize(w, .{ .type = .array, .items = items }),
            .tuple => |items| try serde.serialize(w, .{ .type = .array, .items = items }),
            .object => |props| {
                var st = try w.beginStruct(struct {}, 4);
                try st.field("type", "object");
                try st.field("properties", serde.serializer(props, serializeProperties));
                try st.field("required", serde.serializer(props, serializeRequired));
                try st.field("additionalProperties", false);
                try st.end();
            },
            inline else => |_, t| try serde.serialize(w, .{ .type = t }),
        }
    }

    fn serializeProperties(props: []const Property, writer: anytype) !void {
        var st = try writer.beginStruct(void, props.len);
        for (props) |p| try st.field(p.name, p.schema);
        try st.end();
    }

    fn serializeRequired(props: []const Property, writer: anytype) !void {
        var seq = try writer.beginSeq(props.len);
        for (props) |p| if (p.required) try seq.element(p.name);
        try seq.end();
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
    try serde.json.expectJson(Schema.schema(T), expected);
}

test "schema.serialize()" {
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
