const std = @import("std");
const zbench = @import("zbench");
const stark = @import("stark.zig");

fn contains(target: []const u8, xs: []const []const u8) bool {
    for (xs) |x| {
        if (std.mem.eql(u8, target, x)) return true;
    }
    return false;
}

const Arguments = struct {
    output_style: zbench.OutputStyle = .default,
    party: Party = .prover,
    log_n_from: u6 = 10,
    log_n_to: u6 = 18,
    budget_s: u64 = 2,
    help: bool = false,

    const Self = @This();

    const ParseError = error{
        AllocatorError,
        ExpectedArgument,
        InvalidArgument,
    };

    pub fn parse(args_raw: std.process.Args) ParseError!Self {
        var args = args_raw.iterate();
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

        return result;
    }

    fn parseEnum(comptime T: type, args: *std.process.Args.Iterator) ParseError!T {
        const info = @typeInfo(T);
        if (args.next()) |arg| {
            inline for (info.@"enum".fields) |field| {
                if (std.mem.eql(u8, arg, field.name)) return @enumFromInt(field.value);
            }
        } else {
            return ParseError.ExpectedArgument;
        }

        return ParseError.InvalidArgument;
    }

    fn parseInt(comptime T: type, args: *std.process.Args.Iterator) ParseError!T {
        if (args.next()) |x| {
            return std.fmt.parseInt(T, x, 10) catch ParseError.InvalidArgument;
        }
        return ParseError.ExpectedArgument;
    }

    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.print(
            \\run the STARK benchmarks
            \\
            \\options:
            \\  -h, --help    show this message and exit
            \\  -p, --party   run benchmark for party: prover, verifier  (default: prover)
            \\      --budget  maximum time of one run in seconds  (default: 2)
            \\  -s, --style   output style: default, csv  (default: default)
            \\      --from    min trace length log  (default: 10)
            \\      --to      max trace length log  (default: 18)
            \\
        , .{});
        try writer.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try Arguments.parse(init.minimal.args);
    if (args.help) {
        try Arguments.printHelp(stdout);
        std.process.exit(0);
    }

    var bench = zbench.Benchmark.init(init.gpa, .{
        .time_budget_ns = args.budget_s * std.time.ns_per_s,
        .output_style = args.output_style,
    });
    defer bench.deinit();

    @setEvalBranchQuota(5000);
    const ns = try init.gpa.alloc(u6, args.log_n_to - args.log_n_from + 1);
    defer init.gpa.free(ns);
    for (ns, 0..) |*n, i| {
        n.* = args.log_n_from + @as(u6, @intCast(i));
    }

    var buffer: [1024]u8 = undefined;
    const benchmarks = try init.gpa.alloc(StarkBenchmark, ns.len);
    defer init.gpa.free(benchmarks);
    for (benchmarks, ns, 0..) |*b, n, i| {
        b.* = try StarkBenchmark.init(args.party, init.gpa, n);
        try bench.addParam(
            try std.fmt.bufPrint(
                buffer[i * 8 .. (i + 1) * 8],
                "{}",
                .{n},
            ),
            @as(*const StarkBenchmark, b),
            .{},
        );
    }

    try bench.run(init.io, stdout_file);
    try stdout.flush();

    for (benchmarks) |b| b.deinit();
}

const Party = enum {
    prover,
    verifier,
};

fn counterTransition(_: F, current: []const F, next: []const F) F {
    return next[0].sub(current[0]).sub(F.one);
}

const F = stark.F;
const transitions = [_]stark.TransitionConstraint{counterTransition};

const StarkBenchmark = struct {
    allocator: std.mem.Allocator,
    config: stark.Config,
    trace: []F,
    boundaries: [2]stark.BoundaryConstraint,
    proof: stark.Proof,
    party: Party,

    const Self = @This();

    pub fn init(
        what: Party,
        allocator: std.mem.Allocator,
        log_trace_len: u6,
    ) !Self {
        const trace_len = @as(usize, 1) << log_trace_len;
        const config: stark.Config = .{
            .log_trace_len = log_trace_len,
            .log_blowup = 2,
            .fri_config = .{
                .log_blowup = 2,
                .log_final_poly_len = 0,
                .num_queries = 16,
                .proof_of_work_bits = 0,
                .domain_shift = F.fromComptimeInt(7),
            },
        };

        const trace = try allocator.alloc(F, trace_len);
        errdefer allocator.free(trace);
        for (trace, 0..) |*v, i| v.* = F.fromInner(@intCast(i));

        const boundaries = [2]stark.BoundaryConstraint{
            .{ .row = 0, .column = 0, .value = F.zero },
            .{ .row = trace_len - 1, .column = 0, .value = F.fromInner(@intCast(trace_len - 1)) },
        };
        const bench_air: stark.Air = .{
            .width = 1,
            .transitions = &transitions,
            .boundaries = &boundaries,
        };

        const proof = try stark.prove(allocator, config, bench_air, trace);

        return .{
            .allocator = allocator,
            .config = config,
            .trace = trace,
            .boundaries = boundaries,
            .proof = proof,
            .party = what,
        };
    }

    fn air(self: *const Self) stark.Air {
        return .{
            .width = 1,
            .transitions = &transitions,
            .boundaries = self.boundaries[0..],
        };
    }

    pub fn run(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.party) {
            .prover => self.run_prover(allocator),
            .verifier => self.run_verifier(),
        }
    }

    inline fn run_prover(self: *Self, allocator: std.mem.Allocator) void {
        var proof = stark.prove(allocator, self.config, self.air(), self.trace) catch |e| {
            std.debug.panic("{any}\n", .{e});
        };
        defer proof.deinit(allocator);
        std.mem.doNotOptimizeAway(proof);
    }

    inline fn run_verifier(self: *Self) void {
        const result = stark.verify(self.config, self.air(), &self.proof);
        std.debug.assert(result);
        std.mem.doNotOptimizeAway(result);
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.trace);
        stark.Proof.deinit(@constCast(&self.proof), self.allocator);
    }
};
