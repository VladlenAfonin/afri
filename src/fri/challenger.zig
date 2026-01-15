const std = @import("std");
const field = @import("field.zig");

const Goldilocks = field.Goldilocks;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Challenger = struct {
    state: [Sha256.digest_length]u8,
    counter: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .state = [_]u8{0} ** Sha256.digest_length,
            .counter = 0,
        };
    }

    fn encodeCounter(counter: u64) [8]u8 {
        var bytes: [8]u8 = undefined;
        var tmp = counter;
        var i: usize = 0;
        // big-endian
        while (i < 8) : (i += 1) {
            bytes[7 - i] = @as(u8, @intCast(tmp & 0xff));
            tmp >>= 8;
        }
        return bytes;
    }

    pub fn observeBytes(self: *Self, data: []const u8) void {
        var hasher = Sha256.init(.{});
        hasher.update(&self.state);
        const ctr = encodeCounter(self.counter);
        hasher.update(&ctr);
        hasher.update(data);

        var out: [Sha256.digest_length]u8 = undefined;
        hasher.final(&out);

        self.state = out;
        self.counter += 1;
    }

    pub fn observeField(self: *Self, x: Goldilocks) void {
        const bytes = std.mem.asBytes(&x.value);
        self.observeBytes(bytes);
    }

    fn squeeze(self: *Self) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        hasher.update(&self.state);
        const ctr = encodeCounter(self.counter);
        hasher.update(&ctr);

        var out: [Sha256.digest_length]u8 = undefined;
        hasher.final(&out);

        self.state = out;
        self.counter += 1;
        return out;
    }

    pub fn sampleU64(self: *Self) u64 {
        const block = self.squeeze();
        var result: u64 = 0;

        // Read first 8 bytes big-endian.
        // Endianness doesn't matter for uniformity.
        for (block[0..8]) |b| {
            result = (result << 8) | @as(u64, b);
        }

        return result;
    }

    pub fn sampleField(self: *Self) Goldilocks {
        while (true) {
            const r = self.sampleU64();
            const reduced = @as(u64, @intCast(@mod(r, Goldilocks.p)));
            const elem = Goldilocks.fromInner(reduced);
            if (!elem.eq(Goldilocks.zero)) return elem;
        }
    }

    // --- grind ---

    pub fn grind(self: *Self, pow_bits: u8) u64 {
        if (pow_bits == 0) return 0;

        var nonce: u64 = 0;
        while (true) : (nonce += 1) {
            // Possible optimization: move these 3 lines out of the loop, replace them with
            // var h = base;
            // and use this h instead of hasher.
            var hasher = Sha256.init(.{});
            hasher.update(&self.state);
            hasher.update("pow");
            const nonce_bytes = std.mem.asBytes(&nonce);
            hasher.update(nonce_bytes);

            var out: [Sha256.digest_length]u8 = undefined;
            hasher.final(&out);

            if (leadingZeroBits(&out) >= pow_bits) {
                // bind the nonce into the transcript
                self.observeBytes(nonce_bytes);
                return nonce;
            }
        }
    }

    pub fn checkWitnessAndObserve(self: *Self, pow_bits: u8, nonce: u64) bool {
        if (pow_bits == 0) return nonce == 0;

        var hasher = Sha256.init(.{});
        hasher.update(&self.state);
        hasher.update("pow");
        const nonce_bytes = std.mem.asBytes(&nonce);
        hasher.update(nonce_bytes);

        var out: [Sha256.digest_length]u8 = undefined;
        hasher.final(&out);

        if (leadingZeroBits(&out) < pow_bits) return false;

        self.observeBytes(nonce_bytes);
        return true;
    }

    fn leadingZeroBits(d: *const [Sha256.digest_length]u8) u8 {
        var count: u8 = 0;
        for (d.*) |b| {
            if (b == 0) {
                count += 8;
            } else {
                count += @intCast(@clz(b));
                break;
            }
        }
        return count;
    }
};

test "Challenger is deterministic" {
    var ch1 = Challenger.init();
    var ch2 = Challenger.init();

    ch1.observeBytes("hello");
    _ = ch1.grind(1);

    ch2.observeBytes("hello");
    _ = ch2.grind(1);

    const a1 = ch1.sampleField();
    const a2 = ch2.sampleField();

    try std.testing.expectEqual(a1.value, a2.value);
}

test "Challenger grinding test" {
    var ch1: Challenger = .init();

    ch1.observeBytes("hello");
    const nonce = ch1.grind(1);

    var ch2: Challenger = .init();

    ch2.observeBytes("hello");
    try std.testing.expect(ch2.checkWitnessAndObserve(1, nonce));
}
