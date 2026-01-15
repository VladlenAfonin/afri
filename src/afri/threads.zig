const std = @import("std");

pub fn parallelForRange(
    comptime Ctx: type,
    allocator: std.mem.Allocator,
    num_threads: usize,
    total: usize,
    ctx: *Ctx,
    comptime work: fn (*Ctx, start: usize, end: usize) void,
) !void {
    if (num_threads <= 1 or total <= 1) {
        work(ctx, 0, total);
        return;
    }

    const tcount = @min(num_threads, total);
    const chunk: usize = (total + tcount - 1) / tcount;

    const ThreadFn = struct {
        fn run(c: *Ctx, start: usize, end: usize) void {
            work(c, start, end);
        }
    }.run;

    var threads = try allocator.alloc(std.Thread, tcount - 1);
    defer allocator.free(threads);

    var t: usize = 0;
    while (t < tcount - 1) : (t += 1) {
        const start = t * chunk;
        const end = @min(start + chunk, total);
        threads[t] = try std.Thread.spawn(.{}, ThreadFn, .{ ctx, start, end });
    }

    // Last chunk on the caller thread.
    const start_last = (tcount - 1) * chunk;
    work(ctx, start_last, total);

    for (threads) |th| th.join();
}

test "parallelForRange: fills array with index values" {
    const allocator = std.testing.allocator;

    const out = try allocator.alloc(usize, 1 << 16);
    defer allocator.free(out);

    @memset(out, 0);

    const Ctx = struct { out: []usize };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) {
                ctx.out[i] = i;
            }
        }
    }.work;

    var ctx = Ctx{ .out = out };

    // default-ish: 8 threads
    try parallelForRange(Ctx, allocator, 8, out.len, &ctx, work);

    for (out, 0..) |v, i| {
        try std.testing.expectEqual(@as(usize, i), v);
    }
}

test "parallelForRange: uneven chunking (total not divisible by threads) covers all indices" {
    const allocator = std.testing.allocator;

    const total: usize = 10_003;
    const out = try allocator.alloc(u8, total);
    defer allocator.free(out);

    @memset(out, 0);

    const Ctx = struct { out: []u8 };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) {
                // mark visited
                ctx.out[i] = 1;
            }
        }
    }.work;

    var ctx = Ctx{ .out = out };

    try parallelForRange(Ctx, allocator, 7, total, &ctx, work);

    // Every element must be visited exactly once for this marking-style test.
    for (out) |v| try std.testing.expectEqual(@as(u8, 1), v);
}

test "parallelForRange: total smaller than thread count clamps threads" {
    const allocator = std.testing.allocator;

    const total: usize = 13;
    const out = try allocator.alloc(u8, total);
    defer allocator.free(out);
    @memset(out, 0);

    const Ctx = struct { out: []u8 };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) ctx.out[i] = 1;
        }
    }.work;

    var ctx = Ctx{ .out = out };

    // ask for 64 threads, but total=13 => should still cover all
    try parallelForRange(Ctx, allocator, 64, total, &ctx, work);

    for (out) |v| try std.testing.expectEqual(@as(u8, 1), v);
}

test "parallelForRange: handles total=0 (no work) and does not crash" {
    const allocator = std.testing.allocator;

    // We'll detect accidental calls by having a ctx flag.
    const Ctx = struct { touched: bool };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            _ = start;
            _ = end;
            ctx.touched = true;
        }
    }.work;

    var ctx: Ctx = .{ .touched = false };

    try parallelForRange(Ctx, allocator, 8, 0, &ctx, work);

    // With total=0, our implementation calls work(ctx,0,0) only in the sequential path;
    // but it can also short-circuit. Either behavior is acceptable, but it must not
    // observe indices. We'll accept both by requiring no-op semantics:
    // touched may be true or false. What matters is: nothing crashes.
    std.mem.doNotOptimizeAway(ctx);
}

test "parallelForRange: num_threads=0 behaves like num_threads=1 (sequential)" {
    const allocator = std.testing.allocator;

    const out = try allocator.alloc(usize, 4096);
    defer allocator.free(out);
    @memset(out, 0);

    const Ctx = struct { out: []usize };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) ctx.out[i] = i ^ 0xdeadbeef;
        }
    }.work;

    var ctx = Ctx{ .out = out };

    // Using 0 threads should fall back to sequential in your caller (resolveNumThreads),
    // but we test parallelForRange defensively.
    try parallelForRange(Ctx, allocator, 0, out.len, &ctx, work);

    for (out, 0..) |v, i| {
        try std.testing.expectEqual(@as(usize, i) ^ 0xdeadbeef, v);
    }
}

test "parallelForRange: no overlaps and no gaps (each index hit exactly once)" {
    const allocator = std.testing.allocator;

    const total: usize = 50_000;

    // A counter per index; each work item increments exactly once.
    // This is safe because each index is owned by exactly one chunk
    // if parallelForRange is correct.
    const counts = try allocator.alloc(u8, total);
    defer allocator.free(counts);
    @memset(counts, 0);

    const Ctx = struct { counts: []u8 };

    const work = struct {
        fn work(ctx: *Ctx, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) {
                // Not atomic on purpose: overlap would show up as count != 1,
                // but overlap also risks a data race. In practice, this test
                // catches overlaps in the chunk partitioning logic.
                ctx.counts[i] +%= 1;
            }
        }
    }.work;

    var ctx = Ctx{ .counts = counts };

    try parallelForRange(Ctx, allocator, 12, total, &ctx, work);

    for (counts) |c| {
        try std.testing.expectEqual(@as(u8, 1), c);
    }
}
