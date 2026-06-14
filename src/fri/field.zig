const std = @import("std");

pub const Goldilocks = struct {
    value: InnerType,

    const Self = @This();

    pub const InnerType = u64;
    pub const ExtendedType = u128;

    pub const p: InnerType = 0xFFFF_FFFF_0000_0001;
    const p_ext: ExtendedType = @as(ExtendedType, p);

    pub const zero: Self = .{ .value = 0 };
    pub const one: Self = .{ .value = 1 };

    pub inline fn fromInner(x: InnerType) Self {
        return .{ .value = @mod(x, p) };
    }

    pub inline fn fromComptimeInt(x: comptime_int) Self {
        const reduced = @as(InnerType, @intCast(@mod(x, p)));
        return .{ .value = reduced };
    }

    pub inline fn fromComptimeIntSlice(xs: []const comptime_int) [xs.len]Self {
        var result: [xs.len]Self = undefined;
        inline for (&result, xs) |*r, x| {
            r.* = Self.fromComptimeInt(x);
        }
        return result;
    }

    pub inline fn eq(x: Self, y: Self) bool {
        return x.value == y.value;
    }

    pub inline fn neq(x: Self, y: Self) bool {
        return !x.eq(y);
    }

    pub const inv2: Self = Self.fromComptimeInt((p + 1) / 2);
    pub inline fn halve(a: Self) Self {
        return a.mul(inv2);
    }

    pub fn add(a: Self, b: Self) Self {
        const sum_ext = @as(ExtendedType, a.value) + @as(ExtendedType, b.value);
        const reduced = @as(InnerType, @intCast(sum_ext % p_ext));
        return .{ .value = reduced };
    }

    pub fn sub(a: Self, b: Self) Self {
        // Compute a - b (mod p) as (a + p - b) mod p.
        const diff_ext = (@as(ExtendedType, a.value) + p_ext - @as(ExtendedType, b.value)) % p_ext;
        const reduced = @as(InnerType, @intCast(diff_ext));
        return .{ .value = reduced };
    }

    pub fn mul(a: Self, b: Self) Self {
        const prod_ext = @as(ExtendedType, a.value) * @as(ExtendedType, b.value);
        const reduced = @as(InnerType, @intCast(prod_ext % p_ext));
        return .{ .value = reduced };
    }

    pub fn addAssign(a: *Self, b: Self) void {
        a.* = add(a.*, b);
    }

    pub fn subAssign(a: *Self, b: Self) void {
        a.* = sub(a.*, b);
    }

    pub fn mulAssign(a: *Self, b: Self) void {
        a.* = mul(a.*, b);
    }

    /// Exponentiation by squaring.
    pub fn pow(a: Self, b: InnerType) Self {
        var base = a;
        var exp = b;
        var result = Self.one;

        var first = true;
        while (first or exp != 0) : (exp >>= 1) {
            first = false;
            if ((exp & 1) == 1) {
                result.mulAssign(base);
            }
            if (exp == 0) break;
            base.mulAssign(base);
        }
        return result;
    }

    pub fn inv(a: Self) Self {
        if (a.eq(Self.zero)) @panic("Goldilocks.inv: inverse of zero");
        return .{ .value = invXgcd(a.value) };
    }

    fn invXgcd(x: InnerType) InnerType {
        var r0: ExtendedType = p_ext;
        var r1: ExtendedType = @as(ExtendedType, x);
        var t0: ExtendedType = 0;
        var t1: ExtendedType = 1;
        var n: usize = 0;

        while (r1 != 0) : (n += 1) {
            const q = r0 / r1;
            const qr1 = q * r1;
            const next_r = if (r0 > qr1) r0 - qr1 else qr1 - r0;
            const next_t = t0 + q * t1;

            r0 = r1;
            r1 = next_r;
            t0 = t1;
            t1 = next_t;
        }

        std.debug.assert(r0 == 1);
        std.debug.assert(t0 < p_ext);

        if ((n & 1) == 0) {
            t0 = p_ext - t0;
        }
        return @intCast(t0);
    }

    pub fn div(a: Self, b: Self) Self {
        return mul(a, b.inv());
    }

    // --- Two-adic data for FFT / FRI ---

    /// Largest n such that 2^n divides p-1. For Goldilocks this is 32.
    pub const two_adicity: usize = 32;

    /// Generators of the 2-adic subgroups, taken from Plonky3's Goldilocks.
    ///
    /// The i-th element is a 2^i-th root of unity, and TWO_ADIC_GENERATORS[i+1]^2 = TWO_ADIC_GENERATORS[i].
    pub const two_adic_generators = fromComptimeIntSlice(&[_]comptime_int{
        0x0000000000000001,
        0xffffffff00000000,
        0x0001000000000000,
        0xfffffffeff000001,
        0xefffffff00000001,
        0x00003fffffffc000,
        0x0000008000000000,
        0xf80007ff08000001,
        0xbf79143ce60ca966,
        0x1905d02a5c411f4e,
        0x9d8f2ad78bfed972,
        0x0653b4801da1c8cf,
        0xf2c35199959dfcb6,
        0x1544ef2335d17997,
        0xe0ee099310bba1e2,
        0xf6b2cffe2306baac,
        0x54df9630bf79450e,
        0xabd0a6e8aa3d8a0e,
        0x81281a7b05f9beac,
        0xfbd41c6b8caa3302,
        0x30ba2ecd5e93e76d,
        0xf502aef532322654,
        0x4b2a18ade67246b5,
        0xea9d5a1336fbc98b,
        0x86cdcc31c307e171,
        0x4bbaf5976ecfefd8,
        0xed41d05b78d6e286,
        0x10d78dd8915a171d,
        0x59049500004a4485,
        0xdfa8c93ba46d2666,
        0x7e9bd009b86a0845,
        0x400a7f755588e659,
        0x185629dcda58878c,
    });

    pub fn twoAdicGenerator(bits: usize) Self {
        std.debug.assert(bits <= two_adicity);
        return two_adic_generators[bits];
    }
};

// --- tests ---

fn expectEqual(a: Goldilocks, b: Goldilocks) !void {
    try std.testing.expectEqual(a.value, b.value);
}

fn testOp(
    op: fn (Goldilocks, Goldilocks) Goldilocks,
    comptime op_name: []const u8,
    a: comptime_int,
    b: comptime_int,
    expected: comptime_int,
) !void {
    const A = Goldilocks.fromComptimeInt(a);
    const B = Goldilocks.fromComptimeInt(b);
    const E = Goldilocks.fromComptimeInt(expected);
    const result = op(A, B);
    if (result.neq(E)) {
        std.debug.print("test {s}: {d} {s} {d} = {d} (expected {d})\n", .{
            @typeName(Goldilocks),
            a,
            op_name,
            b,
            result.value,
            E.value,
        });
        return error.TestExpectedEqual;
    }
}

fn testAdd(a: comptime_int, b: comptime_int, expected: comptime_int) !void {
    try testOp(Goldilocks.add, "+", a, b, expected);
}

fn testSub(a: comptime_int, b: comptime_int, expected: comptime_int) !void {
    try testOp(Goldilocks.sub, "-", a, b, expected);
}

fn testMul(a: comptime_int, b: comptime_int, expected: comptime_int) !void {
    try testOp(Goldilocks.mul, "*", a, b, expected);
}

test "Goldilocks fromComptimeIntArray" {
    const xs = [_]comptime_int{ 1, 2, 3, 4, 5 };
    const arr = Goldilocks.fromComptimeIntSlice(&xs);
    try std.testing.expectEqual(@as(usize, 5), arr.len);
    try std.testing.expectEqual(@as(u64, 1), arr[0].value);
    try std.testing.expectEqual(@as(u64, 3), arr[2].value);
}

test "Goldilocks add" {
    try testAdd(3, 5, 8);
    try testAdd(Goldilocks.p - 1, 1, 0);
}

test "Goldilocks sub" {
    try testSub(3, 5, Goldilocks.p - 2);
    try testSub(5, 3, 2);
}

test "Goldilocks mul" {
    try testMul(2, 2, 4);
    try testMul(std.math.maxInt(u64), std.math.maxInt(u64), 18446744056529682436);
}

test "Goldilocks inv * mul" {
    const values = [_]Goldilocks.InnerType{
        1,
        2,
        3,
        5,
        0xffff_ffff,
        0x1_0000_0000,
        Goldilocks.p - 2,
        Goldilocks.p - 1,
    };

    for (values) |value| {
        const a = Goldilocks.fromInner(value);
        const inv_a = a.inv();
        const one = Goldilocks.mul(a, inv_a);
        try expectEqual(one, Goldilocks.one);
    }
}

test "two-adic generator basic sanity" {
    const g1 = Goldilocks.twoAdicGenerator(1);
    const g2 = Goldilocks.twoAdicGenerator(2);
    const g2_sq = Goldilocks.mul(g2, g2);
    try expectEqual(g2_sq, g1);
}
