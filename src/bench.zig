const std = @import("std");
const zbench = @import("zbench");
const afri = @import("afri.zig");
const complex = @import("complex.zig");

fn contains(target: []const u8, xs: []const []const u8) bool {
    for (xs) |x| {
        if (std.mem.eql(u8, target, x)) {
            return true;
        }
    }

    return false;
}

const Arguments = struct {
    output_style: zbench.OutputStyle = .default,
    party: Party = .prover,
    log_n_from: u6 = 16,
    log_n_to: u6 = 26,

    const Self = @This();

    const ParseError = error{
        ExpectedArgument,
        InvalidArgument,
    };

    pub fn parse(allocator: std.mem.Allocator) ParseError!Self {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();

        var result: Arguments = .{};

        while (args.next()) |arg| {
            if (contains(arg, &[_][]const u8{ "-p", "--party" })) {
                result.party = try parseEnum(Party, &args);
            }

            if (contains(arg, &[_][]const u8{ "-s", "--style" })) {
                result.output_style = try parseEnum(zbench.OutputStyle, &args);
            }

            if (contains(arg, &[_][]const u8{"--from"})) {
                result.log_n_from = try parseInt(u6, &args);
            }

            if (contains(arg, &[_][]const u8{"--to"})) {
                result.log_n_to = try parseInt(u6, &args);
            }
        }

        if (result.log_n_from > result.log_n_to) {}

        return result;
    }

    fn parseEnum(comptime T: type, args: *std.process.ArgIterator) ParseError!T {
        const info = @typeInfo(T);
        if (args.next()) |arg| {
            inline for (info.@"enum".fields) |field| {
                if (std.mem.eql(u8, arg, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
        } else {
            return ParseError.ExpectedArgument;
        }

        return ParseError.InvalidArgument;
    }

    fn parseInt(comptime T: type, args: *std.process.ArgIterator) ParseError!T {
        if (args.next()) |x| {
            const value = std.fmt.parseInt(T, x, 10) catch {
                return ParseError.InvalidArgument;
            };

            return value;
        } else {
            return ParseError.ExpectedArgument;
        }
    }
};

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();

    const args = try Arguments.parse(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var bench = zbench.Benchmark.init(allocator, .{
        .time_budget_ns = 2 * std.time.ns_per_s,
        .output_style = args.output_style,
    });
    defer bench.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();

    @setEvalBranchQuota(5000);
    const ns = try allocator.alloc(u6, args.log_n_to - args.log_n_from + 1);
    defer allocator.free(ns);
    for (ns, 0..) |*n, i| {
        n.* = args.log_n_from + @as(u6, @intCast(i));
    }

    var buffer: [1024]u8 = undefined;
    const benchmarks = try allocator.alloc(AfriBenchmark, ns.len);
    defer allocator.free(benchmarks);
    for (benchmarks, ns, 0..) |*b, n, i| {
        const config: afri.Config = .{
            .log_n = n,
            .log_final_n = 3,
            .num_queries = 16,
            .delta_fold = 5e-3,
            .delta_final = 5e-3,
            .degree_bound = 8,
        };

        b.* = try AfriBenchmark.init(args.party, allocator, rng, config);
        try bench.addParam(
            try std.fmt.bufPrint(
                buffer[i * 8 .. (i + 1) * 8],
                "{}",
                .{n},
            ),
            @as(*const AfriBenchmark, b),
            .{},
        );
    }

    try bench.run(stdout);
    try stdout.flush();

    for (benchmarks) |b| b.deinit();
}

const Party = enum {
    prover,
    verifier,
};

const AfriBenchmark = struct {
    allocator: std.mem.Allocator,
    config: afri.Config,
    f0: []T,
    proof: afri.Proof,
    party: Party,

    const Self = @This();
    const T = afri.T;

    pub fn init(
        what: Party,
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
            .party = what,
        };
    }

    pub fn run(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.party) {
            .prover => self.run_prover(allocator),
            .verifier => self.run_verifier(allocator),
        }
    }

    inline fn run_prover(self: *Self, allocator: std.mem.Allocator) void {
        var proof = afri.prove(allocator, self.config, self.f0) catch |e| {
            std.debug.panic("{any}\n", .{e});
        };
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
        afri.Proof.deinit(@constCast(&self.proof), self.allocator);
    }
};
