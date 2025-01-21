const std = @import("std");
const meta = @import("meta.zig");

pub const Schema = union(enum) {
    null,
    boolean,
    integer,
    number,
    string,
    object: []const Property,
    array: *const Schema,
    oneOf: []const Schema, // inentional camelCase (ident)

    pub fn forType(comptime T: type) Schema {
        if (comptime meta.hasDecl(T, "jsonSchema")) {
            return T.jsonSchema;
        }

        return switch (T) {
            []const u8 => .string,
            else => switch (@typeInfo(T)) {
                .null => .null,
                .bool => .boolean,
                .int => .integer,
                .float => .number,
                .@"enum" => .string,
                .optional => |o| .{ .oneOf = &.{ .null, Schema.forType(o.child) } },
                .@"union" => .{ .object = &.{} }, // TODO
                .@"struct" => .{
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

    pub fn jsonStringify(self: Schema, w: anytype) !void {
        switch (self) {
            .oneOf => |schemas| try w.write(.{ .oneOf = schemas }),
            .array => |schema| try w.write(.{ .type = .array, .items = schema }),
            .object => |props| {
                try w.beginObject();

                try w.objectField("type");
                try w.write(.object);

                try w.objectField("properties");
                try w.beginObject();

                for (props) |p| {
                    try w.objectField(p.name);
                    try w.write(p.schema);
                }

                try w.endObject();
                try w.endObject();
            },
            inline else => |_, t| try w.write(.{ .type = t }),
        }
    }
};

pub const Property = struct {
    name: []const u8,
    schema: *const Schema,
};
