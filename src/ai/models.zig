pub const Model = struct {
    id: []const u8,
};

pub const ListResponse = struct {
    data: []const Model,
};
