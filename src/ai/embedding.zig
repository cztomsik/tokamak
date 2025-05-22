pub const Request = struct {
    model: []const u8,
    input: []const u8,
};

pub const Response = struct {
    object: []const u8,
    model: []const u8,
    data: []const Embedding,
    usage: struct {
        prompt_tokens: u32,
        total_tokens: u32,
    },
};

pub const Embedding = struct {
    index: u32,
    object: []const u8,
    embedding: []const f32,
};
