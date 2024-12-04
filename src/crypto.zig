const std = @import("std");

pub fn sha1(key: anytype) [40]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

test sha1 {
    try std.testing.expectEqualStrings(
        &sha1("hello"),
        "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d",
    );
}
