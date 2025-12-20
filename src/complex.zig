const std = @import("std");
const utils = @import("utils.zig");

pub const c32 = Complex(f32);

pub fn Complex(comptime InnerTypeIn: type) type {
    return struct {
        re: InnerType,
        im: InnerType,

        const Self = @This();
        pub const InnerType = InnerTypeIn;

        pub const zero: Self = .{ .re = 0.0, .im = 0.0 };
        pub const one: Self = .{ .re = 1.0, .im = 0.0 };
        pub const neg_one: Self = .{ .re = -1.0, .im = 0.0 };
        pub const i: Self = .{ .re = 0.0, .im = 1.0 };
        pub const neg_i: Self = .{ .re = 0.0, .im = -1.0 };

        pub inline fn init(re: InnerType, im: InnerType) Self {
            return Self{ .re = re, .im = im };
        }

        pub inline fn add(self: Self, other: Self) Self {
            return Self{
                .re = self.re + other.re,
                .im = self.im + other.im,
            };
        }

        pub fn encode(
            self: Self,
            comptime endian: std.builtin.Endian,
        ) [@sizeOf(Self)]u8 {
            const n = @sizeOf(Self);
            const half_n: comptime_int = comptime @divExact(n, 2);
            var out: [n]u8 = undefined;

            const a = utils.encode(InnerType, self.re, endian);
            const b = utils.encode(InnerType, self.im, endian);

            @memcpy(out[0..half_n], &a);
            @memcpy(out[half_n..n], &b);

            return out;
        }

        pub inline fn cis(theta: InnerType) Self {
            return Self{
                .re = std.math.cos(theta),
                .im = std.math.sin(theta),
            };
        }

        pub fn root(n: usize) Self {
            std.debug.assert(n > 0);
            const nf: InnerType = @floatFromInt(n);
            const theta: InnerType = std.math.tau / nf;
            return cis(theta);
        }

        pub inline fn mul(self: Self, other: Self) Self {
            // (a + bi)*(c + di) = (ac - bd) + (ad + bc)i.
            return Self{
                .re = self.re * other.re - self.im * other.im,
                .im = self.re * other.im + self.im * other.re,
            };
        }

        pub inline fn scaleAssign(self: *Self, s: InnerType) void {
            self.* = self.*.scale(s);
        }

        pub inline fn scale(self: Self, s: InnerType) Self {
            return Self{ .re = self.re * s, .im = self.im * s };
        }

        pub inline fn abs2(self: Self) InnerType {
            return self.re * self.re + self.im * self.im;
        }

        pub inline fn abs(self: Self) InnerType {
            return @sqrt(self.abs2());
        }

        pub inline fn inv(self: Self, tol: InnerType) Self {
            // 1 / (a + bi) = (a - bi) / (a^2 + b^2).
            const denom = self.abs2();
            std.debug.assert(denom > tol * tol);
            return self.con().scale(1.0 / denom);
        }

        pub inline fn is_zero(self: Self, tol: InnerType) bool {
            // |z| <= tol <=> |z|^2 <= tol^2.
            const tol2 = tol * tol;
            return self.abs2() < tol2;
        }

        pub inline fn div(self: Self, other: Self, tol: InnerType) Self {
            // a / b = ab* / |b|^2.
            const den = other.abs2();
            std.debug.assert(den > tol * tol);
            return self.mul(other.con()).scale(1.0 / den);
        }

        pub inline fn con(self: Self) Self {
            return Self{ .re = self.re, .im = -self.im };
        }

        pub inline fn neg(self: Self) Self {
            return Self{ .re = -self.re, .im = -self.im };
        }

        pub inline fn sub(self: Self, other: Self) Self {
            return .{
                .re = self.re - other.re,
                .im = self.im - other.im,
            };
        }

        pub inline fn eq(self: Self, other: Self, tol: InnerType) bool {
            return self.sub(other).is_zero(tol);
        }

        /// Integer power: z^e (e >= 0).
        pub fn pow(self: Self, exp: usize) Self {
            var base = self;
            var e = exp;
            var acc = Self.one;

            while (e != 0) : (e >>= 1) {
                if ((e & 1) == 1) acc = acc.mul(base);
                if (e == 1) break; // minor micro-opt; optional
                base = base.mul(base);
            }
            return acc;
        }
    };
}

fn expectApproxZeroAbs(a: f32, tol: f32) !void {
    try std.testing.expectApproxEqAbs(a, 0.0, tol);
}

fn expectApproxEqAbsComplex(a: c32, b: c32, tol: f32) !void {
    try std.testing.expectApproxEqAbs(a.re, b.re, tol);
    try std.testing.expectApproxEqAbs(a.im, b.im, tol);
}

test "c32: add/sub/neg basics" {
    const tol: f32 = 1e-5;

    const a: c32 = .{ .re = 1.25, .im = -3.5 };
    const b: c32 = .{ .re = -2.0, .im = 4.0 };

    try std.testing.expect(a.eq(a, tol));
    try expectApproxEqAbsComplex(
        a.add(b),
        .{ .re = -0.75, .im = 0.5 },
        tol,
    );
    try expectApproxEqAbsComplex(
        a.sub(b),
        .{ .re = 3.25, .im = -7.5 },
        tol,
    );
    try expectApproxEqAbsComplex(
        a.neg(),
        .{ .re = -1.25, .im = 3.5 },
        tol,
    );

    // a - a = 0.
    try std.testing.expect(a.sub(a).is_zero(tol));
}

test "c32: conjugation identities" {
    const tol: f32 = 1e-5;
    const z: c32 = .{ .re = 3.0, .im = -4.0 };

    // conj(conj(z)) = z.
    try expectApproxEqAbsComplex(z.con().con(), z, tol);

    // z * conj(z) = |z|^2 (purely real, imag ~ 0)
    const prod = z.mul(z.con());
    try expectApproxZeroAbs(prod.im, tol);
    try std.testing.expectApproxEqAbs(prod.re, z.abs2(), tol);
}

test "c32: i*i = -1" {
    const tol: f32 = 1e-5;
    try expectApproxEqAbsComplex(c32.i.mul(c32.i), c32.neg_one, tol);
}

test "c32: division and inverse" {
    const tol: f32 = 1e-5;

    const a: c32 = .{ .re = 2.0, .im = 3.0 };
    const b: c32 = .{ .re = -1.5, .im = 0.25 };

    const q = a.div(b, tol);
    const back = q.mul(b);

    // (a/b) * b = a.
    try expectApproxEqAbsComplex(back, a, 2e-4);

    // inv(b) * b = 1.
    const invb = b.inv(tol);
    const one_back = invb.mul(b);
    try expectApproxEqAbsComplex(one_back, c32.one, 2e-4);
}

test "c32: abs and abs2 relationship" {
    const tol = 1e-5;
    const z: c32 = .{ .re = 0.6, .im = -0.8 };
    const a2 = z.abs2();
    const a = z.abs();

    try expectApproxZeroAbs(a * a - a2, tol);
}

test "c32: root of unity sanity" {
    const tol: f32 = 2e-5;

    // n = 1: exp(2pi*i) = 1
    try expectApproxEqAbsComplex(c32.root(1), c32.one, tol);

    // n = 2: exp(pi i) = -1
    try expectApproxEqAbsComplex(
        c32.root(2),
        .{ .re = -1.0, .im = 0.0 },
        tol,
    );

    // n = 4: exp(π/2 i) = i
    try expectApproxEqAbsComplex(c32.root(4), c32.i, tol);
}

test "c32: w^n = 1" {
    // Trigonometry & repeated multiplications accumulate error in f32.
    const tol: f32 = 2e-4;
    const n: usize = 1024;

    const omega = c32.root(n);
    try expectApproxEqAbsComplex(omega.pow(n), c32.one, tol);

    // abs(omega) = 1.
    try std.testing.expectApproxEqAbs(omega.abs(), 1.0, 1e-5);
}

test "c32: pow sanity" {
    const tol: f32 = 2e-5;
    const z: c32 = .{ .re = 0.3, .im = -0.7 };

    // z^0 = 1.
    try expectApproxEqAbsComplex(z.pow(0), c32.one, tol);

    // z^1 = z.
    try expectApproxEqAbsComplex(z.pow(1), z, tol);

    // z^2 = z*z.
    try expectApproxEqAbsComplex(z.pow(2), z.mul(z), tol);
}

test "encode" {
    const z = c32.init(3.14, 3.14);
    // https://www.h-schmidt.net/FloatConverter/IEEE754.html.
    // Note: encoding is little-endian here.
    const expected = [_]u8{ 0xc3, 0xf5, 0x48, 0x40 } ** 2;
    const result = z.encode(.little);
    try std.testing.expectEqualSlices(u8, &expected, &result);
}
