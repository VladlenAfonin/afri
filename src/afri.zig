const std = @import("std");
const complex = @import("complex.zig");
const merkle = @import("merkle.zig");
const challenger_mod = @import("challenger.zig");
const utils = @import("utils.zig");

pub const T = complex.c32;

fn leafDigestPairT(even: T, odd: T) merkle.Digest {
    const n = @sizeOf(T);
    const two_n = 2 * n;

    var buf: [two_n]u8 = undefined;

    const a = even.encode(.little);
    const b = odd.encode(.little);

    @memcpy(buf[0..n], &a);
    @memcpy(buf[n..two_n], &b);

    return merkle.hashBytes(&buf);
}

/// For a pair-leaf row index `row` in [0..n/2),
/// the corresponding x is w^{bitrev(row, log2(n)-1)}.
fn domainPointForRowBitrev(n: usize, row: usize) T {
    std.debug.assert(utils.isPowerOfTwo(n));
    std.debug.assert(n >= 2);

    const log_n = utils.log2(n);
    const log_h = log_n - 1;
    const e = utils.bitReverse(row, log_h);
    const omega = T.root(n);

    return omega.pow(e);
}

/// out[row] = (lo+hi)/2 + (beta/(2*x))*(lo-hi),
/// where x is the domain point for this pair.
fn foldRow(n: usize, row: usize, lo: T, hi: T, beta: T) T {
    const half: T.InnerType = 0.5;

    const x = domainPointForRowBitrev(n, row);
    // Unit circle => x^{-1} = conj(x).
    const inv_x = x.con();

    const avg = lo.add(hi).scale(half);
    const diff = lo.sub(hi); // lo - hi
    const t = beta.mul(inv_x).scale(half).mul(diff); // (beta/(2x))*(lo-hi)
    return avg.add(t);
}

fn foldLayerInPlace(
    n: usize,
    in_vals: []const T, // length n
    out_vals: []T, // length n/2
    beta: T,
) void {
    std.debug.assert(in_vals.len == n);
    std.debug.assert(out_vals.len == n / 2);
    std.debug.assert(n >= 2 and utils.isPowerOfTwo(n));

    var row: usize = 0;
    while (row < n / 2) : (row += 1) {
        const even = in_vals[2 * row];
        const odd = in_vals[2 * row + 1];
        out_vals[row] = foldRow(n, row, even, odd, beta);
    }
}

/// In-place radix-2 DIT FFT.
/// Assumes input is in bit-reversed order; output is in natural order.
/// If inverse=true, computes inverse FFT and divides by n.
pub fn fftBitrevInPlace(xs: []T, inverse: bool) void {
    const n = xs.len;
    std.debug.assert(utils.isPowerOfTwo(n));
    if (n == 1) return;

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang_sign: T.InnerType = if (inverse) -1.0 else 1.0;
        const ang: T.InnerType = ang_sign * std.math.tau / @as(T.InnerType, @floatFromInt(len));
        const wlen = T.cis(ang);

        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = T.one;
            var j: usize = 0;
            while (j < len / 2) : (j += 1) {
                const u = xs[i + j];
                const v = xs[i + j + len / 2].mul(w);
                xs[i + j] = u.add(v);
                xs[i + j + len / 2] = u.sub(v);
                w.mulAssign(wlen);
            }
        }
    }

    if (inverse) {
        const inv_n: T.InnerType = 1.0 / @as(T.InnerType, @floatFromInt(n));
        for (xs) |*z| z.scaleAssign(inv_n);
    }
}

pub const Config = struct {
    log_n: u6,
    log_final_n: u6,
    num_queries: usize,

    /// Approx fold tolerance per round.
    delta_fold: T.InnerType,
    /// Final degree check tolerance (coeff magnitudes beyond bound).
    delta_final: T.InnerType,

    /// Claimed initial degree bound (in coefficient index). Must be < n.
    degree_bound: usize,

    pub fn n(self: Config) usize {
        return @as(usize, 1) << self.log_n;
    }

    pub fn finalN(self: Config) usize {
        return @as(usize, 1) << self.log_final_n;
    }

    pub fn rounds(self: Config) usize {
        std.debug.assert(self.log_n >= self.log_final_n);
        return @as(usize, self.log_n - self.log_final_n);
    }
};

pub const PairOpening = struct {
    even: T,
    odd: T,
    path: []merkle.Digest,
};

pub const QueryProof = struct {
    openings: []PairOpening, // length = rounds()
};

pub const Proof = struct {
    /// Commitments for layers 0..R-1.
    roots: []merkle.Digest, // length = rounds()
    final_evals: []T, // length = finalN()
    queries: []QueryProof, // length = num_queries

    // Backing storage for all paths & openings.
    // These to not be used by the Verifier.
    _openings_flat: []PairOpening,
    _paths_flat: []merkle.Digest,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        allocator.free(self.roots);
        allocator.free(self.final_evals);
        allocator.free(self.queries);
        allocator.free(self._openings_flat);
        allocator.free(self._paths_flat);
        self.* = undefined;
    }
};

pub fn prove(
    allocator: std.mem.Allocator,
    cfg: Config,
    f0_bitrev: []const T,
) !Proof {
    const n0 = cfg.n();
    const n_final = cfg.finalN();
    const rounds_count = cfg.rounds();

    std.debug.assert(f0_bitrev.len == n0);
    std.debug.assert(utils.isPowerOfTwo(n0));
    std.debug.assert(utils.isPowerOfTwo(n_final));
    std.debug.assert(1 <= n_final and n_final <= n0);

    var ch = challenger_mod.Challenger.init();

    // Store layer values and Merkle trees for openings.
    // layers_vals[i] length = n0 >> i, for i=0..R (Rth is final evals).
    var layers_vals = try allocator.alloc([]T, rounds_count + 1);
    defer allocator.free(layers_vals);

    var layers_trees = try allocator.alloc(merkle.MerkleTree, rounds_count);
    defer allocator.free(layers_trees);

    // Copy f0.
    layers_vals[0] = try allocator.alloc(T, n0);
    @memcpy(layers_vals[0], f0_bitrev);

    // Roots to include in proof.
    var roots = try allocator.alloc(merkle.Digest, rounds_count);

    // Betas (not included, derived by transcript).
    var betas = try allocator.alloc(T, rounds_count);
    defer allocator.free(betas);

    // Build commitments and fold forward.
    var i: usize = 0;
    while (i < rounds_count) : (i += 1) {
        const n_i = n0 >> @intCast(i);
        const m_i = n_i / 2; // pair leaves

        // Compute pair leaf digests.
        var leafs = try allocator.alloc(merkle.Digest, m_i);
        defer allocator.free(leafs);

        var row: usize = 0;
        while (row < m_i) : (row += 1) {
            const even = layers_vals[i][2 * row];
            const odd = layers_vals[i][2 * row + 1];
            leafs[row] = leafDigestPairT(even, odd);
        }

        var tree = try merkle.MerkleTree.buildFromLeaves(allocator, leafs);
        layers_trees[i] = tree;
        roots[i] = tree.root();

        // Transcript: observe root, sample beta.
        ch.observeDigest(roots[i]);
        const angle = ch.sampleAngleF32();
        betas[i] = T.cis(angle);

        // Allocate and compute next layer (size halves).
        layers_vals[i + 1] = try allocator.alloc(T, m_i);
        foldLayerInPlace(n_i, layers_vals[i], layers_vals[i + 1], betas[i]);
    }

    // Final evals are layers_vals[R], length = n_fin.
    std.debug.assert(layers_vals[rounds_count].len == n_final);

    // Observe final evals in transcript before sampling queries.
    for (layers_vals[rounds_count]) |z| {
        const b = z.encode(.little);
        ch.observeBytes(&b);
    }

    // Allocate proof containers (flat).
    const queries_count = cfg.num_queries;
    var queries = try allocator.alloc(QueryProof, queries_count);

    // Total number of openings = Q * R.
    const openings_count = queries_count * rounds_count;
    var openings_flat = try allocator.alloc(PairOpening, openings_count);

    // Total number of path digests = sum over layers (Q * depth_i).
    // depth_i = log2(m_i).
    var total_paths: usize = 0;
    i = 0;
    while (i < rounds_count) : (i += 1) {
        const n_i = n0 >> @intCast(i);
        const m_i = n_i / 2;
        total_paths += queries_count * utils.log2(m_i);
    }
    var paths_flat = try allocator.alloc(merkle.Digest, total_paths);

    // Fill query proofs.
    var openings_cursor: usize = 0;
    var paths_cursor: usize = 0;

    var q: usize = 0;
    while (q < queries_count) : (q += 1) {
        // Query index derived from transcript.
        var idx: usize = ch.sampleIndexPow2(n0);

        // Set slice for this query’s openings.
        const q_openings = openings_flat[openings_cursor .. openings_cursor + rounds_count];
        openings_cursor += rounds_count;
        queries[q] = .{ .openings = q_openings };

        // For each layer, open the pair-leaf at (idx >> 1).
        i = 0;
        while (i < rounds_count) : (i += 1) {
            const n_i = n0 >> @intCast(i);
            const m_i = n_i / 2;
            const depth_i = utils.log2(m_i);

            const even_idx = idx & ~@as(usize, 1);
            const pair_idx = idx >> 1;

            const even = layers_vals[i][even_idx];
            const odd = layers_vals[i][even_idx + 1];

            const path = paths_flat[paths_cursor .. paths_cursor + depth_i];
            paths_cursor += depth_i;

            var tmp_buf: [64]merkle.Digest = undefined;
            const got_depth = try layers_trees[i].open(pair_idx, &tmp_buf);
            std.debug.assert(got_depth == depth_i);
            @memcpy(path, tmp_buf[0..depth_i]);

            q_openings[i] = .{ .even = even, .odd = odd, .path = path };

            idx >>= 1;
        }
    }

    // Copy final evals into proof-owned buffer.
    const final_evals = try allocator.alloc(T, n_final);
    @memcpy(final_evals, layers_vals[rounds_count]);

    // Cleanup layer values + trees (proof already contains what it needs).
    i = 0;
    while (i < rounds_count) : (i += 1) {
        layers_trees[i].deinit(allocator);
        allocator.free(layers_vals[i]);
    }
    allocator.free(layers_vals[rounds_count]);

    return .{
        .roots = roots,
        .final_evals = final_evals,
        .queries = queries,
        ._openings_flat = openings_flat,
        ._paths_flat = paths_flat,
    };
}

pub fn verify(
    allocator: std.mem.Allocator,
    cfg: Config,
    proof: Proof,
) bool {
    const n0 = cfg.n();
    const n_fin = cfg.finalN();
    const n_rounds = cfg.rounds();

    if (proof.roots.len != n_rounds) return false;
    if (proof.final_evals.len != n_fin) return false;
    if (proof.queries.len != cfg.num_queries) return false;

    var ch = challenger_mod.Challenger.init();

    // Recompute betas from roots.
    var betas = allocator.alloc(T, n_rounds) catch return false;
    defer allocator.free(betas);

    var i: usize = 0;
    while (i < n_rounds) : (i += 1) {
        ch.observeDigest(proof.roots[i]);
        const angle = ch.sampleAngleF32();
        betas[i] = T.cis(angle);
    }

    // Observe final evals.
    for (proof.final_evals) |z| {
        const b = z.encode(.little);
        ch.observeBytes(&b);
    }

    // Verify queries.
    var q: usize = 0;
    while (q < cfg.num_queries) : (q += 1) {
        var idx: usize = ch.sampleIndexPow2(n0);

        // For fold checks, we need to compare expected next value to actual next layer value.
        i = 0;
        while (i < n_rounds) : (i += 1) {
            const n_i = n0 >> @intCast(i);
            const m_i = n_i / 2;
            const depth_i = utils.log2(m_i);

            const opening_i = proof.queries[q].openings[i];

            if (opening_i.path.len != depth_i) return false;

            const even_idx = idx & ~@as(usize, 1);
            const is_even = (idx == even_idx);
            const pair_idx = idx >> 1;

            // Verify Merkle path against root[i].
            const leaf = leafDigestPairT(opening_i.even, opening_i.odd);
            const recomputed = merkle.MerkleTree.rootFromProofDigest(leaf, pair_idx, opening_i.path);
            if (!std.mem.eql(u8, &recomputed, &proof.roots[i])) return false;

            // Compute expected next.
            const lo = opening_i.even;
            const hi = opening_i.odd;
            const cur = if (is_even) lo else hi;

            const expected_next = foldRow(n_i, pair_idx, lo, hi, betas[i]);

            const next_idx = pair_idx;

            // Actual next layer value.
            const actual_next = if (i + 1 < n_rounds) blk: {
                const opening_next = proof.queries[q].openings[i + 1];
                const next_is_even = (next_idx & 1) == 0;
                break :blk if (next_is_even) opening_next.even else opening_next.odd;
            } else blk: {
                // Final layer is sent openly (bitrev order).
                break :blk proof.final_evals[next_idx];
            };

            // Approx fold consistency.
            // We compare expected_next to the actual next-layer value.
            if (!actual_next.eq(expected_next, cfg.delta_fold)) return false;

            // Move down.
            // `cur` is not directly used further (kept for clarity).
            _ = cur;
            idx = next_idx;
        }
    }

    // Final degree check via IFFT.
    // `final_evals` are in bit-reversed order (by construction of folding).
    // IFFT(bitrev) -> coefficients in natural order.
    var coeffs = allocator.alloc(T, n_fin) catch return false;
    defer allocator.free(coeffs);
    @memcpy(coeffs, proof.final_evals);

    fftBitrevInPlace(coeffs, true);

    // Degree bound after R folds: floor(degree_bound / 2^R).
    const deg_fin = @min(cfg.degree_bound >> @intCast(n_rounds), n_fin);
    var k: usize = deg_fin;
    while (k < n_fin) : (k += 1) {
        if (!coeffs[k].is_zero(cfg.delta_final)) return false;
    }

    return true;
}

test "aFRI accepts low-degree polynomial (small params)" {
    const allocator = std.testing.allocator;

    const cfg: Config = .{
        .log_n = 6, // n = 64
        .log_final_n = 3, // n_fin = 8, R = 3
        .num_queries = 16,
        .delta_fold = 5e-3,
        .delta_final = 5e-3,
        .degree_bound = 8, // deg < 8 initially
    };

    const n0 = cfg.n();

    // Build domain points in bitrev order.
    const xs = try complex.makeRootsBitrevAlloc(T, allocator, n0);
    defer std.testing.allocator.free(xs);

    // Random polynomial coefficients (deterministic seed)
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rnd = prng.random();

    var coeffs: [8]T = undefined;
    for (&coeffs) |*c| {
        // small coefficients in [-0.5, 0.5]
        const re = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        const im = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        c.* = .{ .re = re, .im = im };
    }

    // Evaluate on domain (bitrev order)
    const f0 = try std.testing.allocator.alloc(T, n0);
    defer std.testing.allocator.free(f0);

    for (f0, xs) |*out, x| {
        out.* = complex.evalPoly(T, &coeffs, x);
    }

    var proof = try prove(std.testing.allocator, cfg, f0);
    defer proof.deinit(std.testing.allocator);

    try std.testing.expect(verify(allocator, cfg, proof));
}

test "aFRI rejects if a query opening is tampered (Merkle mismatch or fold mismatch)" {
    const cfg: Config = .{
        .log_n = 6, // n=64
        .log_final_n = 3, // n_fin=8, R=3
        .num_queries = 16,
        .delta_fold = 5e-3,
        .delta_final = 5e-3,
        .degree_bound = 8,
    };

    const n0 = cfg.n();

    // Domain points in bitrev order.
    const xs = try complex.makeRootsBitrevAlloc(T, std.testing.allocator, n0);
    defer std.testing.allocator.free(xs);

    // Deterministic polynomial
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rnd = prng.random();

    var coeffs: [8]T = undefined;
    for (&coeffs) |*c| {
        const re = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        const im = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        c.* = .{ .re = re, .im = im };
    }

    const f0 = try std.testing.allocator.alloc(T, n0);
    defer std.testing.allocator.free(f0);
    for (f0, xs) |*out, x| out.* = complex.evalPoly(T, &coeffs, x);

    var proof = try prove(std.testing.allocator, cfg, f0);
    defer proof.deinit(std.testing.allocator);

    // Sanity: valid proof should verify.
    try std.testing.expect(verify(std.testing.allocator, cfg, proof));

    // Tamper with a single opened value in the very first query, first layer.
    // This should (almost surely) invalidate the Merkle proof for that layer.
    proof.queries[0].openings[0].even.re += 0.1234;

    try std.testing.expect(!verify(std.testing.allocator, cfg, proof));
}

test "aFRI rejects if final layer is tampered (final degree check fails)" {
    // Use a tighter delta_final so that changing a final
    // evaluation breaks the coefficient bound robustly.
    const cfg: Config = .{
        .log_n = 6, // n = 64
        .log_final_n = 3, // n_fin = 8
        .num_queries = 16,
        .delta_fold = 5e-3,
        .delta_final = 1e-4, // tighter final tolerance
        .degree_bound = 8,
    };

    const n0 = cfg.n();

    const xs = try complex.makeRootsBitrevAlloc(T, std.testing.allocator, n0);
    defer std.testing.allocator.free(xs);

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rnd = prng.random();

    var coeffs: [8]T = undefined;
    for (&coeffs) |*c| {
        const re = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        const im = (@as(T.InnerType, @floatFromInt(rnd.int(u32))) / 4294967296.0) - 0.5;
        c.* = .{ .re = re, .im = im };
    }

    const f0 = try std.testing.allocator.alloc(T, n0);
    defer std.testing.allocator.free(f0);
    for (f0, xs) |*out, x| out.* = complex.evalPoly(T, &coeffs, x);

    var proof = try prove(std.testing.allocator, cfg, f0);
    defer proof.deinit(std.testing.allocator);

    // Sanity: valid proof should verify
    try std.testing.expect(verify(std.testing.allocator, cfg, proof));

    // Tamper with one final evaluation entry.
    // Since verifier uses final_evals for the terminal IFFT/degree bound check,
    // this should cause coefficients above the bound to become non-negligible.
    proof.final_evals[0].re += 0.25;

    try std.testing.expect(!verify(std.testing.allocator, cfg, proof));
}
