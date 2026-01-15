const std = @import("std");
const zbench = @import("zbench");
const afri = @import("afri.zig");
const utils = @import("utils.zig");
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
    const benchmarks = try allocator.alloc(AfriBenchmark, ns.len);
    defer allocator.free(benchmarks);
    for (benchmarks, ns, 0..) |*b, n, i| {
        const config: afri.Config = .{
            .log_n = n,
            .log_final_n = 3,
            .num_queries = 16,
            .delta_fold = 5e-3,
            .delta_final = 5e-3,

            // TODO: Allow setting either blowup factor or initial degree log.
            .degree_bound = @divExact(@as(usize, 1) << n, 2), // this sets rho = 1/2
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

        // Begin with coefficients. Free in deinit().
        const f0 = try allocator.alloc(T, n0);
        for (f0[0..@divExact(n0, 2)]) |*c| c.* = T.random(rng);
        for (f0[@divExact(n0, 2)..n0]) |*c| c.* = T.zero;

        utils.bitReversePermute(T, f0);
        afri.fftBitrevInPlace(f0, false);
        utils.bitReversePermute(T, f0);

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
        const result = afri.verify(allocator, self.config, self.proof);
        std.mem.doNotOptimizeAway(result);
        std.debug.assert(result);
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.f0);
        afri.Proof.deinit(@constCast(&self.proof), self.allocator);
    }
};
