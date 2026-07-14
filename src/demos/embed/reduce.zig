//! The two reductions an embedding is always looked at through: t-SNE (what the
//! neighborhoods look like) and k-means (what the clusters are), plus the PCA
//! the framework uses as the honest linear baseline.
//!
//! Exact O(n²) t-SNE — no Barnes-Hut. That is a deliberate ceiling: it keeps the
//! code readable and it is fast enough for the few thousand points you can
//! actually *see* in a scatter. Above `max_tsne` the caller is told, not lied to.

const std = @import("std");

pub const max_tsne: usize = 4000;

/// Row-major `n`×`d` matrix of the original vectors.
pub const Matrix = struct {
    data: []const f32,
    n: usize,
    d: usize,

    pub fn row(m: Matrix, i: usize) []const f32 {
        return m.data[i * m.d ..][0..m.d];
    }
};

fn sqDist(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += (x - y) * (x - y);
    return s;
}

/// Symmetric affinities P with a per-point sigma binary-searched to the target
/// perplexity — the step that makes t-SNE adaptive to local density.
fn affinities(gpa: std.mem.Allocator, m: Matrix, perplexity: f32) ![]f32 {
    const n = m.n;
    const p = try gpa.alloc(f32, n * n);
    @memset(p, 0);
    const log_u = @log(perplexity);
    var d2 = try gpa.alloc(f32, n);
    defer gpa.free(d2);

    for (0..n) |i| {
        for (0..n) |j| d2[j] = if (i == j) 0 else sqDist(m.row(i), m.row(j));
        var beta: f32 = 1.0; // 1 / (2 sigma²)
        var lo: f32 = 0;
        var hi: f32 = std.math.floatMax(f32);
        for (0..50) |_| {
            // Row of unnormalized affinities and its Shannon entropy.
            var sum: f32 = 0;
            var hsum: f32 = 0;
            for (0..n) |j| {
                if (i == j) continue;
                const e = @exp(-d2[j] * beta);
                sum += e;
                hsum += d2[j] * e;
            }
            if (sum < 1e-12) sum = 1e-12;
            const h = @log(sum) + beta * hsum / sum;
            const diff = h - log_u;
            if (@abs(diff) < 1e-4) break;
            if (diff > 0) { // entropy too high → sharpen
                lo = beta;
                beta = if (hi == std.math.floatMax(f32)) beta * 2 else (beta + hi) / 2;
            } else {
                hi = beta;
                beta = (beta + lo) / 2;
            }
        }
        var sum: f32 = 0;
        for (0..n) |j| {
            if (i == j) continue;
            const e = @exp(-d2[j] * beta);
            p[i * n + j] = e;
            sum += e;
        }
        if (sum > 1e-12) {
            for (0..n) |j| p[i * n + j] /= sum;
        }
    }
    // Symmetrize: P = (P + Pᵀ) / 2n.
    const inv = 1.0 / @as(f32, @floatFromInt(2 * n));
    for (0..n) |i| {
        for (i + 1..n) |j| {
            const v = (p[i * n + j] + p[j * n + i]) * inv;
            p[i * n + j] = v;
            p[j * n + i] = v;
        }
        p[i * n + i] = 0;
    }
    return p;
}

/// t-SNE into 3D. Returns `n`×3 coordinates, centered and scaled to the unit
/// ball. `seed` makes the (random) initialization reproducible — a scatter that
/// changes shape every run is not a figure anyone can cite.
pub fn tsne(gpa: std.mem.Allocator, m: Matrix, perplexity: f32, iters: usize, seed: u64) ![][3]f32 {
    const n = m.n;
    const y = try gpa.alloc([3]f32, n);
    errdefer gpa.free(y);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (y) |*v| {
        for (0..3) |k| v[k] = rnd.floatNorm(f32) * 1e-2;
    }
    if (n < 3) return y;

    const p = try affinities(gpa, m, perplexity);
    defer gpa.free(p);
    const grad = try gpa.alloc([3]f32, n);
    defer gpa.free(grad);
    const vel = try gpa.alloc([3]f32, n);
    defer gpa.free(vel);
    @memset(vel, .{ 0, 0, 0 });
    const q_num = try gpa.alloc(f32, n * n); // 1 / (1 + |yi - yj|²)
    defer gpa.free(q_num);

    const lr: f32 = @max(@as(f32, @floatFromInt(n)) / 12.0, 50.0);
    for (0..iters) |it| {
        // Early exaggeration: pull the clusters apart before letting them settle.
        const exag: f32 = if (it < 250) 12.0 else 1.0;
        const momentum: f32 = if (it < 250) 0.5 else 0.8;

        var z: f32 = 0;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                var s: f32 = 0;
                for (0..3) |k| {
                    const t = y[i][k] - y[j][k];
                    s += t * t;
                }
                const num = 1.0 / (1.0 + s);
                q_num[i * n + j] = num;
                q_num[j * n + i] = num;
                z += 2 * num;
            }
            q_num[i * n + i] = 0;
        }
        if (z < 1e-12) z = 1e-12;

        for (0..n) |i| {
            grad[i] = .{ 0, 0, 0 };
            for (0..n) |j| {
                if (i == j) continue;
                const num = q_num[i * n + j];
                const q = num / z;
                const mult = (exag * p[i * n + j] - q) * num;
                for (0..3) |k| grad[i][k] += 4.0 * mult * (y[i][k] - y[j][k]);
            }
        }
        for (0..n) |i| {
            for (0..3) |k| {
                vel[i][k] = momentum * vel[i][k] - lr * grad[i][k] * 1e-3;
                y[i][k] += vel[i][k];
            }
        }
    }

    // Center and scale into the unit ball — the framework's camera assumes it.
    var ctr = [3]f32{ 0, 0, 0 };
    for (y) |v| {
        for (0..3) |k| ctr[k] += v[k];
    }
    for (0..3) |k| ctr[k] /= @floatFromInt(n);
    var max_r: f32 = 0;
    for (y) |*v| {
        for (0..3) |k| v[k] -= ctr[k];
        max_r = @max(max_r, @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
    }
    if (max_r > 1e-9) {
        for (y) |*v| {
            for (0..3) |k| v[k] /= max_r;
        }
    }
    return y;
}

/// k-means (Lloyd, k-means++ seeding) over the original vectors. Returns the
/// cluster index of every point — the unsupervised answer to "what classes?"
/// for a table that shipped without a label column.
pub fn kmeans(gpa: std.mem.Allocator, m: Matrix, k: usize, iters: usize, seed: u64) ![]u16 {
    const n = m.n;
    const kk = @max(@min(k, n), 1);
    const out = try gpa.alloc(u16, n);
    errdefer gpa.free(out);
    @memset(out, 0);
    const cent = try gpa.alloc(f32, kk * m.d);
    defer gpa.free(cent);
    const d2 = try gpa.alloc(f32, n);
    defer gpa.free(d2);

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    // k-means++: each new center is drawn far from the ones already chosen.
    @memcpy(cent[0..m.d], m.row(rnd.uintLessThan(usize, n)));
    for (1..kk) |c| {
        var total: f64 = 0;
        for (0..n) |i| {
            var best = std.math.floatMax(f32);
            for (0..c) |j| best = @min(best, sqDist(m.row(i), cent[j * m.d ..][0..m.d]));
            d2[i] = best;
            total += best;
        }
        var pick = rnd.float(f64) * total;
        var chosen: usize = n - 1;
        for (0..n) |i| {
            pick -= d2[i];
            if (pick <= 0) {
                chosen = i;
                break;
            }
        }
        @memcpy(cent[c * m.d ..][0..m.d], m.row(chosen));
    }

    const counts = try gpa.alloc(u32, kk);
    defer gpa.free(counts);
    const acc = try gpa.alloc(f32, kk * m.d);
    defer gpa.free(acc);
    for (0..iters) |_| {
        var moved = false;
        for (0..n) |i| {
            var best: u16 = 0;
            var best_d = std.math.floatMax(f32);
            for (0..kk) |c| {
                const d = sqDist(m.row(i), cent[c * m.d ..][0..m.d]);
                if (d < best_d) {
                    best_d = d;
                    best = @intCast(c);
                }
            }
            if (out[i] != best) moved = true;
            out[i] = best;
        }
        @memset(counts, 0);
        @memset(acc, 0);
        for (0..n) |i| {
            const c = out[i];
            counts[c] += 1;
            for (0..m.d) |j| acc[c * m.d + j] += m.row(i)[j];
        }
        for (0..kk) |c| {
            // An emptied cluster keeps its previous centroid — snapping it to
            // the origin would drag every stray point there on the next pass.
            if (counts[c] == 0) continue;
            const inv = 1.0 / @as(f32, @floatFromInt(counts[c]));
            for (0..m.d) |j| cent[c * m.d + j] = acc[c * m.d + j] * inv;
        }
        if (!moved) break;
    }
    return out;
}
