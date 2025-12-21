const std = @import("std");
const zbench = @import("zbench");
const afri = @import("afri.zig");
const complex = @import("complex.zig");

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var bench = zbench.Benchmark.init(allocator, .{
        .time_budget_ns = 30 * std.time.ns_per_s,
    });
    defer bench.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();

    const config: afri.Config = .{
        .log_n = 26,
        .log_final_n = 3,
        .num_queries = 16,
        .delta_fold = 5e-3,
        .delta_final = 5e-3,
        .degree_bound = 8,
    };

    const prover: AfriBenchmark = try .init(.prover, allocator, rng, config);
    const verifier: AfriBenchmark = try .init(.verifier, allocator, rng, config);
    try bench.addParam("aFRI Prover", &prover, .{});
    try bench.addParam("aFRI Verifier", &verifier, .{});

    try bench.run(stdout);
    try stdout.flush();
}

const AfriBenchmark = struct {
    allocator: std.mem.Allocator,
    config: afri.Config,
    f0: []T,
    proof: afri.Proof,
    what: What,

    const Self = @This();
    const T = afri.T;

    const What = enum {
        prover,
        verifier,
    };

    pub fn init(
        comptime what: What,
        allocator: std.mem.Allocator,
        rng: std.Random,
        config: afri.Config,
    ) !Self {
        const n0 = config.n();

        // Build domain points in bitrev order.
        const xs = try complex.makeRootsBitrevAlloc(T, allocator, n0);
        defer allocator.free(xs);

        var coeffs: [8]T = undefined;
        for (&coeffs) |*c| {
            // small coefficients in [-0.5, 0.5].
            const re = (@as(T.InnerType, @floatFromInt(rng.int(u32))) / 4294967296.0) - 0.5;
            const im = (@as(T.InnerType, @floatFromInt(rng.int(u32))) / 4294967296.0) - 0.5;
            c.* = .{ .re = re, .im = im };
        }

        // Evaluate on domain (bitrev order).
        const f0 = try allocator.alloc(T, n0);

        for (f0, xs) |*out, x| {
            out.* = complex.evalPoly(T, &coeffs, x);
        }

        const proof = try afri.prove(allocator, config, f0);

        return AfriBenchmark{
            .allocator = allocator,
            .config = config,
            .f0 = f0,
            .proof = proof,
            .what = what,
        };
    }

    pub fn run(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.what) {
            .prover => self.run_prover(allocator),
            .verifier => self.run_verifier(allocator),
        }
    }

    inline fn run_prover(self: *Self, allocator: std.mem.Allocator) void {
        var proof = afri.prove(allocator, self.config, self.f0) catch @panic("oom");
        defer proof.deinit(allocator);
        std.mem.doNotOptimizeAway(proof);
    }

    inline fn run_verifier(self: *Self, allocator: std.mem.Allocator) void {
        std.mem.doNotOptimizeAway(
            afri.verify(allocator, self.config, self.proof),
        );
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.f0);
        self.proof.deinit(self.allocator);
    }
};
