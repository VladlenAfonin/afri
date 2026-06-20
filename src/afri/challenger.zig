const std = @import("std");
const merkle = @import("merkle.zig");
const utils = @import("utils.zig");
const common = @import("common");

const Hash = common.Hash;

pub const Challenger = struct {
    state: [Hash.digest_length]u8,
    counter: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .state = [_]u8{0} ** Hash.digest_length,
            .counter = 0,
        };
    }

    pub fn observeBytes(self: *Self, data: []const u8) void {
        var hasher = Hash.init(.{});
        hasher.update(&self.state);
        const ctr = utils.encode(u64, self.counter, .big);
        hasher.update(&ctr);
        hasher.update(data);

        var out: [Hash.digest_length]u8 = undefined;
        hasher.final(&out);

        self.state = out;
        self.counter += 1;
    }

    pub fn observeDigest(self: *Self, d: merkle.Digest) void {
        self.observeBytes(d[0..]);
    }

    fn squeeze(self: *Self) [Hash.digest_length]u8 {
        var hasher = Hash.init(.{});
        hasher.update(&self.state);
        const ctr = utils.encode(u64, self.counter, .big);
        hasher.update(&ctr);

        var out: [Hash.digest_length]u8 = undefined;
        hasher.final(&out);

        self.state = out;
        self.counter += 1;
        return out;
    }

    pub fn sampleU64(self: *Self) u64 {
        const block = self.squeeze();
        var r: u64 = 0;
        for (block[0..8]) |b| r = (r << 8) | @as(u64, b);
        return r;
    }

    pub fn sampleU32(self: *Self) u32 {
        const block = self.squeeze();
        var r: u32 = 0;
        for (block[0..4]) |b| r = (r << 8) | @as(u32, b);
        return r;
    }

    /// Sample an index in [0, n), assuming n is a power of two.
    pub fn sampleIndexPow2(self: *Self, n: usize) usize {
        std.debug.assert(n != 0 and (n & (n - 1)) == 0);
        const mask: u64 = @intCast(n - 1);
        return @as(usize, @intCast(self.sampleU64() & mask));
    }

    /// Uniform-ish f32 in [0, 1) derived from u32/2^32.
    pub fn sampleF32Unit(self: *Self) f32 {
        const r = self.sampleU32();
        // 2^32 as f64 to avoid rounding surprises; cast back to f32.
        const x = @as(f64, @floatFromInt(r)) / 4294967296.0;
        return @as(f32, @floatCast(x));
    }

    /// Angle in [0, 2pi).
    pub fn sampleAngleF32(self: *Self) f32 {
        const u = self.sampleF32Unit();
        const tau = std.math.tau; // f64
        const a = tau * @as(f64, @floatCast(u));
        return @as(f32, @floatCast(a));
    }
};

test "Challenger determinism" {
    var c1 = Challenger.init();
    var c2 = Challenger.init();
    var c3 = Challenger.init();

    c1.observeBytes("hello");
    c2.observeBytes("hello");
    c3.observeBytes("biba");

    const a1 = c1.sampleU64();
    const a2 = c2.sampleU64();
    const a3 = c3.sampleU64();
    try std.testing.expectEqual(a1, a2);
    try std.testing.expect(a1 != a3);

    const t1 = c1.sampleAngleF32();
    const t2 = c2.sampleAngleF32();
    const t3 = c3.sampleAngleF32();
    try std.testing.expectApproxEqAbs(t1, t2, 1e-5);
    try std.testing.expect(@abs(t1 - t3) >= 1e-5);
}
