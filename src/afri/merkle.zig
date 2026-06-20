const std = @import("std");
const utils = @import("utils.zig");
const common = @import("common");

pub const Hash = common.Hash;
pub const Digest = common.Digest;

pub fn hashBytes(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Hash.hash(bytes, &out, .{});
    return out;
}

fn hashNode(left: Digest, right: Digest) Digest {
    var buf: [2 * Hash.digest_length]u8 = undefined;
    @memcpy(buf[0..Hash.digest_length], &left);
    @memcpy(
        buf[Hash.digest_length .. 2 * Hash.digest_length],
        &right,
    );
    return hashBytes(&buf);
}

pub const MerkleTree = struct {
    nodes: []Digest,
    leaf_count: usize,

    const Self = @This();

    pub const Error = error{
        EmptyTree,
        NotPowerOfTwo,
        IndexOutOfBounds,
        ProofTooShort,
    };

    /// Build a tree from already-hashed leaf digests.
    pub fn buildFromLeaves(
        allocator: std.mem.Allocator,
        leaves: []const Digest,
    ) !Self {
        const n = leaves.len;
        if (n == 0) return Error.EmptyTree;
        if (!utils.isPowerOfTwo(n)) return Error.NotPowerOfTwo;

        const total_nodes = 2 * n - 1;
        var nodes = try allocator.alloc(Digest, total_nodes);

        const leaf_offset = n - 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            nodes[leaf_offset + i] = leaves[i];
        }

        var idx: usize = leaf_offset;
        while (idx > 0) {
            idx -= 1;
            nodes[idx] = hashNode(
                nodes[2 * idx + 1],
                nodes[2 * idx + 2],
            );
        }

        return .{ .nodes = nodes, .leaf_count = n };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        self.nodes = &.{};
        self.leaf_count = 0;
    }

    pub inline fn root(self: Self) Digest {
        return self.nodes[0];
    }

    /// Fill `proof_out` with the authentication path for leaf `leaf_idx`.
    /// Returns the number of entries written.
    pub fn open(
        self: Self,
        leaf_idx: usize,
        proof_out: []Digest,
    ) !usize {
        if (leaf_idx >= self.leaf_count) {
            return Error.IndexOutOfBounds;
        }

        var idx = (self.leaf_count - 1) + leaf_idx;
        var depth: usize = 0;

        while (idx > 0) : (depth += 1) {
            if (depth >= proof_out.len) return Error.ProofTooShort;
            const sibling = if ((idx & 1) == 0) idx - 1 else idx + 1;
            proof_out[depth] = self.nodes[sibling];
            idx = (idx - 1) / 2;
        }

        return depth;
    }

    pub fn rootFromProofDigest(
        leaf: Digest,
        leaf_idx: usize,
        proof: []const Digest,
    ) Digest {
        var h = leaf;
        var idx = leaf_idx;

        var depth: usize = 0;
        while (depth < proof.len) : (depth += 1) {
            const sib = proof[depth];
            const even = (idx & 1) == 0;
            h = if (even) hashNode(h, sib) else hashNode(sib, h);
            idx >>= 1;
        }

        return h;
    }
};

test "MerkleTree build/open/verify (digests)" {
    const leaves: [4]Digest = .{
        hashBytes("a"),
        hashBytes("b"),
        hashBytes("b"),
        hashBytes("c"),
    };

    var tree = try MerkleTree.buildFromLeaves(
        std.testing.allocator,
        &leaves,
    );
    defer tree.deinit(std.testing.allocator);

    const root = tree.root();

    var proof_buf: [64]Digest = undefined;
    const depth = try tree.open(2, &proof_buf);
    const proof = proof_buf[0..depth];

    const recomputed = MerkleTree.rootFromProofDigest(
        leaves[2],
        2,
        proof,
    );
    try std.testing.expectEqualSlices(u8, &root, &recomputed);
}
