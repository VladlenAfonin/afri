const std = @import("std");

const fri = @import("fri.zig");
const field = @import("field.zig");
const fft = @import("fft.zig");
const utils = @import("utils.zig");
const merkle = @import("merkle.zig");
const challenger_mod = @import("challenger.zig");

pub const F = field.Goldilocks;
const Challenger = challenger_mod.Challenger;
const Digest = merkle.Digest;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const BoundaryConstraint = struct {
    row: usize,
    column: usize,
    value: F,
};

pub const TransitionConstraint = *const fn (
    x: F,
    current: []const F,
    next: []const F,
) F;

pub const Air = struct {
    width: usize,
    transitions: []const TransitionConstraint,
    boundaries: []const BoundaryConstraint,
};

pub const Config = struct {
    log_trace_len: u6,
    log_blowup: u6,
    fri_config: fri.FriConfig,

    pub fn traceLen(self: Config) usize {
        return @as(usize, 1) << self.log_trace_len;
    }

    pub fn evalLen(self: Config) usize {
        return @as(usize, 1) << @intCast(self.log_trace_len + self.log_blowup);
    }
};

pub const TraceOpening = struct {
    row: []F,
    path: []Digest,
};

pub const QueryProof = struct {
    current: TraceOpening,
    next: TraceOpening,
};

pub const Proof = struct {
    trace_root: Digest,
    composition: fri.FriProof,
    queries: []QueryProof,

    _rows_flat: []F,
    _paths_flat: []Digest,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        self.composition.deinit(allocator);
        allocator.free(self.queries);
        allocator.free(self._rows_flat);
        allocator.free(self._paths_flat);
        self.* = undefined;
    }
};

const TraceMerkleTree = struct {
    nodes: []Digest,
    leaf_count: usize,
    width: usize,

    fn build(
        allocator: std.mem.Allocator,
        columns: []const []const F,
    ) !TraceMerkleTree {
        const width = columns.len;
        if (width == 0) return error.EmptyTrace;

        const n = columns[0].len;
        if (n == 0 or !utils.isPowerOfTwo(n)) return error.InvalidTraceLength;
        for (columns) |column| {
            if (column.len != n) return error.InvalidTraceColumnLength;
        }

        const nodes = try allocator.alloc(Digest, 2 * n - 1);
        errdefer allocator.free(nodes);

        const leaf_offset = n - 1;
        var row: usize = 0;
        while (row < n) : (row += 1) {
            nodes[leaf_offset + row] = digestColumnsRow(columns, row);
        }

        var idx = leaf_offset;
        while (idx > 0) {
            idx -= 1;
            nodes[idx] = hashNode(nodes[2 * idx + 1], nodes[2 * idx + 2]);
        }

        return .{
            .nodes = nodes,
            .leaf_count = n,
            .width = width,
        };
    }

    fn deinit(self: *TraceMerkleTree, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        self.nodes = &.{};
        self.leaf_count = 0;
        self.width = 0;
    }

    fn root(self: TraceMerkleTree) Digest {
        return self.nodes[0];
    }

    fn open(self: TraceMerkleTree, leaf_idx: usize, path_out: []Digest) !usize {
        if (leaf_idx >= self.leaf_count) return error.IndexOutOfBounds;

        var idx = self.leaf_count - 1 + leaf_idx;
        var depth: usize = 0;
        while (idx > 0) : (depth += 1) {
            if (depth >= path_out.len) return error.ProofTooShort;
            const sibling = if ((idx & 1) == 0) idx - 1 else idx + 1;
            path_out[depth] = self.nodes[sibling];
            idx = (idx - 1) / 2;
        }
        return depth;
    }
};

fn hashBytes(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

fn hashNode(left: Digest, right: Digest) Digest {
    var buf: [2 * Sha256.digest_length]u8 = undefined;
    @memcpy(buf[0..Sha256.digest_length], &left);
    @memcpy(buf[Sha256.digest_length..][0..Sha256.digest_length], &right);
    return hashBytes(&buf);
}

fn updateField(hasher: *Sha256, x: F) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, x.value, .little);
    hasher.update(&bytes);
}

fn digestColumnsRow(columns: []const []const F, row: usize) Digest {
    var hasher = Sha256.init(.{});
    for (columns) |column| updateField(&hasher, column[row]);

    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn digestRow(row: []const F) Digest {
    var hasher = Sha256.init(.{});
    for (row) |x| updateField(&hasher, x);

    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn rootFromTraceOpening(row: []const F, leaf_idx: usize, path: []const Digest) Digest {
    var h = digestRow(row);
    var idx = leaf_idx;

    var depth: usize = 0;
    while (depth < path.len) : (depth += 1) {
        const sibling = path[depth];
        h = if ((idx & 1) == 0) hashNode(h, sibling) else hashNode(sibling, h);
        idx >>= 1;
    }

    return h;
}

fn observeU64(ch: *Challenger, x: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, x, .little);
    ch.observeBytes(&bytes);
}

fn deriveWeights(config: Config, air: Air, trace_root: Digest, weights: []F) void {
    var ch = Challenger.init();
    ch.observeBytes("stark_v1");
    observeU64(&ch, config.log_trace_len);
    observeU64(&ch, config.log_blowup);
    observeU64(&ch, air.width);
    observeU64(&ch, air.transitions.len);
    observeU64(&ch, air.boundaries.len);
    ch.observeBytes(&trace_root);

    for (air.boundaries) |bc| {
        observeU64(&ch, bc.row);
        observeU64(&ch, bc.column);
        ch.observeField(bc.value);
    }

    for (weights) |*w| w.* = ch.sampleField();
}

fn traceValue(trace: []const F, width: usize, row: usize, column: usize) F {
    return trace[row * width + column];
}

fn traceColumnCoeffs(
    allocator: std.mem.Allocator,
    trace: []const F,
    width: usize,
    column: usize,
    trace_len: usize,
) ![]F {
    const coeffs = try allocator.alloc(F, trace_len);
    errdefer allocator.free(coeffs);

    var row: usize = 0;
    while (row < trace_len) : (row += 1) {
        coeffs[row] = traceValue(trace, width, row, column);
    }

    fft.fftInPlace(coeffs, true);
    return coeffs;
}

fn evalPolyOnCoset(
    allocator: std.mem.Allocator,
    coeffs: []const F,
    n: usize,
    shift: F,
    bitrev: bool,
) ![]F {
    const values = try allocator.alloc(F, n);
    errdefer allocator.free(values);

    var shift_power = F.one;
    var i: usize = 0;
    while (i < coeffs.len) : (i += 1) {
        values[i] = coeffs[i].mul(shift_power);
        shift_power.mulAssign(shift);
    }
    while (i < n) : (i += 1) values[i] = F.zero;

    fft.fftInPlace(values, false);
    if (bitrev) utils.bitReversePermutation(F, values);

    return values;
}

fn evalColumnsOnCoset(
    allocator: std.mem.Allocator,
    columns: []const []const F,
    n: usize,
    shift: F,
    bitrev: bool,
) ![][]F {
    const out = try allocator.alloc([]F, columns.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |column| allocator.free(column);
    }

    for (columns, 0..) |column, i| {
        out[i] = try evalPolyOnCoset(allocator, column, n, shift, bitrev);
        initialized += 1;
    }

    return out;
}

fn freeColumns(allocator: std.mem.Allocator, columns: [][]F) void {
    for (columns) |column| allocator.free(column);
    allocator.free(columns);
}

fn pointForTraceRow(log_trace_len: u6, row: usize) F {
    const trace_len = @as(usize, 1) << log_trace_len;
    std.debug.assert(row < trace_len);
    const omega_trace = F.twoAdicGenerator(log_trace_len);
    return F.pow(omega_trace, @intCast(row));
}

fn cosetPointFromBitrev(log_n: usize, idx_bitrev: usize, shift: F) F {
    const omega = F.twoAdicGenerator(log_n);
    const exponent = utils.bitReverse(idx_bitrev, log_n);
    return shift.mul(F.pow(omega, @intCast(exponent)));
}

fn nextIndexBitrev(log_n: usize, idx_bitrev: usize, step: usize) usize {
    const n = @as(usize, 1) << @intCast(log_n);
    const exponent = utils.bitReverse(idx_bitrev, log_n);
    const next_exponent = (exponent + step) & (n - 1);
    return utils.bitReverse(next_exponent, log_n);
}

fn evalTransitionZerofier(log_trace_len: u6, x: F) F {
    const trace_len = @as(usize, 1) << log_trace_len;
    const omega_trace = F.twoAdicGenerator(log_trace_len);
    const last_root = F.pow(omega_trace, @intCast(trace_len - 1));
    return F.pow(x, @intCast(trace_len)).sub(F.one).div(x.sub(last_root));
}

fn compositionAt(
    config: Config,
    air: Air,
    weights: []const F,
    x: F,
    current: []const F,
    next: []const F,
) F {
    var acc = F.zero;
    var weight_index: usize = 0;

    const transition_z = evalTransitionZerofier(config.log_trace_len, x);
    for (air.transitions) |tc| {
        const q = tc(x, current, next).div(transition_z);
        acc.addAssign(q.mul(weights[weight_index]));
        weight_index += 1;
    }

    for (air.boundaries) |bc| {
        const point = pointForTraceRow(config.log_trace_len, bc.row);
        const q = current[bc.column].sub(bc.value).div(x.sub(point));
        acc.addAssign(q.mul(weights[weight_index]));
        weight_index += 1;
    }

    return acc;
}

fn buildCompositionEvals(
    allocator: std.mem.Allocator,
    config: Config,
    air: Air,
    weights: []const F,
    trace_coset_evals: []const []const F,
) ![]F {
    const eval_len = config.evalLen();
    const width = air.width;
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const blowup = @as(usize, 1) << config.log_blowup;

    const current = try allocator.alloc(F, width);
    defer allocator.free(current);
    const next = try allocator.alloc(F, width);
    defer allocator.free(next);

    const values = try allocator.alloc(F, eval_len);
    errdefer allocator.free(values);

    var idx: usize = 0;
    while (idx < eval_len) : (idx += 1) {
        const next_idx = nextIndexBitrev(log_eval_len, idx, blowup);
        for (current, 0..) |*v, col| v.* = trace_coset_evals[col][idx];
        for (next, 0..) |*v, col| v.* = trace_coset_evals[col][next_idx];

        const x = cosetPointFromBitrev(
            log_eval_len,
            idx,
            config.fri_config.domain_shift,
        );
        values[idx] = compositionAt(config, air, weights, x, current, next);
    }

    return values;
}

fn projectToTraceDegreeInPlace(config: Config, values_bitrev: []F) void {
    std.debug.assert(values_bitrev.len == config.evalLen());

    utils.bitReversePermutation(F, values_bitrev);
    fft.fftInPlace(values_bitrev, true);

    const degree_bound = config.traceLen();
    for (values_bitrev[degree_bound..]) |*c| c.* = F.zero;

    fft.fftInPlace(values_bitrev, false);
    utils.bitReversePermutation(F, values_bitrev);
}

fn validateInputs(config: Config, air: Air, trace: []const F) bool {
    if (air.width == 0) return false;
    if (trace.len != config.traceLen() * air.width) return false;
    if (config.log_blowup == 0) return false;
    if (!config.fri_config.domain_shift.neq(F.zero)) return false;
    if (config.fri_config.log_blowup != config.log_blowup) return false;
    if (config.fri_config.log_final_poly_len > config.log_trace_len + config.log_blowup) return false;

    for (air.boundaries) |bc| {
        if (bc.row >= config.traceLen()) return false;
        if (bc.column >= air.width) return false;
    }

    return true;
}

pub fn prove(
    allocator: std.mem.Allocator,
    config: Config,
    air: Air,
    trace: []const F,
) !Proof {
    std.debug.assert(validateInputs(config, air, trace));

    const trace_len = config.traceLen();
    const eval_len = config.evalLen();
    const width = air.width;
    const n_quotients = air.transitions.len + air.boundaries.len;

    var trace_coeffs = try allocator.alloc([]F, width);
    defer allocator.free(trace_coeffs);
    var initialized_coeffs: usize = 0;
    defer {
        for (trace_coeffs[0..initialized_coeffs]) |coeffs| allocator.free(coeffs);
    }

    for (trace_coeffs, 0..) |*coeffs, col| {
        coeffs.* = try traceColumnCoeffs(allocator, trace, width, col, trace_len);
        initialized_coeffs += 1;
    }

    const trace_coset_evals = try evalColumnsOnCoset(
        allocator,
        trace_coeffs,
        eval_len,
        config.fri_config.domain_shift,
        true,
    );
    defer freeColumns(allocator, trace_coset_evals);

    var trace_tree = try TraceMerkleTree.build(allocator, trace_coset_evals);
    defer trace_tree.deinit(allocator);
    const trace_root = trace_tree.root();

    const weights = try allocator.alloc(F, n_quotients);
    defer allocator.free(weights);
    deriveWeights(config, air, trace_root, weights);

    const composition_evals = try buildCompositionEvals(
        allocator,
        config,
        air,
        weights,
        trace_coset_evals,
    );
    defer allocator.free(composition_evals);
    projectToTraceDegreeInPlace(config, composition_evals);

    var composition_proof = try fri.prove(allocator, config.fri_config, composition_evals);
    errdefer composition_proof.deinit(allocator);

    const query_count = composition_proof.queries.len;
    const path_len = utils.log2Usize(eval_len);

    const queries = try allocator.alloc(QueryProof, query_count);
    errdefer allocator.free(queries);

    const rows_flat = try allocator.alloc(F, query_count * 2 * width);
    errdefer allocator.free(rows_flat);

    const paths_flat = try allocator.alloc(Digest, query_count * 2 * path_len);
    errdefer allocator.free(paths_flat);

    var row_cursor: usize = 0;
    var path_cursor: usize = 0;
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const blowup = @as(usize, 1) << config.log_blowup;

    for (composition_proof.queries, 0..) |q, qi| {
        const current_idx: usize = q.idx0;
        const next_idx = nextIndexBitrev(log_eval_len, current_idx, blowup);

        const current_row = rows_flat[row_cursor .. row_cursor + width];
        row_cursor += width;
        for (current_row, 0..) |*v, col| v.* = trace_coset_evals[col][current_idx];

        const current_path = paths_flat[path_cursor .. path_cursor + path_len];
        path_cursor += path_len;
        const current_depth = try trace_tree.open(current_idx, current_path);
        std.debug.assert(current_depth == path_len);

        const next_row = rows_flat[row_cursor .. row_cursor + width];
        row_cursor += width;
        for (next_row, 0..) |*v, col| v.* = trace_coset_evals[col][next_idx];

        const next_path = paths_flat[path_cursor .. path_cursor + path_len];
        path_cursor += path_len;
        const next_depth = try trace_tree.open(next_idx, next_path);
        std.debug.assert(next_depth == path_len);

        queries[qi] = .{
            .current = .{ .row = current_row, .path = current_path },
            .next = .{ .row = next_row, .path = next_path },
        };
    }

    return .{
        .trace_root = trace_root,
        .composition = composition_proof,
        .queries = queries,
        ._rows_flat = rows_flat,
        ._paths_flat = paths_flat,
    };
}

pub fn verify(
    config: Config,
    air: Air,
    proof: *const Proof,
) bool {
    if (air.width == 0) return false;
    if (config.log_blowup == 0) return false;
    if (!config.fri_config.domain_shift.neq(F.zero)) return false;
    if (config.fri_config.log_blowup != config.log_blowup) return false;

    const eval_len = config.evalLen();
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const path_len = utils.log2Usize(eval_len);
    const blowup = @as(usize, 1) << config.log_blowup;
    const n_quotients = air.transitions.len + air.boundaries.len;

    if (proof.queries.len != proof.composition.queries.len) return false;
    if (proof._rows_flat.len != proof.queries.len * 2 * air.width) return false;
    if (proof._paths_flat.len != proof.queries.len * 2 * path_len) return false;

    for (air.boundaries) |bc| {
        if (bc.row >= config.traceLen()) return false;
        if (bc.column >= air.width) return false;
    }

    if (!fri.verify(config.fri_config, &proof.composition, log_eval_len)) return false;

    var weights_buf: [64]F = undefined;
    if (n_quotients > weights_buf.len) return false;
    const weights = weights_buf[0..n_quotients];
    deriveWeights(config, air, proof.trace_root, weights);

    for (proof.composition.queries, proof.queries) |composition_query, trace_query| {
        if (trace_query.current.row.len != air.width) return false;
        if (trace_query.next.row.len != air.width) return false;
        if (trace_query.current.path.len != path_len) return false;
        if (trace_query.next.path.len != path_len) return false;

        const current_idx: usize = composition_query.idx0;
        const next_idx = nextIndexBitrev(log_eval_len, current_idx, blowup);

        const current_root = rootFromTraceOpening(
            trace_query.current.row,
            current_idx,
            trace_query.current.path,
        );
        if (!std.mem.eql(u8, &current_root, &proof.trace_root)) return false;

        const next_root = rootFromTraceOpening(
            trace_query.next.row,
            next_idx,
            trace_query.next.path,
        );
        if (!std.mem.eql(u8, &next_root, &proof.trace_root)) return false;

        const x = cosetPointFromBitrev(
            log_eval_len,
            current_idx,
            config.fri_config.domain_shift,
        );
        const expected = compositionAt(
            config,
            air,
            weights,
            x,
            trace_query.current.row,
            trace_query.next.row,
        );
        if (expected.neq(composition_query.value0)) return false;
    }

    return true;
}

fn counterTransition(_: F, current: []const F, next: []const F) F {
    return next[0].sub(current[0]).sub(F.one);
}

fn factorialCounterTransition(_: F, current: []const F, next: []const F) F {
    return next[0].sub(current[0]).sub(F.one);
}

fn factorialValueTransition(_: F, current: []const F, next: []const F) F {
    return next[1].sub(current[1].mul(next[0]));
}

fn testConfig(log_trace_len: u6) Config {
    return .{
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
}

fn makeCounterTrace(allocator: std.mem.Allocator, trace_len: usize) ![]F {
    const trace = try allocator.alloc(F, trace_len);
    errdefer allocator.free(trace);
    for (trace, 0..) |*v, i| v.* = F.fromInner(@intCast(i));
    return trace;
}

fn makeFactorialTrace(allocator: std.mem.Allocator, n: usize) ![]F {
    const trace_len = n + 1;
    const width = 2;
    const trace = try allocator.alloc(F, trace_len * width);
    errdefer allocator.free(trace);

    trace[0] = F.zero;
    trace[1] = F.one;

    var acc = F.one;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const x = F.fromInner(@intCast(i));
        acc.mulAssign(x);
        trace[i * width] = x;
        trace[i * width + 1] = acc;
    }

    return trace;
}

test "stark proves and verifies counter AIR" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = F.zero },
        .{ .row = trace_len - 1, .column = 0, .value = F.fromInner(@intCast(trace_len - 1)) },
    };
    const air: Air = .{
        .width = 1,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeCounterTrace(allocator, trace_len);
    defer allocator.free(trace);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    try std.testing.expect(verify(cfg, air, &proof));
}

test "stark rejects invalid counter trace" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = F.zero },
        .{ .row = trace_len - 1, .column = 0, .value = F.fromInner(@intCast(trace_len - 1)) },
    };
    const air: Air = .{
        .width = 1,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeCounterTrace(allocator, trace_len);
    defer allocator.free(trace);
    trace[3] = F.fromComptimeInt(99);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    try std.testing.expect(!verify(cfg, air, &proof));
}

test "stark rejects spoiled trace opening" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = F.zero },
        .{ .row = trace_len - 1, .column = 0, .value = F.fromInner(@intCast(trace_len - 1)) },
    };
    const air: Air = .{
        .width = 1,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeCounterTrace(allocator, trace_len);
    defer allocator.free(trace);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    proof.queries[0].current.row[0].addAssign(F.one);
    try std.testing.expect(!verify(cfg, air, &proof));
}

test "stark rejects spoiled FRI proof" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = F.zero },
        .{ .row = trace_len - 1, .column = 0, .value = F.fromInner(@intCast(trace_len - 1)) },
    };
    const air: Air = .{
        .width = 1,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeCounterTrace(allocator, trace_len);
    defer allocator.free(trace);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    proof.composition.queries[0].steps[0].sibling_value.addAssign(F.one);
    try std.testing.expect(!verify(cfg, air, &proof));
}

test "stark proves and verifies factorial AIR" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const n = cfg.traceLen() - 1;

    const transitions = [_]TransitionConstraint{
        factorialCounterTransition,
        factorialValueTransition,
    };
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = F.zero },
        .{ .row = 0, .column = 1, .value = F.one },
        .{ .row = n, .column = 0, .value = F.fromInner(@intCast(n)) },
        .{ .row = n, .column = 1, .value = F.fromComptimeInt(5040) },
    };
    const air: Air = .{
        .width = 2,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeFactorialTrace(allocator, n);
    defer allocator.free(trace);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    try std.testing.expect(verify(cfg, air, &proof));
}
