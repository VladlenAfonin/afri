const std = @import("std");
const common = @import("common");

const afri = @import("afri.zig");
const utils = @import("utils.zig");
const merkle = @import("merkle.zig");
const challenger_mod = @import("challenger.zig");

pub const T = afri.T;
const Challenger = challenger_mod.Challenger;
const Digest = merkle.Digest;
const Hash = common.Hash;

pub const BoundaryConstraint = struct {
    row: usize,
    column: usize,
    value: T,
};

pub const TransitionConstraint = *const fn (
    x: T,
    current: []const T,
    next: []const T,
) T;

pub const Air = struct {
    width: usize,
    transitions: []const TransitionConstraint,
    boundaries: []const BoundaryConstraint,
};

pub const Config = struct {
    log_trace_len: u6,
    log_blowup: u6,
    afri_config: afri.Config,

    /// Tolerance for sampled composition checks in the ASTARK wrapper.
    delta_constraint: T.InnerType,
    /// Tolerance used by complex division in quotient evaluations.
    delta_divisor: T.InnerType,

    pub fn traceLen(self: Config) usize {
        return @as(usize, 1) << self.log_trace_len;
    }

    pub fn evalLen(self: Config) usize {
        return @as(usize, 1) << @intCast(self.log_trace_len + self.log_blowup);
    }
};

pub const TraceOpening = struct {
    row: []T,
    path: []Digest,
};

pub const QueryProof = struct {
    current: TraceOpening,
    next: TraceOpening,
};

pub const Proof = struct {
    trace_root: Digest,
    composition: afri.Proof,
    queries: []QueryProof,

    _rows_flat: []T,
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
        columns: []const []const T,
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
    Hash.hash(bytes, &out, .{});
    return out;
}

fn hashNode(left: Digest, right: Digest) Digest {
    var buf: [2 * Hash.digest_length]u8 = undefined;
    @memcpy(buf[0..Hash.digest_length], &left);
    @memcpy(buf[Hash.digest_length..][0..Hash.digest_length], &right);
    return hashBytes(&buf);
}

fn updateValue(hasher: *Hash, x: T) void {
    const bytes = x.encode(.little);
    hasher.update(&bytes);
}

fn digestColumnsRow(columns: []const []const T, row: usize) Digest {
    var hasher = Hash.init(.{});
    for (columns) |column| updateValue(&hasher, column[row]);

    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn digestRow(row: []const T) Digest {
    var hasher = Hash.init(.{});
    for (row) |x| updateValue(&hasher, x);

    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn rootFromTraceOpening(row: []const T, leaf_idx: usize, path: []const Digest) Digest {
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
    const bytes = utils.encode(u64, x, .big);
    ch.observeBytes(&bytes);
}

fn observeValue(ch: *Challenger, x: T) void {
    const bytes = x.encode(.little);
    ch.observeBytes(&bytes);
}

fn deriveWeights(config: Config, air: Air, trace_root: Digest, weights: []T) void {
    var ch = Challenger.init();
    ch.observeBytes("astark_v1");
    observeU64(&ch, config.log_trace_len);
    observeU64(&ch, config.log_blowup);
    observeU64(&ch, air.width);
    observeU64(&ch, air.transitions.len);
    observeU64(&ch, air.boundaries.len);
    ch.observeDigest(trace_root);

    for (air.boundaries) |bc| {
        observeU64(&ch, bc.row);
        observeU64(&ch, bc.column);
        observeValue(&ch, bc.value);
    }

    for (weights) |*w| w.* = T.cis(ch.sampleAngleF32());
}

fn traceValue(trace: []const T, width: usize, row: usize, column: usize) T {
    return trace[row * width + column];
}

fn fftNatural(values: []T, inverse: bool) void {
    utils.bitReversePermute(T, values);
    afri.fftBitrevInPlace(values, inverse);
}

fn traceColumnCoeffs(
    allocator: std.mem.Allocator,
    trace: []const T,
    width: usize,
    column: usize,
    trace_len: usize,
) ![]T {
    const coeffs = try allocator.alloc(T, trace_len);
    errdefer allocator.free(coeffs);

    var row: usize = 0;
    while (row < trace_len) : (row += 1) {
        coeffs[row] = traceValue(trace, width, row, column);
    }

    fftNatural(coeffs, true);
    return coeffs;
}

fn evalPolyOnCoset(
    allocator: std.mem.Allocator,
    coeffs: []const T,
    n: usize,
    shift: T,
    bitrev: bool,
) ![]T {
    const values = try allocator.alloc(T, n);
    errdefer allocator.free(values);

    var shift_power = T.one;
    var i: usize = 0;
    while (i < coeffs.len) : (i += 1) {
        values[i] = coeffs[i].mul(shift_power);
        shift_power = shift_power.mul(shift);
    }
    while (i < n) : (i += 1) values[i] = T.zero;

    fftNatural(values, false);
    if (bitrev) utils.bitReversePermute(T, values);

    return values;
}

fn evalColumnsOnCoset(
    allocator: std.mem.Allocator,
    columns: []const []const T,
    n: usize,
    shift: T,
    bitrev: bool,
) ![][]T {
    const out = try allocator.alloc([]T, columns.len);
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

fn freeColumns(allocator: std.mem.Allocator, columns: [][]T) void {
    for (columns) |column| allocator.free(column);
    allocator.free(columns);
}

fn pointForTraceRow(log_trace_len: u6, row: usize) T {
    const trace_len = @as(usize, 1) << log_trace_len;
    std.debug.assert(row < trace_len);
    const omega_trace = T.root(trace_len);
    return omega_trace.pow(row);
}

fn cosetPointFromBitrev(log_n: usize, idx_bitrev: usize, shift: T) T {
    const n = @as(usize, 1) << @intCast(log_n);
    const omega = T.root(n);
    const exponent = utils.bitReverse(idx_bitrev, log_n);
    return shift.mul(omega.pow(exponent));
}

fn nextIndexBitrev(log_n: usize, idx_bitrev: usize, step: usize) usize {
    const n = @as(usize, 1) << @intCast(log_n);
    const exponent = utils.bitReverse(idx_bitrev, log_n);
    const next_exponent = (exponent + step) & (n - 1);
    return utils.bitReverse(next_exponent, log_n);
}

fn evalTransitionZerofier(config: Config, x: T) T {
    const trace_len = config.traceLen();
    const last_root = pointForTraceRow(config.log_trace_len, trace_len - 1);
    return x.pow(trace_len).sub(T.one).div(x.sub(last_root), config.delta_divisor);
}

fn compositionAt(
    config: Config,
    air: Air,
    weights: []const T,
    x: T,
    current: []const T,
    next: []const T,
) T {
    var acc = T.zero;
    var weight_index: usize = 0;

    const transition_z = evalTransitionZerofier(config, x);
    for (air.transitions) |tc| {
        const q = tc(x, current, next).div(transition_z, config.delta_divisor);
        acc = acc.add(q.mul(weights[weight_index]));
        weight_index += 1;
    }

    for (air.boundaries) |bc| {
        const point = pointForTraceRow(config.log_trace_len, bc.row);
        const q = current[bc.column].sub(bc.value).div(x.sub(point), config.delta_divisor);
        acc = acc.add(q.mul(weights[weight_index]));
        weight_index += 1;
    }

    return acc;
}

fn buildCompositionEvals(
    allocator: std.mem.Allocator,
    config: Config,
    air: Air,
    weights: []const T,
    trace_coset_evals: []const []const T,
) ![]T {
    const eval_len = config.evalLen();
    const width = air.width;
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const blowup = @as(usize, 1) << config.log_blowup;

    const current = try allocator.alloc(T, width);
    defer allocator.free(current);
    const next = try allocator.alloc(T, width);
    defer allocator.free(next);

    const values = try allocator.alloc(T, eval_len);
    errdefer allocator.free(values);

    var idx: usize = 0;
    while (idx < eval_len) : (idx += 1) {
        const next_idx = nextIndexBitrev(log_eval_len, idx, blowup);
        for (current, 0..) |*v, col| v.* = trace_coset_evals[col][idx];
        for (next, 0..) |*v, col| v.* = trace_coset_evals[col][next_idx];

        const x = cosetPointFromBitrev(
            log_eval_len,
            idx,
            config.afri_config.domain_shift,
        );
        values[idx] = compositionAt(config, air, weights, x, current, next);
    }

    return values;
}

fn deriveAfriQueryIndices(
    allocator: std.mem.Allocator,
    cfg: afri.Config,
    proof: afri.Proof,
) ![]usize {
    var ch = Challenger.init();

    var i: usize = 0;
    while (i < cfg.rounds()) : (i += 1) {
        ch.observeDigest(proof.roots[i]);
        _ = ch.sampleAngleF32();
    }

    for (proof.final_evals) |z| observeValue(&ch, z);

    const indices = try allocator.alloc(usize, cfg.num_queries);
    errdefer allocator.free(indices);

    for (indices) |*idx| idx.* = ch.sampleIndexPow2(cfg.n());
    return indices;
}

fn initialCompositionValue(proof: afri.Proof, query_index: usize, idx: usize) ?T {
    if (query_index >= proof.queries.len) return null;
    const query = proof.queries[query_index];
    if (query.openings.len == 0) return null;
    const opening = query.openings[0];
    return if ((idx & 1) == 0) opening.even else opening.odd;
}

fn validateInputs(config: Config, air: Air, trace: []const T) bool {
    if (air.width == 0) return false;
    if (trace.len != config.traceLen() * air.width) return false;
    if (config.log_blowup == 0) return false;
    if (config.afri_config.log_n != config.log_trace_len + config.log_blowup) return false;
    if (config.afri_config.domain_shift.is_zero(config.delta_divisor)) return false;
    if (config.delta_constraint <= 0.0) return false;
    if (config.delta_divisor <= 0.0) return false;

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
    trace: []const T,
) !Proof {
    std.debug.assert(validateInputs(config, air, trace));

    const trace_len = config.traceLen();
    const eval_len = config.evalLen();
    const width = air.width;
    const n_quotients = air.transitions.len + air.boundaries.len;

    const trace_coeffs = try allocator.alloc([]T, width);
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
        config.afri_config.domain_shift,
        true,
    );
    defer freeColumns(allocator, trace_coset_evals);

    var trace_tree = try TraceMerkleTree.build(allocator, trace_coset_evals);
    defer trace_tree.deinit(allocator);
    const trace_root = trace_tree.root();

    const weights = try allocator.alloc(T, n_quotients);
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

    var composition_proof = try afri.prove(allocator, config.afri_config, composition_evals);
    errdefer composition_proof.deinit(allocator);

    const query_indices = try deriveAfriQueryIndices(allocator, config.afri_config, composition_proof);
    defer allocator.free(query_indices);

    const query_count = composition_proof.queries.len;
    const path_len = utils.log2(eval_len);

    const queries = try allocator.alloc(QueryProof, query_count);
    errdefer allocator.free(queries);

    const rows_flat = try allocator.alloc(T, query_count * 2 * width);
    errdefer allocator.free(rows_flat);

    const paths_flat = try allocator.alloc(Digest, query_count * 2 * path_len);
    errdefer allocator.free(paths_flat);

    var row_cursor: usize = 0;
    var path_cursor: usize = 0;
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const blowup = @as(usize, 1) << config.log_blowup;

    for (query_indices, 0..) |current_idx, qi| {
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
    allocator: std.mem.Allocator,
    config: Config,
    air: Air,
    proof: *const Proof,
) bool {
    if (air.width == 0) return false;
    if (config.log_blowup == 0) return false;
    if (config.afri_config.log_n != config.log_trace_len + config.log_blowup) return false;

    const eval_len = config.evalLen();
    const log_eval_len = config.log_trace_len + config.log_blowup;
    const path_len = utils.log2(eval_len);
    const blowup = @as(usize, 1) << config.log_blowup;
    const n_quotients = air.transitions.len + air.boundaries.len;

    if (proof.queries.len != proof.composition.queries.len) return false;
    if (proof._rows_flat.len != proof.queries.len * 2 * air.width) return false;
    if (proof._paths_flat.len != proof.queries.len * 2 * path_len) return false;

    for (air.boundaries) |bc| {
        if (bc.row >= config.traceLen()) return false;
        if (bc.column >= air.width) return false;
    }

    if (!afri.verify(allocator, config.afri_config, proof.composition)) return false;

    const query_indices = deriveAfriQueryIndices(
        allocator,
        config.afri_config,
        proof.composition,
    ) catch return false;
    defer allocator.free(query_indices);

    var weights_buf: [64]T = undefined;
    if (n_quotients > weights_buf.len) return false;
    const weights = weights_buf[0..n_quotients];
    deriveWeights(config, air, proof.trace_root, weights);

    for (query_indices, proof.queries, 0..) |current_idx, trace_query, qi| {
        if (trace_query.current.row.len != air.width) return false;
        if (trace_query.next.row.len != air.width) return false;
        if (trace_query.current.path.len != path_len) return false;
        if (trace_query.next.path.len != path_len) return false;

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

        const opened_composition = initialCompositionValue(
            proof.composition,
            qi,
            current_idx,
        ) orelse return false;

        const x = cosetPointFromBitrev(
            log_eval_len,
            current_idx,
            config.afri_config.domain_shift,
        );
        const expected = compositionAt(
            config,
            air,
            weights,
            x,
            trace_query.current.row,
            trace_query.next.row,
        );
        if (!expected.eq(opened_composition, config.delta_constraint)) return false;
    }

    return true;
}

fn real(x: f32) T {
    return T.init(x, 0.0);
}

fn counterTransition(_: T, current: []const T, next: []const T) T {
    return next[0].sub(current[0]).sub(T.one);
}

fn factorialCounterTransition(_: T, current: []const T, next: []const T) T {
    return next[0].sub(current[0]).sub(T.one);
}

fn factorialValueTransition(_: T, current: []const T, next: []const T) T {
    return next[1].sub(current[1].mul(next[0]));
}

fn testConfig(log_trace_len: u6) Config {
    const log_blowup: u6 = 2;
    const trace_len = @as(usize, 1) << @intCast(log_trace_len);
    const eval_len = trace_len << log_blowup;
    const shift_angle: f32 = std.math.pi / @as(f32, @floatFromInt(eval_len));
    return .{
        .log_trace_len = log_trace_len,
        .log_blowup = log_blowup,
        .afri_config = .{
            .log_n = log_trace_len + log_blowup,
            .log_final_n = 3,
            .num_queries = 16,
            .delta_fold = 8e-2,
            .delta_final = 8e-2,
            .degree_bound = @as(usize, 1) << @intCast(log_trace_len),
            .domain_shift = T.cis(shift_angle),
        },
        .delta_constraint = 2e-1,
        .delta_divisor = 1e-5,
    };
}

fn makeCounterTrace(allocator: std.mem.Allocator, trace_len: usize) ![]T {
    const trace = try allocator.alloc(T, trace_len);
    errdefer allocator.free(trace);
    for (trace, 0..) |*v, i| v.* = real(@floatFromInt(i));
    return trace;
}

fn makeFactorialTrace(allocator: std.mem.Allocator, n: usize) ![]T {
    const trace_len = n + 1;
    const width = 2;
    const trace = try allocator.alloc(T, trace_len * width);
    errdefer allocator.free(trace);

    trace[0] = T.zero;
    trace[1] = T.one;

    var acc: f32 = 1.0;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const x: f32 = @floatFromInt(i);
        acc *= x;
        trace[i * width] = real(x);
        trace[i * width + 1] = real(acc);
    }

    return trace;
}

test "astark proves and verifies counter AIR" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = trace_len - 1, .column = 0, .value = real(@floatFromInt(trace_len - 1)) },
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

    try std.testing.expect(verify(allocator, cfg, air, &proof));
}

test "astark proves and verifies counter AIR at log 6" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(6);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = trace_len - 1, .column = 0, .value = real(@floatFromInt(trace_len - 1)) },
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

    try std.testing.expect(verify(allocator, cfg, air, &proof));
}

test "astark rejects invalid counter trace" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = trace_len - 1, .column = 0, .value = real(@floatFromInt(trace_len - 1)) },
    };
    const air: Air = .{
        .width = 1,
        .transitions = &transitions,
        .boundaries = &boundaries,
    };

    const trace = try makeCounterTrace(allocator, trace_len);
    defer allocator.free(trace);
    trace[3] = real(99.0);

    var proof = try prove(allocator, cfg, air, trace);
    defer proof.deinit(allocator);

    try std.testing.expect(!verify(allocator, cfg, air, &proof));
}

test "astark rejects spoiled trace opening" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = trace_len - 1, .column = 0, .value = real(@floatFromInt(trace_len - 1)) },
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

    proof.queries[0].current.row[0] = proof.queries[0].current.row[0].add(real(0.25));
    try std.testing.expect(!verify(allocator, cfg, air, &proof));
}

test "astark rejects spoiled AFRI proof" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(3);
    const trace_len = cfg.traceLen();

    const transitions = [_]TransitionConstraint{counterTransition};
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = trace_len - 1, .column = 0, .value = real(@floatFromInt(trace_len - 1)) },
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

    proof.composition.queries[0].openings[0].even =
        proof.composition.queries[0].openings[0].even.add(real(0.25));
    try std.testing.expect(!verify(allocator, cfg, air, &proof));
}

test "astark proves and verifies factorial AIR" {
    const allocator = std.testing.allocator;
    const cfg = testConfig(2);
    const n = cfg.traceLen() - 1;

    const transitions = [_]TransitionConstraint{
        factorialCounterTransition,
        factorialValueTransition,
    };
    const boundaries = [_]BoundaryConstraint{
        .{ .row = 0, .column = 0, .value = T.zero },
        .{ .row = 0, .column = 1, .value = T.one },
        .{ .row = n, .column = 0, .value = real(@floatFromInt(n)) },
        .{ .row = n, .column = 1, .value = real(6.0) },
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

    try std.testing.expect(verify(allocator, cfg, air, &proof));
}
