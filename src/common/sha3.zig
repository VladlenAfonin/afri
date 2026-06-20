//! SHA3 over Keccak-f[1600] with the same byte-stream interface shape as
//! std.crypto.hash.sha2.Sha256. This implementation is deliberately scalar:
//! it does not call Zig's optimized Keccak core and does not use SIMD.

const std = @import("std");

const lane_count = 25;
const state_bytes = 200;

pub const Sha3_224 = Sha3(224);
pub const Sha3_256 = Sha3(256);
pub const Sha3_384 = Sha3(384);
pub const Sha3_512 = Sha3(512);

pub fn Sha3(comptime digest_bits: comptime_int) type {
    if (digest_bits != 224 and digest_bits != 256 and digest_bits != 384 and digest_bits != 512) {
        @compileError("SHA3 supports only 224-bit, 256-bit, 384-bit, and 512-bit digests");
    }

    const digest_len = digest_bits / 8;
    const rate = state_bytes - 2 * digest_len;

    return struct {
        const Self = @This();

        pub const digest_length = digest_len;
        pub const block_length = rate;
        pub const Options = struct {};

        state: [lane_count]u64 = [_]u64{0} ** lane_count,
        buf: [rate]u8 = undefined,
        buf_len: usize = 0,

        pub fn init(options: Options) Self {
            _ = options;
            return .{};
        }

        pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) void {
            var d = Self.init(options);
            d.update(bytes);
            d.final(out);
        }

        pub fn update(d: *Self, bytes: []const u8) void {
            var off: usize = 0;

            if (d.buf_len != 0) {
                const left = Self.block_length - d.buf_len;
                const take = @min(left, bytes.len);
                @memcpy(d.buf[d.buf_len..][0..take], bytes[0..take]);
                d.buf_len += take;
                off += take;

                if (d.buf_len == Self.block_length) {
                    d.absorbBlock(&d.buf);
                    d.buf_len = 0;
                } else {
                    return;
                }
            }

            while (off + Self.block_length <= bytes.len) : (off += Self.block_length) {
                d.absorbBlock(bytes[off..][0..Self.block_length]);
            }

            const rest = bytes[off..];
            @memcpy(d.buf[0..rest.len], rest);
            d.buf_len = rest.len;
        }

        pub fn peek(d: Self) [digest_length]u8 {
            var copy = d;
            return copy.finalResult();
        }

        pub fn final(d: *Self, out: *[digest_length]u8) void {
            var block = [_]u8{0} ** Self.block_length;
            @memcpy(block[0..d.buf_len], d.buf[0..d.buf_len]);
            block[d.buf_len] ^= 0x06;
            block[Self.block_length - 1] ^= 0x80;

            d.absorbBlock(&block);
            d.squeeze(out);
        }

        pub fn finalResult(d: *Self) [digest_length]u8 {
            var result: [digest_length]u8 = undefined;
            d.final(&result);
            return result;
        }

        fn absorbBlock(d: *Self, block: *const [Self.block_length]u8) void {
            var lane: usize = 0;
            while (lane < Self.block_length / 8) : (lane += 1) {
                d.state[lane] ^= std.mem.readInt(u64, block[lane * 8 ..][0..8], .little);
            }
            keccakF1600(&d.state);
        }

        fn squeeze(d: *Self, out: *[digest_length]u8) void {
            for (out, 0..) |*byte, i| {
                const shift: u6 = @intCast(8 * (i % 8));
                byte.* = @intCast((d.state[i / 8] >> shift) & 0xff);
            }
        }
    };
}

fn keccakF1600(state: *[lane_count]u64) void {
    for (round_constants) |rc| {
        var c: [5]u64 = undefined;
        var d: [5]u64 = undefined;

        var x: usize = 0;
        while (x < 5) : (x += 1) {
            c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        }

        x = 0;
        while (x < 5) : (x += 1) {
            d[x] = c[(x + 4) % 5] ^ std.math.rotl(u64, c[(x + 1) % 5], 1);
        }

        x = 0;
        while (x < 5) : (x += 1) {
            var y: usize = 0;
            while (y < 5) : (y += 1) {
                state[x + 5 * y] ^= d[x];
            }
        }

        var b: [lane_count]u64 = undefined;
        var y: usize = 0;
        while (y < 5) : (y += 1) {
            x = 0;
            while (x < 5) : (x += 1) {
                const src = x + 5 * y;
                const dst_x = y;
                const dst_y = (2 * x + 3 * y) % 5;
                b[dst_x + 5 * dst_y] = std.math.rotl(u64, state[src], rho_offsets[src]);
            }
        }

        y = 0;
        while (y < 5) : (y += 1) {
            x = 0;
            while (x < 5) : (x += 1) {
                state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y]);
            }
        }

        state[0] ^= rc;
    }
}

fn bytesFromHex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

fn assertEqualHash(comptime Hash: type, comptime expected_hex: []const u8, input: []const u8) !void {
    var expected = bytesFromHex(expected_hex);
    var actual: [Hash.digest_length]u8 = undefined;
    Hash.hash(input, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

const rho_offsets = [lane_count]u6{
    0,  1,  62, 28, 27,
    36, 44, 6,  55, 20,
    3,  10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2,  61, 56, 14,
};

const round_constants = [24]u64{
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808a,
    0x8000000080008000,
    0x000000000000808b,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008a,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000a,
    0x000000008000808b,
    0x800000000000008b,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800a,
    0x800000008000000a,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
};

test "SHA3 reference vectors" {
    const long = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";

    try assertEqualHash(Sha3_224, "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7", "");
    try assertEqualHash(Sha3_224, "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf", "abc");
    try assertEqualHash(Sha3_224, "543e6868e1666c1a643630df77367ae5a62a85070a51c14cbf665cbc", long);

    try assertEqualHash(Sha3_256, "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a", "");
    try assertEqualHash(Sha3_256, "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", "abc");
    try assertEqualHash(Sha3_256, "916f6061fe879741ca6469b43971dfdb28b1a32dc36cb3254e812be27aad1d18", long);

    try assertEqualHash(Sha3_384, "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004", "");
    try assertEqualHash(Sha3_384, "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25", "abc");
    try assertEqualHash(Sha3_384, "79407d3b5916b59c3e30b09822974791c313fb9ecc849e406f23592d04f625dc8c709b98b43b3852b337216179aa7fc7", long);

    try assertEqualHash(Sha3_512, "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26", "");
    try assertEqualHash(Sha3_512, "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0", "abc");
    try assertEqualHash(Sha3_512, "afebb2ef542e6579c50cad06d2e578f9f8dd6881d7dc824d26360feebf18a4fa73e3261122948efcfd492e74e82e2189ed0fb440d187f382270cb455f21dd185", long);
}

test "SHA3 streaming updates and peek match one-shot hash" {
    const long = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
    const message = long ++ long;

    var expected: [Sha3_256.digest_length]u8 = undefined;
    Sha3_256.hash(message, &expected, .{});

    var h = Sha3_256.init(.{});
    h.update(message[0..1]);
    h.update(message[1..Sha3_256.block_length]);
    h.update(message[Sha3_256.block_length..]);

    const peeked = h.peek();
    var actual: [Sha3_256.digest_length]u8 = undefined;
    h.final(&actual);

    try std.testing.expectEqualSlices(u8, &expected, &peeked);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "SHA3 aligned block finalization" {
    const message = [_]u8{0xa3} ** Sha3_256.block_length;

    var one_shot: [Sha3_256.digest_length]u8 = undefined;
    Sha3_256.hash(&message, &one_shot, .{});

    var h = Sha3_256.init(.{});
    h.update(&message);

    var streaming: [Sha3_256.digest_length]u8 = undefined;
    h.final(&streaming);

    try std.testing.expectEqualSlices(u8, &one_shot, &streaming);
}
