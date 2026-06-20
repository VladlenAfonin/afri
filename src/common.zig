const std = @import("std");
const build_options = @import("build_options");

pub const sha3 = @import("common/sha3.zig");
pub const streebog = @import("common/streebog.zig");

/// The 256-bit hash implementation selected with `-Dhash`.
pub const Hash = switch (build_options.hash) {
    .sha2 => std.crypto.hash.sha2.Sha256,
    .sha3 => sha3.Sha3_256,
    .streebog => streebog.Streebog256,
};

pub const Digest = [Hash.digest_length]u8;
