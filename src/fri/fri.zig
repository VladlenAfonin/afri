const std = @import("std");

const field = @import("field.zig");
const utils = @import("utils.zig");
const fft = @import("fft.zig");
const merkle = @import("merkle.zig");
const challenger_mod = @import("challenger.zig");

pub const F = field.Goldilocks;
const Digest = merkle.Digest;
const MerkleTree = merkle.MerkleTree;
const Challenger = challenger_mod.Challenger;

/// In-place FRI-style binary folding.
///
/// Given values f of length n=2m and a challenge beta, overwrites f[0..m] with:
///   g[i] = f[2i] + beta * f[2i+1].
///
/// Returns a subslice `values[0..n/2]` for convenience.
pub fn foldBinaryInPlace(values: []F, beta: F) []F {
    const n = values.len;
    if (!utils.isPowerOfTwo(n) or n < 2) {
        @panic("foldBinaryInPlace: length must be >= 2 and a power of 2");
    }
    const half = n / 2;

    var i: usize = 0;
    while (i < half) : (i += 1) {
        const even = values[2 * i];
        const odd = values[2 * i + 1];

        var t = odd;
        t.mulAssign(beta);

        var sum = even;
        sum.addAssign(t);

        values[i] = sum;
    }
    return values[0..half];
}

/// Out-of-place binary folding into `out`.
pub fn foldBinary(
    output: []F,
    input: []const F,
    beta: F,
) void {
    const n = input.len;
    if (!utils.isPowerOfTwo(n) or n < 2) {
        @panic("foldBinary: length must be >= 2 and a power of 2");
    }
    const half = n / 2;
    if (output.len < half) @panic("foldBinary: out too small");

    var i: usize = 0;
    while (i < half) : (i += 1) {
        const even = input[2 * i];
        const odd = input[2 * i + 1];

        var t = odd;
        t.mulAssign(beta);

        var sum = even;
        sum.addAssign(t);

        output[i] = sum;
    }
}

/// Fold evaluations of p(x) into evaluations of p_even(x) + beta * p_odd(x).
/// Input `values` must be bit-reversed evaluations on a 2^k subgroup.
/// Output is written into `out` (length = values.len/2), also bit-reversed.
///
/// This matches Plonky3's `fold_even_odd` math.
pub fn foldEvenOddBitrev(out: []F, values: []const F, beta: F) void {
    foldEvenOddBitrevShift(out, values, beta, F.one);
}

/// Fold evaluations over the coset `shift * <omega>`.
/// Input and output are bit-reversed; the next layer lives on
/// `shift^2 * <omega^2>`.
pub fn foldEvenOddBitrevShift(out: []F, values: []const F, beta: F, shift: F) void {
    const n = values.len;
    std.debug.assert(utils.isPowerOfTwo(n));
    std.debug.assert(n >= 2);
    std.debug.assert(out.len == n / 2);

    const log_n = utils.log2Usize(n);
    const out_n = n / 2;

    // Here we construct the array of omega powers sorted in bitreverse.
    const omega_inv = F.twoAdicGenerator(log_n).inv();
    const shift_inv = shift.inv();
    const one_half = F.inv2;
    const half_beta = beta.halve().mul(shift_inv);

    // We need power[i] = (beta/2) * omega_inv^{bitrev(i)} for i in [0..height).
    // Compute sequential powers then bit-reverse the array.
    // Reuse `out` temporarily to hold powers, then overwrite with results.
    var omega_powers = out;
    omega_powers[0] = half_beta;
    var i: usize = 1;
    while (i < out_n) : (i += 1) {
        omega_powers[i] = omega_powers[i - 1].mul(omega_inv);
    }
    utils.bitReversePermutation(F, omega_powers);

    // Now compute:
    // result = (1/2 + power) * lo + (1/2 - power) * hi
    // where (lo, hi) are the paired evaluations p(x), p(-x) in bit-reversed layout.
    i = 0;
    while (i < out_n) : (i += 1) {
        // 2*i because we move by pairs, because values are sorted in bitreverse.
        const lo = values[2 * i];
        const hi = values[2 * i + 1];
        const power = omega_powers[i];

        const a = one_half.add(power);
        const b = one_half.sub(power);

        out[i] = a.mul(lo).add(b.mul(hi));
    }

    // Note: `out` already holds the folded evaluations (bit-reversed).
}

/// Verifier-side: compute a single folded value for a specific row.
/// `row` is the index in the next layer (bit-reversed, size = n/2).
pub fn foldRowBitrev(n: usize, row: usize, lo: F, hi: F, beta: F) F {
    return foldRowBitrevShift(n, row, lo, hi, beta, F.one);
}

/// Verifier-side coset-aware fold for a single row.
pub fn foldRowBitrevShift(n: usize, row: usize, lo: F, hi: F, beta: F, shift: F) F {
    std.debug.assert(utils.isPowerOfTwo(n));
    std.debug.assert(n >= 2);

    const log_n = utils.log2Usize(n);
    const log_h = log_n - 1;

    const omega_inv = F.twoAdicGenerator(log_n).inv();
    const one_half = F.one.halve();
    const half_beta = beta.mul(one_half).mul(shift.inv());

    const e = utils.bitReverse(row, log_h);
    const omega_inv_pow = F.pow(omega_inv, @intCast(e));

    const t = half_beta.mul(omega_inv_pow);
    const a = one_half.add(t);
    const b = one_half.sub(t);

    return a.mul(lo).add(b.mul(hi));
}

pub const FriConfig = struct {
    log_blowup: u6,
    log_final_poly_len: usize, // final codeword length = 1<<log_final_poly_len
    num_queries: usize,
    proof_of_work_bits: u8,
    domain_shift: F = F.one,
};

pub const CommitPhaseStep = struct {
    sibling_value: F,
    path: []Digest, // Merkle path for the PAIR leaf at index_pair = index >> 1
};

pub const QueryProof = struct {
    idx0: u32,
    value0: F, // w0[idx0]
    steps: []CommitPhaseStep, // length = num_layers
};

pub const FriProof = struct {
    roots: []Digest, // length = num_layers
    final_poly: []F, // length = 1 << log_final_poly_len
    pow_witness: u64,
    queries: []QueryProof, // length = num_queries

    pub fn deinit(self: *FriProof, allocator: std.mem.Allocator) void {
        for (self.queries) |q| {
            for (q.steps) |s| allocator.free(s.path);
            allocator.free(q.steps);
        }
        allocator.free(self.queries);
        allocator.free(self.final_poly);
        allocator.free(self.roots);
        self.* = undefined;
    }
};

/// Evaluate polynomial using the Horner scheme.
fn evalPoly(coeffs: []const F, x: F) F {
    var acc = F.zero;
    var i: usize = coeffs.len;
    while (i != 0) {
        i -= 1;
        acc = acc.mul(x).add(coeffs[i]);
    }
    return acc;
}

/// Get the point in the evaluation domain that
/// is to be placed at the `idx_bitrev` index.
///
/// You give this function the bit-reversed index.
fn getOmegaBitrev(log_n: usize, idx_bitrev: usize) F {
    return getCosetPointBitrev(log_n, idx_bitrev, F.one);
}

/// Get the point in `shift * <omega>` at the `idx_bitrev` index.
fn getCosetPointBitrev(log_n: usize, idx_bitrev: usize, shift: F) F {
    const n = @as(usize, 1) << @intCast(log_n);
    std.debug.assert(idx_bitrev < n);

    const omega = F.twoAdicGenerator(log_n);
    const e = utils.bitReverse(idx_bitrev, log_n);
    return shift.mul(F.pow(omega, @intCast(e)));
}

fn squareTimes(x: F, times: usize) F {
    var result = x;
    var i: usize = 0;
    while (i < times) : (i += 1) {
        result.mulAssign(result);
    }
    return result;
}

/// Run the FRI prover for the `evals0_bitrev` bit-reversed array of polynomial evaluations.
pub fn prove(
    allocator: std.mem.Allocator,
    config: FriConfig,
    f0_bitrev: []const F, // length N=2^log_n, in bit-reversed order
) !FriProof {
    // Initial evaluations count.
    const n0 = f0_bitrev.len;
    std.debug.assert(utils.isPowerOfTwo(n0));

    var challenger_ = Challenger.init();
    const challenger = &challenger_;

    // How many times one needs to fold to create a polynomial of size 1.
    const log_n0 = utils.log2Usize(n0);

    // Otherwise nothing can be done.
    std.debug.assert(config.log_final_poly_len <= log_n0);

    const final_len = @as(usize, 1) << @intCast(config.log_final_poly_len);
    const num_layers = log_n0 - config.log_final_poly_len;
    var layer_shift = config.domain_shift;

    // We will commit to layers of size n0, n0/2, ..., 2*final_len.
    // There are num_layers commits and num_layers betas.

    // Domain separation.
    challenger.observeBytes("fri_v1");

    // Allocate roots. Do not clean, because they go into proof.
    var roots = try allocator.alloc(Digest, num_layers);

    // We keep Merkle trees only during proving to open paths.
    var trees = try allocator.alloc(MerkleTree, num_layers);
    defer {
        for (trees) |*t| if (t.leaf_count != 0) t.deinit(allocator);
        allocator.free(trees);
    }

    // Betas (derived from transcript, not stored in proof).
    var betas = try allocator.alloc(F, num_layers);
    defer allocator.free(betas);

    // Also store all layers' evaluations so we can open leaves.
    // By layer we mean evaluations.
    //
    // For simplicity keep all layers' evaluations to answer openings.
    var layers = try allocator.alloc([]F, num_layers + 1);
    defer {
        for (layers) |layer| allocator.free(layer);
        allocator.free(layers);
    }

    const cur = try allocator.alloc(F, n0);
    @memcpy(cur, f0_bitrev);
    layers[0] = cur;

    // Commit/fold loop.
    var li: usize = 0;
    while (li < num_layers) : (li += 1) {
        // Commit to pairs.

        trees[li] = try MerkleTree.buildPairs(allocator, layers[li]);
        roots[li] = trees[li].root();

        challenger.observeBytes(&roots[li]);
        betas[li] = challenger.sampleField();

        const next_len = layers[li].len / 2;
        const next = try allocator.alloc(F, next_len);
        foldEvenOddBitrevShift(next, layers[li], betas[li], layer_shift);
        layer_shift.mulAssign(layer_shift);

        layers[li + 1] = next;
    }

    // Interpolate final polynomial coefficients from final layer evaluations.
    std.debug.assert(layers[num_layers].len == final_len);
    const final_poly = try allocator.alloc(F, final_len);
    @memcpy(final_poly, layers[num_layers]);

    // Convert from bit-reversed eval order to normal, then IFFT to coefficients.
    utils.bitReversePermutation(F, final_poly);
    fft.fftInPlace(final_poly, true);

    // If the final layer is evaluated on a coset, IFFT gives coefficients of
    // p(shift * X). Convert those back to coefficients of p(X).
    const final_shift = squareTimes(config.domain_shift, num_layers);
    var shift_pow = F.one;
    const shift_inv = final_shift.inv();
    var coeff_i: usize = 0;
    while (coeff_i < final_poly.len) : (coeff_i += 1) {
        final_poly[coeff_i].mulAssign(shift_pow);
        shift_pow.mulAssign(shift_inv);
    }

    // Observe final poly into transcript.
    for (final_poly) |c| challenger.observeField(c);

    // Optional PoW grinding before sampling query indices.
    const pow_witness = challenger.grind(config.proof_of_work_bits);

    // Sample query indices (since n0 is power-of-two, use mask for exact uniformity).
    var queries = try allocator.alloc(QueryProof, config.num_queries);

    // Query index.
    var qi: usize = 0;
    while (qi < config.num_queries) : (qi += 1) {
        // For each query go through all of the layers and collect the proper openings.

        // Use masking to avoid modulo bias.
        // n0 is a power of two, so n0 - 1 is like 11111...1.
        // See https://stackoverflow.com/a/10984975 for more info on modulo bias.
        //
        // This also asserts n0 <= 2^32.
        const r = challenger.sampleU64();
        const index0: usize = @intCast(r & (n0 - 1));
        const value0 = layers[0][index0];
        std.debug.assert(index0 < n0);

        // Prepare openings for all layers.
        var steps = try allocator.alloc(CommitPhaseStep, num_layers);

        // Layer index.
        var index = index0;
        li = 0;
        while (li < num_layers) : (li += 1) {
            const size = n0 >> @intCast(li);

            // Since we stop at final_len, last committed size is 2*final_len.
            std.debug.assert(size >= 2);

            const sibling_index = index ^ 1;
            const sibling_value = layers[li][sibling_index];

            const log_size = utils.log2Usize(size);
            const pair_index = @as(usize, index) >> 1;
            const path_len = log_size - 1; // leaf_count = size / 2

            // Do not clean as it goes into the proof.
            const path = try allocator.alloc(Digest, path_len);
            _ = try trees[li].open(pair_index, path);

            steps[li] = .{
                .sibling_value = sibling_value,
                .path = path,
            };

            index = pair_index;
        }

        queries[qi] = .{
            .idx0 = @intCast(index0),
            .value0 = value0,
            .steps = steps,
        };
    }

    return FriProof{
        .roots = roots,
        .final_poly = final_poly,
        .pow_witness = pow_witness,
        .queries = queries,
    };
}

pub fn verify(
    config: FriConfig,
    proof: *const FriProof,
    log_n0: u6,
) bool {
    const n0 = @as(usize, 1) << @intCast(log_n0);
    const final_len = @as(usize, 1) << @intCast(config.log_final_poly_len);
    const num_layers = log_n0 - config.log_final_poly_len;
    const final_shift = squareTimes(config.domain_shift, num_layers);

    if (proof.roots.len != num_layers) return false;
    if (proof.final_poly.len != final_len) return false;
    if (proof.queries.len != config.num_queries) return false;

    var challenger_ = Challenger.init();
    const challenger = &challenger_;

    challenger.observeBytes("fri_v1");

    // Re-derive betas from transcript (roots).
    var betas_buf: [64]F = undefined;
    if (num_layers > betas_buf.len) @panic("increase betas_buf or heap-allocate");
    const betas = betas_buf[0..num_layers];

    var li: usize = 0;
    while (li < num_layers) : (li += 1) {
        challenger.observeBytes(&proof.roots[li]);
        betas[li] = challenger.sampleField();
    }

    // Observe final poly.
    for (proof.final_poly) |c| challenger.observeField(c);

    // Check PoW witness (optional).
    if (!challenger.checkWitnessAndObserve(
        config.proof_of_work_bits,
        proof.pow_witness,
    )) return false;

    // Re-sample indices and verify query proofs in order.
    var qi: usize = 0;
    while (qi < config.num_queries) : (qi += 1) {
        const r = challenger.sampleU64();
        const idx0_expected = @as(u32, @intCast(r & (n0 - 1)));

        const q = proof.queries[qi];
        if (q.idx0 != idx0_expected) return false;
        if (q.steps.len != num_layers) return false;

        // Verify Merkle openings and fold consistency down the chain.
        var folded_eval = q.value0;
        var index = q.idx0;
        var layer_shift = config.domain_shift;

        li = 0;
        while (li < num_layers) : (li += 1) {
            const size = n0 >> @intCast(li);
            const root = proof.roots[li];

            const pair_idx = index >> 1;
            const sibling_value = q.steps[li].sibling_value;

            // Reconstruct the committed pair (lo, hi) in even/odd order.
            const is_even = (index & 1) == 0;
            const lo = if (is_even) folded_eval else sibling_value;
            const hi = if (is_even) sibling_value else folded_eval;

            // Verify Merkle proof for the PAIR leaf at pair_idx.
            const recomputed = MerkleTree.rootFromPairProof(lo, hi, pair_idx, q.steps[li].path);
            if (!std.mem.eql(u8, &recomputed, &root)) return false;

            // Fold to next layer value at index = pair_idx.
            folded_eval = foldRowBitrevShift(size, pair_idx, lo, hi, betas[li], layer_shift);
            layer_shift.mulAssign(layer_shift);
            index = pair_idx;
        }

        // Final polynomial consistency.
        // index is in [0..final_len).
        if (index >= final_len) return false;
        const x = getCosetPointBitrev(config.log_final_poly_len, index, final_shift);
        const y = evalPoly(proof.final_poly, x);
        if (folded_eval.neq(y)) return false;
    }

    return true;
}

test "fri prove/verify roundtrip (pow_bits = 0)" {
    const allocator = std.testing.allocator;

    const log_n0: usize = 10;
    const n0 = 1 << log_n0;

    const config = FriConfig{
        .log_blowup = 2, // included for later; current skeleton may not fully use it
        .log_final_poly_len = 0, // final poly length = 1 (constant)
        .num_queries = 12,
        .proof_of_work_bits = 0,
    };

    // Degree bound we intend: < n0 / 2^log_blowup.
    const blowup = 1 << config.log_blowup;
    const deg_bound: usize = n0 / blowup;
    std.debug.assert(deg_bound > 0);

    // Build random coefficients of length deg_bound, pad to n0 with zeros.
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();

    var coeffs = try allocator.alloc(F, n0);
    defer allocator.free(coeffs);

    // Fill first deg_bound coefficients randomly, rest zero.
    var i: usize = 0;
    while (i < deg_bound) : (i += 1) {
        const r = rng.int(F.InnerType);
        coeffs[i] = F.fromInner(r);
    }
    while (i < n0) : (i += 1) coeffs[i] = F.zero;

    // Evaluate polynomial on subgroup of size n0 using FFT (coeffs -> evals).
    const evals = try allocator.alloc(F, n0);
    defer allocator.free(evals);
    @memcpy(evals, coeffs);

    // Forward FFT: values become evaluations in normal order
    fft.fftInPlace(evals, false);

    // Convert to bit-reversed order (folding expects bit-reversed evals, like Plonky3).
    utils.bitReversePermutation(F, evals);

    // Prove
    var proof = try prove(allocator, config, evals);
    defer proof.deinit(allocator);

    // Verify (fresh challenger, same transcript evolution)
    try std.testing.expect(verify(config, &proof, log_n0));
}

test "fri prove/verify roundtrip (pow_bits = 8)" {
    const allocator = std.testing.allocator;

    const log_n0: usize = 9;
    const n0 = 1 << log_n0;

    const config = FriConfig{
        .log_blowup = 1,
        .log_final_poly_len = 0,
        .num_queries = 8,
        .proof_of_work_bits = 8, // small PoW; should be fast in tests
    };

    const blowup = 1 << config.log_blowup;
    const deg_bound: usize = n0 / blowup;

    var prng = std.Random.DefaultPrng.init(0xdead_beef_cafe_babe);
    const rng = prng.random();

    var coeffs = try allocator.alloc(F, n0);
    defer allocator.free(coeffs);

    var i: usize = 0;
    while (i < deg_bound) : (i += 1) {
        const r = rng.int(F.InnerType);
        coeffs[i] = F.fromInner(r);
    }
    while (i < n0) : (i += 1) coeffs[i] = F.zero;

    const evals = try allocator.alloc(F, n0);
    defer allocator.free(evals);
    @memcpy(evals, coeffs);
    fft.fftInPlace(evals, false);
    utils.bitReversePermutation(F, evals);

    var proof = try prove(allocator, config, evals);
    defer proof.deinit(allocator);

    try std.testing.expect(verify(config, &proof, log_n0));
}

test "fri verification fails if proof is corrupted" {
    const allocator = std.testing.allocator;

    const log_n0: usize = 9;
    const n0: usize = 1 << @intCast(log_n0);

    const config = FriConfig{
        .log_blowup = 1,
        .log_final_poly_len = 0,
        .num_queries = 8,
        .proof_of_work_bits = 0,
    };

    // Simple low-degree polynomial: constant 7
    var coeffs = try allocator.alloc(F, n0);
    defer allocator.free(coeffs);
    coeffs[0] = F.fromComptimeInt(7);
    var i: usize = 1;
    while (i < n0) : (i += 1) coeffs[i] = F.zero;

    const evals = try allocator.alloc(F, n0);
    defer allocator.free(evals);
    @memcpy(evals, coeffs);
    fft.fftInPlace(evals, false);
    utils.bitReversePermutation(F, evals);

    var proof = try prove(allocator, config, evals);
    defer proof.deinit(allocator);

    // Corrupt one opened value in the first query, first layer.
    proof.queries[2].steps[1].sibling_value.addAssign(F.one);

    try std.testing.expect(!verify(config, &proof, log_n0));
}

/// Used for tests.
fn randField(rng: std.Random) F {
    const r = rng.int(u64);
    return F.fromInner(@intCast(@mod(@as(u128, r), @as(u128, F.p))));
}

test "foldEvenOddBitrev matches even+beta*odd evaluations" {
    const log_n: usize = 8;
    const n: usize = 1 << @intCast(log_n);
    const half: usize = n / 2;

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();

    // Random polynomial p(X) with degree < n.
    var coeffs: [n]F = undefined;
    for (&coeffs) |*c| c.* = randField(rng);

    // evals = p evaluated on the 2^log_n subgroup, in normal order.
    var evals = coeffs;
    fft.fftInPlace(&evals, false);

    // Split coefficients into even and odd:
    // p(X) = E(X^2) + X * O(X^2),
    // where E(Y) = Σ a_{2j} Y^j and O(Y) = Σ a_{2j+1} Y^j.
    var even_coeffs: [half]F = undefined;
    var odd_coeffs: [half]F = undefined;
    for (0..half) |i| {
        even_coeffs[i] = coeffs[2 * i];
        odd_coeffs[i] = coeffs[2 * i + 1];
    }

    // Evaluate even() and odd() on the subgroup of size n/2.
    var even_evals = even_coeffs;
    var odd_evals = odd_coeffs;
    fft.fftInPlace(&even_evals, false);
    fft.fftInPlace(&odd_evals, false);

    const beta = randField(rng);

    // expected[i] = even(omega'^i) + beta * odd(omega'^i)
    // where omega' is the (n/2)-th root of unity, i.e. omega^2.
    var expected: [half]F = undefined;
    for (0..half) |i| {
        var t = odd_evals[i];
        t.mulAssign(beta);

        var s = even_evals[i];
        s.addAssign(t);

        expected[i] = s;
    }

    // foldEvenOddBitrev takes and returns bit-reversed evaluations (Plonky3 convention).
    var evals_bitrev = evals;
    utils.bitReversePermutation(F, &evals_bitrev);

    var folded_bitrev: [half]F = undefined;
    foldEvenOddBitrev(&folded_bitrev, &evals_bitrev, beta);

    // Convert back to normal order for comparison.
    utils.bitReversePermutation(F, &folded_bitrev);

    for (0..half) |i| {
        try std.testing.expectEqual(expected[i].value, folded_bitrev[i].value);
    }
}

test "foldEvenOddBitrev on p(X) = X yields constant beta" {
    const log_n: usize = 6;
    const n: usize = 1 << @intCast(log_n);
    const half_n: usize = n / 2;

    var prng = std.Random.DefaultPrng.init(0xbeef_cafe_dead_f00d);
    const rng = prng.random();

    // p(x) = x.
    // This is like [0, 1, 0, 0, 0, ...].
    var coeffs: [n]F = [_]F{F.zero} ** n; //undefined;
    coeffs[1] = F.one;

    // Transform to evaluations.
    fft.fftInPlace(&coeffs, false);

    const beta = randField(rng);

    // Fold.
    utils.bitReversePermutation(F, &coeffs);
    var folded: [half_n]F = undefined;
    foldEvenOddBitrev(&folded, &coeffs, beta);
    utils.bitReversePermutation(F, folded[0..]);

    // For p(x) = x:
    // even(y) = 0, odd(y) = 1 => folded(y) = beta (constant).
    for (folded) |v| {
        try std.testing.expectEqual(beta.value, v.value);
    }
}

test "foldBinaryInPlace sanity" {
    var buf_in = [_]F.InnerType{ 1, 2, 3, 4 };
    const buf: []F = @ptrCast(&buf_in);
    const beta = F.fromComptimeInt(5);

    const out = foldBinaryInPlace(buf, beta);

    // Gets transformed like this:
    // [1, 2, 3, 4] -> [[1, 2], [3, 4]] -> [1 + 2b, 3 + 4b];

    // g[0] = 1 + 5*2 = 11
    // g[1] = 3 + 5*4 = 23
    try std.testing.expectEqual(@as(u64, 11), out[0].value);
    try std.testing.expectEqual(@as(u64, 23), out[1].value);
}
