const std = @import("std");

const afri_complex = @import("afri/complex.zig");
const afri_merkle = @import("afri/merkle.zig");
const afri_challenger = @import("afri/challenger.zig");
const afri_afri = @import("afri/afri.zig");
const afri_threads = @import("afri/threads.zig");

const fri_field = @import("fri/field.zig");
const fri_fft = @import("fri/fft.zig");
const fri_challenger = @import("fri/challenger.zig");
const fri_merkle = @import("fri/merkle.zig");
const fri = @import("fri/fri.zig");

test "aggregate" {
    // aFRI.
    _ = afri_complex;
    _ = afri_merkle;
    _ = afri_challenger;
    _ = afri_afri;
    _ = afri_threads;

    // FRI.
    _ = fri_field;
    _ = fri_fft;
    _ = fri_challenger;
    _ = fri_merkle;
    _ = fri;
}
