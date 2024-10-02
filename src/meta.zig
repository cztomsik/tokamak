pub fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .One,
        else => false,
    };
}
