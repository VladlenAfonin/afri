const std = @import("std");

pub fn isPowerOfTwo(n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

pub inline fn log2Usize(n: usize) usize {
    return std.math.log2_int(usize, n);

    // var x = n;
    // var result: usize = 0;
    // while (x > 1) : (x >>= 1) {
    //     result += 1;
    // }
    // return result;
}

// This seems to work in O(n*log(n)).
pub fn bitReversePermutation(comptime T: type, values: []T) void {
    const n = values.len;
    if (!isPowerOfTwo(n)) {
        @panic("bitReversePermutation: length must be a power of 2");
    }
    const log_n = log2Usize(n);

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

test "bitReversePermutation: sanity check" {
    var array = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    bitReversePermutation(u8, &array);
    const expected = [_]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };
    try std.testing.expect(std.mem.eql(u8, &array, &expected));

    var array2: [16]u8 = undefined;
    for (&array2, 0..) |*a, i| {
        a.* = @intCast(i);
    }
    bitReversePermutation(u8, &array2);
    const expected2 =
        [_]u8{ 0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15 };
    try std.testing.expect(std.mem.eql(u8, &array2, &expected2));
}
