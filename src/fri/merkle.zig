const std = @import("std");
const field = @import("field.zig");
const utils = @import("utils.zig");
const common = @import("common");

const Goldilocks = field.Goldilocks;
const F = Goldilocks;
const Hash = common.Hash;

pub const Digest = common.Digest;

fn hashBytes(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Hash.hash(bytes, &out, .{});
    return out;
}

fn encodeU64LE(x: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, x, .little);
    return out;
}

pub fn leafDigestGoldilocks(val: F) Digest {
    const b = encodeU64LE(val.value);
    return hashBytes(&b);
}

pub fn leafDigestGoldilocksPair(lo: F, hi: F) Digest {
    var buf: [16]u8 = undefined;
    const a = encodeU64LE(lo.value);
    const b = encodeU64LE(hi.value);
    @memcpy(buf[0..8], &a);
    @memcpy(buf[8..16], &b);
    return hashBytes(&buf);
}

fn hashNode(left: Digest, right: Digest) Digest {
    var buf: [2 * Hash.digest_length]u8 = undefined;
    @memcpy(buf[0..Hash.digest_length], left[0..]);
    @memcpy(buf[Hash.digest_length..][0..Hash.digest_length], right[0..]);
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

    pub fn build(allocator: std.mem.Allocator, leaves: []const F) !Self {
        const n = leaves.len;
        if (n == 0) return Error.EmptyTree;
        if (!utils.isPowerOfTwo(n)) return Error.NotPowerOfTwo;

        const total_nodes = 2 * n - 1;
        var nodes = try allocator.alloc(Digest, total_nodes);

        const leaf_offset = n - 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            nodes[leaf_offset + i] = leafDigestGoldilocks(leaves[i]);
        }

        var idx: usize = leaf_offset;
        while (idx > 0) {
            idx -= 1;
            const left = nodes[2 * idx + 1];
            const right = nodes[2 * idx + 2];
            nodes[idx] = hashNode(left, right);
        }

        return .{
            .nodes = nodes,
            .leaf_count = n,
        };
    }

    pub fn buildPairs(allocator: std.mem.Allocator, leaves: []const F) !Self {
        const n = leaves.len;
        if (n < 2) return Error.EmptyTree;
        if (!utils.isPowerOfTwo(n)) return Error.NotPowerOfTwo;

        const m = n / 2; // number of pair-leaves
        // m is power-of-two if n is power-of-two (including m=1).

        const total_nodes = 2 * m - 1;
        var nodes = try allocator.alloc(Digest, total_nodes);

        const leaf_offset = m - 1;
        var j: usize = 0;
        while (j < m) : (j += 1) {
            const lo = leaves[2 * j];
            const hi = leaves[2 * j + 1];
            nodes[leaf_offset + j] = leafDigestGoldilocksPair(lo, hi);
        }

        var idx: usize = leaf_offset;
        while (idx > 0) {
            idx -= 1;
            nodes[idx] = hashNode(nodes[2 * idx + 1], nodes[2 * idx + 2]);
        }

        return .{ .nodes = nodes, .leaf_count = m };
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
        if (leaf_idx >= self.leaf_count) return Error.IndexOutOfBounds;

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

    /// Recompute root from an already-computed leaf digest.
    pub fn rootFromProofDigest(
        leaf_digest: Digest,
        leaf_idx: usize,
        proof: []const Digest,
    ) Digest {
        var hash = leaf_digest;
        var idx = leaf_idx;

        var depth: usize = 0;
        while (depth < proof.len) : (depth += 1) {
            const sibling = proof[depth];
            const even = (idx & 1) == 0;
            hash = if (even) hashNode(hash, sibling) else hashNode(sibling, hash);
            idx >>= 1;
        }

        return hash;
    }

    pub fn rootFromProof(
        leaf: F,
        leaf_idx: usize,
        proof: []const Digest,
    ) Digest {
        return rootFromProofDigest(
            leafDigestGoldilocks(leaf),
            leaf_idx,
            proof,
        );
    }

    pub fn rootFromPairProof(
        lo: F,
        hi: F,
        pair_idx: usize,
        proof: []const Digest,
    ) Digest {
        return rootFromProofDigest(
            leafDigestGoldilocksPair(lo, hi),
            pair_idx,
            proof,
        );
    }
};

test "MerkleTree basic build/open/verify" {
    var leaves_in = [_]F.InnerType{ 1, 2, 3, 4 };
    const leaves: []const F = @ptrCast(&leaves_in);

    var tree = try MerkleTree.build(std.testing.allocator, leaves);
    defer tree.deinit(std.testing.allocator);

    const root = tree.root();

    var proof_buf: [64]Digest = undefined;
    const depth = try tree.open(2, proof_buf[0..]);
    const proof = proof_buf[0..depth];

    const recomputed = MerkleTree.rootFromProof(leaves[2], 2, proof);
    try std.testing.expectEqualSlices(u8, &root, &recomputed);
}

test "MerkleTree pair-leaf open/verify" {
    var leaves_in = [_]F.InnerType{ 1, 2, 3, 4 };
    const leaves: []const F = @ptrCast(&leaves_in);

    var tree = try MerkleTree.buildPairs(std.testing.allocator, leaves[0..]);
    defer tree.deinit(std.testing.allocator);

    const root = tree.root();

    // pair 1 commits to (3,4)
    var proof_buf: [64]Digest = undefined;
    const depth = try tree.open(1, proof_buf[0..]);
    const proof = proof_buf[0..depth];

    const recomputed = MerkleTree.rootFromPairProof(leaves[2], leaves[3], 1, proof);
    try std.testing.expectEqualSlices(u8, &root, &recomputed);
}
