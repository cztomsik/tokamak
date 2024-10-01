const root = @import("root");
const std = @import("std");

// This can be overridden in your root module (with `pub const mime_types = ...;`)
// and it doesn't have to be a comptime map either
pub const mime_types = if (@hasDecl(root, "mime_types")) root.mime_types else std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html" },
    .{ ".css", "text/css" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".js", "text/javascript" },
    .{ ".md", "text/markdown" },
});

/// Get the MIME type for a given file extension.
pub fn mime(ext: []const u8) []const u8 {
    return mime_types.get(ext) orelse "application/octet-stream";
}
