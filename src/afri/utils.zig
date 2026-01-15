const std = @import("std");

pub inline fn isPowerOfTwo(n: usize) bool {
    return n != 0 and (n & (n - 1) == 0);
}

pub inline fn log2(n: usize) usize {
    return std.math.log2_int(usize, n);
}

pub fn bitReverse(n: usize, log_n: usize) usize {
    var x = n;
    var res: usize = 0;
    var i: usize = 0;

    while (i < log_n) : (i += 1) {
        res = (res << 1) | (x & 1);
        x >>= 1;
    }
    return res;
}

pub fn bitReversePermute(comptime T: type, values: []T) void {
    const n = values.len;
    if (!isPowerOfTwo(n)) {
        @panic("bitReversePermutation: length must be a power of 2");
    }
    const log_n = log2(n);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const j = bitReverse(i, log_n);
        if (j > i) {
            const tmp = values[i];
            values[i] = values[j];
            values[j] = tmp;
        }
    }
}

/// Encode primitive type into bytes.
///
/// Supported types:
///   - `f32`
///   - `f64`
///   - `u64`: only big-endian is supported.
pub fn encode(
    comptime T: type,
    x: T,
    comptime endian: std.builtin.Endian,
) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;

    switch (T) {
        // This is only big-endian.
        u64 => {
            comptime if (endian == .little) {
                @compileError("little-endian is not supported for u64");
            };

            var tmp = x;

            var i: usize = 0;
            while (i < 8) : (i += 1) {
                out[7 - i] = @as(u8, @intCast(tmp & 0xff));
                tmp >>= 8;
            }
        },
        f32 => {
            const bits: u32 = @bitCast(x);
            std.mem.writeInt(u32, &out, bits, endian);
        },
        f64 => {
            const bits: u64 = @bitCast(x);
            std.mem.writeInt(u64, &out, bits, endian);
        },
        else => @compileError("not supported type"),
    }

    return out;
}
