const std = @import("std");
const complex = @import("complex.zig");
const merkle = @import("merkle.zig");
const challenger = @import("challenger.zig");
const afri = @import("afri.zig");
const threads = @import("threads.zig");

const fri_field = @import("fri/field.zig");
const fri_fft = @import("fri/fft.zig");
const fri_challenger = @import("fri/challenger.zig");
const fri_merkle = @import("fri/merkle.zig");
const fri = @import("fri/fri.zig");

test "aggregate" {
    // aFRI.
    _ = complex;
    _ = merkle;
    _ = challenger;
    _ = afri;
    _ = threads;

    // FRI.
    _ = fri_field;
    _ = fri_fft;
    _ = fri_challenger;
    _ = fri_merkle;
    _ = fri;
}
