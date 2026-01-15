const std = @import("std");
const zbench = @import("zbench");
const fri = @import("fri.zig");
const field_mod = @import("field.zig");
const fft = @import("fft.zig");
const utils = @import("utils.zig");

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
    budget_s: u64 = 2,
    help: bool = false,

    const Self = @This();

    const ParseError = error{
        AllocatorError,
        ExpectedArgument,
        InvalidArgument,
    };

    pub fn parse(allocator: std.mem.Allocator) ParseError!Self {
        var args = std.process.argsWithAllocator(allocator) catch |e| {
            std.debug.panic("unable to allocate memory: {}\n", .{e});
            return ParseError.AllocatorError;
        };
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

            if (contains(arg, &[_][]const u8{"--budget"})) {
                result.budget_s = try parseInt(u64, &args);
            }

            if (contains(arg, &[_][]const u8{ "-h", "help", "-help", "--help" })) {
                result.help = true;
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

    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.print(
            \\run the benchmarks
            \\
            \\options:
            \\  -h, --help    show this message and exit
            \\  -p, --party   run benchmark for party: prover, verifier  (default: prover)
            \\      --budget  maximum time of one run in seconds  (default: 2)
            \\  -s, --style   output style: default, csv  (default: default)
            \\      --from    min degree log  (default: 16)
            \\      --to      max degree log  (default: 26)
            \\
        , .{});
        try writer.flush();
    }
};

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try Arguments.parse(allocator);
    if (args.help) {
        try Arguments.printHelp(stdout);
        std.process.exit(0);
    }

    var bench = zbench.Benchmark.init(allocator, .{
        .time_budget_ns = args.budget_s * std.time.ns_per_s,
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
    const benchmarks = try allocator.alloc(FriBenchmark, ns.len);
    defer allocator.free(benchmarks);
    for (benchmarks, ns, 0..) |*b, n, i| {
        const config = fri.FriConfig{
            .log_blowup = 2,
            .log_final_poly_len = 0,
            .num_queries = 12,
            .proof_of_work_bits = 0,
        };

        b.* = try FriBenchmark.init(args.party, allocator, rng, config, n);
        try bench.addParam(
            try std.fmt.bufPrint(
                buffer[i * 8 .. (i + 1) * 8],
                "{}",
                .{n},
            ),
            @as(*const FriBenchmark, b),
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

const FriBenchmark = struct {
    allocator: std.mem.Allocator,
    config: fri.FriConfig,
    f0: []F,
    log_n0: u6,
    proof: fri.FriProof,
    party: Party,

    const Self = @This();
    const F = fri.F;

    pub fn init(
        what: Party,
        allocator: std.mem.Allocator,
        rng: std.Random,
        config: fri.FriConfig,
        log_n: u6,
    ) !Self {
        const n0 = @as(usize, 1) << log_n;

        // Degree bound we intend: < n0 / 2^log_blowup.
        const blowup = @as(usize, 1) << config.log_blowup;
        const deg_bound: usize = n0 / blowup;
        std.debug.assert(deg_bound > 0);

        // Fill first deg_bound coefficients randomly, rest zero.
        const f0 = try allocator.alloc(F, n0);
        for (f0[0..deg_bound]) |*c| c.* = F.fromInner(rng.int(F.InnerType));
        for (f0[deg_bound..]) |*c| c.* = F.zero;

        // Forward FFT: values become evaluations in normal order.
        // This FFT does the bitrev permutation inside.
        fft.fftInPlace(f0, false);
        utils.bitReversePermutation(F, f0);

        const proof = try fri.prove(allocator, config, f0);

        return FriBenchmark{
            .allocator = allocator,
            .config = config,
            .f0 = f0,
            .log_n0 = log_n,
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
        var proof = fri.prove(allocator, self.config, self.f0) catch |e| {
            std.debug.panic("{any}\n", .{e});
        };
        defer proof.deinit(allocator);
        std.mem.doNotOptimizeAway(proof);
    }

    inline fn run_verifier(self: *Self, _: std.mem.Allocator) void {
        const result = fri.verify(self.config, &self.proof, self.log_n0);
        std.debug.assert(result);
        std.mem.doNotOptimizeAway(result);
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.f0);
        fri.FriProof.deinit(@constCast(&self.proof), self.allocator);
    }
};
