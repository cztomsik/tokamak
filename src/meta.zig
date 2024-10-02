pub const TypeId = enum(usize) {
    _,

    pub inline fn get(comptime T: type) TypeId {
        return @enumFromInt(@intFromPtr(@typeName(T)));
    }
};

pub fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .One,
        else => false,
    };
}
