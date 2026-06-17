//! Streebog (GOST 34.11-2018) with the same byte-stream interface shape as
//! std.crypto.hash.sha2.Sha256. The standard writes vector components from
//! right to left; this API accepts ordinary left-to-right byte streams, so
//! blocks and final digests are converted at byte boundaries.

const std = @import("std");

const Block = [block_length]u8;

pub const block_length = 64;
pub const Streebog512 = Streebog(512);
pub const Streebog256 = Streebog(256);

pub fn Streebog(comptime digest_bits: comptime_int) type {
    if (digest_bits != 256 and digest_bits != 512) {
        @compileError("Streebog supports only 256-bit and 512-bit digests");
    }

    return struct {
        const Self = @This();

        pub const block_length = 64;
        pub const digest_length = digest_bits / 8;
        pub const Options = struct {};

        h: Block,
        n: Block,
        sigma: Block,
        buf: Block = undefined,
        buf_len: u8 = 0,

        pub fn init(options: Options) Self {
            _ = options;
            return .{
                .h = if (digest_bits == 512) zero_block else [_]u8{1} ** Self.block_length,
                .n = zero_block,
                .sigma = zero_block,
            };
        }

        pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
            var d = Self.init(options);
            d.update(b);
            d.final(out);
        }

        pub fn update(d: *Self, b: []const u8) void {
            var off: usize = 0;

            if (d.buf_len != 0) {
                const left = Self.block_length - d.buf_len;
                const take = @min(left, b.len);
                @memcpy(d.buf[d.buf_len..][0..take], b[0..take]);
                d.buf_len += @intCast(take);
                off += take;

                if (d.buf_len == Self.block_length) {
                    d.processBytes(&d.buf, Self.block_length);
                    d.buf_len = 0;
                } else {
                    return;
                }
            }

            while (off + Self.block_length <= b.len) : (off += Self.block_length) {
                d.processBytes(b[off..][0..Self.block_length], Self.block_length);
            }

            const rest = b[off..];
            @memcpy(d.buf[0..rest.len], rest);
            d.buf_len = @intCast(rest.len);
        }

        pub fn peek(d: Self) [digest_length]u8 {
            var copy = d;
            return copy.finalResult();
        }

        pub fn final(d: *Self, out: *[digest_length]u8) void {
            var block = zero_block;
            @memcpy(block[0..d.buf_len], d.buf[0..d.buf_len]);
            block[d.buf_len] = 1;
            reverseBlock(&block);

            const len = d.buf_len;
            d.processBlock(&block, len);

            var h = d.h;
            g(&h, &d.n, &zero_block);
            g(&h, &d.sigma, &zero_block);
            reverseBlock(&h);

            if (digest_bits == 512) {
                @memcpy(out, &h);
            } else {
                @memcpy(out, h[32..64]);
            }
        }

        pub fn finalResult(d: *Self) [digest_length]u8 {
            var result: [digest_length]u8 = undefined;
            d.final(&result);
            return result;
        }

        fn processBytes(d: *Self, bytes: *const Block, len: usize) void {
            var block = bytes.*;
            reverseBlock(&block);
            d.processBlock(&block, len);
        }

        fn processBlock(d: *Self, block: *const Block, len: usize) void {
            g(&d.h, block, &d.n);
            addMod512(&d.n, &lengthBlock(len));
            addMod512(&d.sigma, block);
        }
    };
}

fn g(h: *Block, m: *const Block, n: *const Block) void {
    var key = xorBlocks(h, n);
    lps(&key);

    var state = m.*;
    for (round_constants) |c| {
        xorInPlace(&state, &key);
        lps(&state);

        xorInPlace(&key, &c);
        lps(&key);
    }

    xorInPlace(&state, &key);
    xorInPlace(&state, h);
    xorInPlace(&state, m);
    h.* = state;
}

fn lps(block: *Block) void {
    s(block);
    p(block);
    l(block);
}

fn s(block: *Block) void {
    for (block) |*b| {
        b.* = pi[b.*];
    }
}

fn p(block: *Block) void {
    const tmp = block.*;
    for (block, 0..) |*b, i| {
        b.* = tmp[tau[i]];
    }
}

fn l(block: *Block) void {
    var out: Block = undefined;

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const bytes = block[i * 8 ..][0..8];
        const word = std.mem.readInt(u64, bytes, .big);
        var acc: u64 = 0;

        var bit: usize = 0;
        while (bit < 64) : (bit += 1) {
            if (((word >> @intCast(63 - bit)) & 1) != 0) {
                acc ^= a[bit];
            }
        }

        std.mem.writeInt(u64, out[i * 8 ..][0..8], acc, .big);
    }

    block.* = out;
}

fn addMod512(dst: *Block, rhs: *const Block) void {
    var carry: u16 = 0;
    var i: usize = block_length;
    while (i > 0) {
        i -= 1;
        const sum = @as(u16, dst[i]) + rhs[i] + carry;
        dst[i] = @intCast(sum & 0xff);
        carry = sum >> 8;
    }
}

fn lengthBlock(byte_len: usize) Block {
    var out = zero_block;
    const bit_len: u16 = @intCast(byte_len * 8);
    out[62] = @intCast(bit_len >> 8);
    out[63] = @intCast(bit_len & 0xff);
    return out;
}

fn xorBlocks(lhs: *const Block, rhs: *const Block) Block {
    var out: Block = undefined;
    for (&out, lhs, rhs) |*o, l_byte, r_byte| {
        o.* = l_byte ^ r_byte;
    }
    return out;
}

fn xorInPlace(dst: *Block, rhs: *const Block) void {
    for (dst, rhs) |*d, r| {
        d.* ^= r;
    }
}

fn reverseBlock(block: *Block) void {
    std.mem.reverse(u8, block);
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

const zero_block = [_]u8{0} ** block_length;

const pi = [256]u8{
    252, 238, 221, 17,  207, 110, 49,  22,  251, 196, 250, 218, 35,  197, 4,   77,
    233, 119, 240, 219, 147, 46,  153, 186, 23,  54,  241, 187, 20,  205, 95,  193,
    249, 24,  101, 90,  226, 92,  239, 33,  129, 28,  60,  66,  139, 1,   142, 79,
    5,   132, 2,   174, 227, 106, 143, 160, 6,   11,  237, 152, 127, 212, 211, 31,
    235, 52,  44,  81,  234, 200, 72,  171, 242, 42,  104, 162, 253, 58,  206, 204,
    181, 112, 14,  86,  8,   12,  118, 18,  191, 114, 19,  71,  156, 183, 93,  135,
    21,  161, 150, 41,  16,  123, 154, 199, 243, 145, 120, 111, 157, 158, 178, 177,
    50,  117, 25,  61,  255, 53,  138, 126, 109, 84,  198, 128, 195, 189, 13,  87,
    223, 245, 36,  169, 62,  168, 67,  201, 215, 121, 214, 246, 124, 34,  185, 3,
    224, 15,  236, 222, 122, 148, 176, 188, 220, 232, 40,  80,  78,  51,  10,  74,
    167, 151, 96,  115, 30,  0,   98,  68,  26,  184, 56,  130, 100, 159, 38,  65,
    173, 69,  70,  146, 39,  94,  85,  47,  140, 163, 165, 125, 105, 213, 149, 59,
    7,   88,  179, 64,  134, 172, 29,  247, 48,  55,  107, 228, 136, 217, 231, 137,
    225, 27,  131, 73,  76,  63,  248, 254, 141, 83,  170, 144, 202, 216, 133, 97,
    32,  113, 103, 164, 45,  43,  9,   91,  203, 155, 37,  208, 190, 229, 108, 82,
    89,  166, 116, 210, 230, 244, 180, 192, 209, 102, 175, 194, 57,  75,  99,  182,
};

const tau = [64]u8{
    0, 8,  16, 24, 32, 40, 48, 56,
    1, 9,  17, 25, 33, 41, 49, 57,
    2, 10, 18, 26, 34, 42, 50, 58,
    3, 11, 19, 27, 35, 43, 51, 59,
    4, 12, 20, 28, 36, 44, 52, 60,
    5, 13, 21, 29, 37, 45, 53, 61,
    6, 14, 22, 30, 38, 46, 54, 62,
    7, 15, 23, 31, 39, 47, 55, 63,
};

const a = [64]u64{
    0x8e20faa72ba0b470, 0x47107ddd9b505a38, 0xad08b0e0c3282d1c, 0xd8045870ef14980e,
    0x6c022c38f90a4c07, 0x3601161cf205268d, 0x1b8e0b0e798c13c8, 0x83478b07b2468764,
    0xa011d380818e8f40, 0x5086e740ce47c920, 0x2843fd2067adea10, 0x14aff010bdd87508,
    0x0ad97808d06cb404, 0x05e23c0468365a02, 0x8c711e02341b2d01, 0x46b60f011a83988e,
    0x90dab52a387ae76f, 0x486dd4151c3dfdb9, 0x24b86a840e90f0d2, 0x125c354207487869,
    0x092e94218d243cba, 0x8a174a9ec8121e5d, 0x4585254f64090fa0, 0xaccc9ca9328a8950,
    0x9d4df05d5f661451, 0xc0a878a0a1330aa6, 0x60543c50de970553, 0x302a1e286fc58ca7,
    0x18150f14b9ec46dd, 0x0c84890ad27623e0, 0x0642ca05693b9f70, 0x0321658cba93c138,
    0x86275df09ce8aaa8, 0x439da0784e745554, 0xafc0503c273aa42a, 0xd960281e9d1d5215,
    0xe230140fc0802984, 0x71180a8960409a42, 0xb60c05ca30204d21, 0x5b068c651810a89e,
    0x456c34887a3805b9, 0xac361a443d1c8cd2, 0x561b0d22900e4669, 0x2b838811480723ba,
    0x9bcf4486248d9f5d, 0xc3e9224312c8c1a0, 0xeffa11af0964ee50, 0xf97d86d98a327728,
    0xe4fa2054a80b329c, 0x727d102a548b194e, 0x39b008152acb8227, 0x9258048415eb419d,
    0x492c024284fbaec0, 0xaa16012142f35760, 0x550b8e9e21f7a530, 0xa48b474f9ef5dc18,
    0x70a6a56e2440598e, 0x3853dc371220a247, 0x1ca76e95091051ad, 0x0edd37c48a08a6d8,
    0x07e095624504536c, 0x8d70c431ac02a736, 0xc83862965601dd1b, 0x641c314b2b8ee083,
};

const round_constants = [12]Block{
    bytesFromHex("b1085bda1ecadae9ebcb2f81c0657c1f2f6a76432e45d016714eb88d7585c4fc4b7ce09192676901a2422a08a460d31505767436cc744d23dd806559f2a64507"),
    bytesFromHex("6fa3b58aa99d2f1a4fe39d460f70b5d7f3feea720a232b9861d55e0f16b501319ab5176b12d699585cb561c2db0aa7ca55dda21bd7cbcd56e679047021b19bb7"),
    bytesFromHex("f574dcac2bce2fc70a39fc286a3d843506f15e5f529c1f8bf2ea7514b1297b7bd3e20fe490359eb1c1c93a376062db09c2b6f443867adb31991e96f50aba0ab2"),
    bytesFromHex("ef1fdfb3e81566d2f948e1a05d71e4dd488e857e335c3c7d9d721cad685e353fa9d72c82ed03d675d8b71333935203be3453eaa193e837f1220cbebc84e3d12e"),
    bytesFromHex("4bea6bacad4747999a3f410c6ca923637f151c1f1686104a359e35d7800fffbdbfcd1747253af5a3dfff00b723271a167a56a27ea9ea63f5601758fd7c6cfe57"),
    bytesFromHex("ae4faeae1d3ad3d96fa4c33b7a3039c02d66c4f95142a46c187f9ab49af08ec6cffaa6b71c9ab7b40af21f66c2bec6b6bf71c57236904f35fa68407a46647d6e"),
    bytesFromHex("f4c70e16eeaac5ec51ac86febf240954399ec6c7e6bf87c9d3473e33197a93c90992abc52d822c3706476983284a05043517454ca23c4af38886564d3a14d493"),
    bytesFromHex("9b1f5b424d93c9a703e7aa020c6e41414eb7f8719c36de1e89b4443b4ddbc49af4892bcb929b069069d18d2bd1a5c42f36acc2355951a8d9a47f0dd4bf02e71e"),
    bytesFromHex("378f5a541631229b944c9ad8ec165fde3a7d3a1b258942243cd955b7e00d0984800a440bdbb2ceb17b2b8a9aa6079c540e38dc92cb1f2a607261445183235adb"),
    bytesFromHex("abbedea680056f52382ae548b2e4f3f38941e71cff8a78db1fffe18a1b3361039fe76702af69334b7a1e6c303b7652f43698fad1153bb6c374b4c7fb98459ced"),
    bytesFromHex("7bcd9ed0efc889fb3002c6cd635afe94d8fa6bbbebab076120018021148466798a1d71efea48b9caefbacd1d7d476e98dea2594ac06fd85d6bcaa4cd81f32d1b"),
    bytesFromHex("378ee767f11631bad21380b00449b17acda43c32bcdf1d77f82012d430219f9b5d80ef9d1891cc86e71da4aa88e12852faf417d5d9b21b9948bc924af11bd720"),
};

test "GOST 34.11-2018 examples: 512-bit digest" {
    try assertEqualHash(
        Streebog512,
        "1b54d01a4af5b9d5cc3d86d68d285462b19abc2475222f35c085122be4ba1ffa00ad30f8767b3a82384c6574f024c311e2a481332b08ef7f41797891c1646f48",
        "012345678901234567890123456789012345678901234567890123456789012",
    );

    const message = bytesFromHex("d1e520e2e5f2f0e82c20d1f2f0e8e1eee6e820e2edf3f6e82c20e2e5fef2fa20f120eceef0ff20f1f2f0e5ebe0ece820ede020f5f0e0e1f0fbff20efebfaeafb20c8e3eef0e5e2fb");
    try assertEqualHash(
        Streebog512,
        "1e88e62226bfca6f9994f1f2d51569e0daf8475a3b0fe61a5300eee46d961376035fe83549ada2b8620fcd7c496ce5b33f0cb9dddc2b6460143b03dabac9fb28",
        &message,
    );
}

test "GOST 34.11-2018 examples: 256-bit digest" {
    try assertEqualHash(
        Streebog256,
        "9d151eefd8590b89daa6ba6cb74af9275dd051026bb149a452fd84e5e57b5500",
        "012345678901234567890123456789012345678901234567890123456789012",
    );

    const message = bytesFromHex("d1e520e2e5f2f0e82c20d1f2f0e8e1eee6e820e2edf3f6e82c20e2e5fef2fa20f120eceef0ff20f1f2f0e5ebe0ece820ede020f5f0e0e1f0fbff20efebfaeafb20c8e3eef0e5e2fb");
    try assertEqualHash(
        Streebog256,
        "9dd2fe4e90409e5da87f53976d7405b0c0cac628fc669a741d50063c557e8f50",
        &message,
    );
}

test "streaming updates and peek match one-shot hash" {
    const message = "012345678901234567890123456789012345678901234567890123456789012";

    var expected: [Streebog512.digest_length]u8 = undefined;
    Streebog512.hash(message, &expected, .{});

    var h = Streebog512.init(.{});
    h.update(message[0..7]);
    h.update(message[7..55]);
    h.update(message[55..]);

    const peeked = h.peek();
    var actual: [Streebog512.digest_length]u8 = undefined;
    h.final(&actual);

    try std.testing.expectEqualSlices(u8, &expected, &peeked);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
