const std = @import("std");
const field = @import("field.zig");
const utils = @import("utils.zig");

const Goldilocks = field.Goldilocks;
const F = Goldilocks;

/// In-place radix-2 DIT FFT on Goldilocks.
///
/// - `inverse = false`: compute standard DFT over the multiplicative subgroup generated
///   by `Goldilocks.twoAdicGenerator(log_n)`.
/// - `inverse = true`: compute inverse DFT and scale by n^{-1}.
pub fn fftInPlace(values: []F, inverse: bool) void {
    const n = values.len;
    if (n == 0) return;
    if (!utils.isPowerOfTwo(n)) @panic("fftInPlace: length must be a power of 2");

    const log_n = utils.log2Usize(n);
    if (log_n > F.two_adicity) {
        @panic("fftInPlace: domain size exceeds Goldilocks TWO_ADICITY");
    }

    utils.bitReversePermutation(F, values);

    const root = F.twoAdicGenerator(log_n);
    const omega = if (inverse) root.inv() else root;

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len / 2;
        const step = n / len; // exponent for stage root of unity
        const step_inner: F.InnerType = @intCast(step);
        const wlen = F.pow(omega, step_inner);

        var start: usize = 0;
        while (start < n) : (start += len) {
            var w = F.one;
            var j: usize = 0;
            while (j < half) : (j += 1) {
                const u = values[start + j];
                var v = values[start + j + half];
                v.mulAssign(w);

                const t0 = u.add(v);
                const t1 = u.sub(v);

                values[start + j] = t0;
                values[start + j + half] = t1;

                w.mulAssign(wlen);
            }
        }
    }

    if (inverse) {
        const n_inner: F.InnerType = @intCast(n);
        const inv_n = F.fromInner(n_inner).inv();
        for (values) |*x| {
            x.mulAssign(inv_n);
        }
    }
}

// --- test ---

test "fftInPlace: constant vector" {
    var buf_in = [_]F.InnerType{ 1, 1, 1, 1 };
    const buf = @as([]F, @ptrCast(&buf_in));

    fftInPlace(buf, false);

    const expected_in = [_]F.InnerType{ 4, 0, 0, 0 };
    try std.testing.expect(std.mem.eql(
        F.InnerType,
        @ptrCast(buf),
        &expected_in,
    ));
}

test "fftInPlace: inverse" {
    var buf_in = [_]F.InnerType{ 1, 1, 1, 1 };
    const buf = @as([]F, @ptrCast(&buf_in));

    fftInPlace(buf, false);
    fftInPlace(buf, true);

    try std.testing.expect(std.mem.allEqual(
        F.InnerType,
        @ptrCast(buf),
        F.one.value,
    ));
}
