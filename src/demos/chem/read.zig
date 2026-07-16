//! Readers for the two files a chemist or structural biologist actually has on
//! disk: XYZ (what every quantum-chemistry code writes) and PDB (what every
//! structure comes in). Both land in the same `Atom` list.
//!
//! PDB is read by column, not by whitespace — the format is fixed-width and real
//! files are full of atom names and residues that would split wrong otherwise.
//! Only ATOM/HETATM records matter here; CONECT is honored when present, and the
//! bonds nobody wrote down are inferred from covalent radii.

const std = @import("std");
const source = @import("../../source.zig");

pub const Element = enum(u8) {
    h,
    c,
    n,
    o,
    s,
    p,
    f,
    cl,
    br,
    i,
    fe,
    zn,
    mg,
    ca,
    na,
    k,
    other,

    pub fn symbol(e: Element) []const u8 {
        return switch (e) {
            .h => "H",
            .c => "C",
            .n => "N",
            .o => "O",
            .s => "S",
            .p => "P",
            .f => "F",
            .cl => "Cl",
            .br => "Br",
            .i => "I",
            .fe => "Fe",
            .zn => "Zn",
            .mg => "Mg",
            .ca => "Ca",
            .na => "Na",
            .k => "K",
            .other => "X",
        };
    }

    /// Covalent radius in Å (Cordero 2008) — what infers the bonds.
    pub fn covalentRadius(e: Element) f32 {
        return switch (e) {
            .h => 0.31,
            .c => 0.76,
            .n => 0.71,
            .o => 0.66,
            .s => 1.05,
            .p => 1.07,
            .f => 0.57,
            .cl => 1.02,
            .br => 1.20,
            .i => 1.39,
            .fe => 1.32,
            .zn => 1.22,
            .mg => 1.41,
            .ca => 1.76,
            .na => 1.66,
            .k => 2.03,
            .other => 1.20,
        };
    }

    /// Van der Waals radius in Å (Bondi 1964, Mantina 2009 for the metals) —
    /// how big the atom LOOKS. Bonds come from `covalentRadius`; this is the
    /// other radius, and drawing spheres with the covalent one (or with three
    /// hand-picked buckets) makes sulphur the size of oxygen and iron the size
    /// of carbon, which is exactly what a chemist reads a CPK model to avoid.
    pub fn vdwRadius(e: Element) f32 {
        return switch (e) {
            .h => 1.10,
            .c => 1.70,
            .n => 1.55,
            .o => 1.52,
            .s => 1.80,
            .p => 1.80,
            .f => 1.47,
            .cl => 1.75,
            .br => 1.85,
            .i => 1.98,
            .fe => 2.04,
            .zn => 2.10,
            .mg => 1.73,
            .ca => 2.31,
            .na => 2.27,
            .k => 2.75,
            .other => 1.80,
        };
    }

    /// CPK/Jmol colors — the palette every chemist reads without a legend.
    pub fn cpk(e: Element) [3]f32 {
        return switch (e) {
            .h => .{ 0.92, 0.92, 0.95 },
            .c => .{ 0.35, 0.38, 0.42 },
            .n => .{ 0.20, 0.40, 1.00 },
            .o => .{ 1.00, 0.20, 0.18 },
            .s => .{ 1.00, 0.85, 0.20 },
            .p => .{ 1.00, 0.55, 0.10 },
            .f => .{ 0.55, 1.00, 0.55 },
            .cl => .{ 0.35, 0.95, 0.35 },
            .br => .{ 0.65, 0.30, 0.15 },
            .i => .{ 0.60, 0.25, 0.75 },
            .fe => .{ 0.88, 0.45, 0.10 },
            .zn => .{ 0.55, 0.55, 0.65 },
            .mg => .{ 0.30, 0.85, 0.30 },
            .ca => .{ 0.40, 0.85, 0.55 },
            .na => .{ 0.55, 0.35, 0.95 },
            .k => .{ 0.55, 0.25, 0.85 },
            .other => .{ 0.75, 0.55, 0.95 },
        };
    }

    pub fn fromSymbol(s: []const u8) Element {
        var b: [2]u8 = .{ ' ', ' ' };
        var n: usize = 0;
        for (s) |c| {
            if (std.ascii.isAlphabetic(c) and n < 2) {
                b[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        const two = b[0..2];
        if (std.mem.eql(u8, two, "cl")) return .cl;
        if (std.mem.eql(u8, two, "br")) return .br;
        if (std.mem.eql(u8, two, "fe")) return .fe;
        if (std.mem.eql(u8, two, "zn")) return .zn;
        if (std.mem.eql(u8, two, "mg")) return .mg;
        if (std.mem.eql(u8, two, "ca")) return .ca;
        if (std.mem.eql(u8, two, "na")) return .na;
        return switch (b[0]) {
            'h' => .h,
            'c' => .c,
            'n' => .n,
            'o' => .o,
            's' => .s,
            'p' => .p,
            'f' => .f,
            'i' => .i,
            'k' => .k,
            else => .other,
        };
    }
};

pub const Atom = struct {
    pos: [3]f32,
    el: Element,
    /// PDB: the atom's name (CA, CB, N…), the residue and the chain. XYZ leaves
    /// them empty — the fields simply stay unused, and the domain notices.
    atom_name: [4]u8 = .{ ' ', ' ', ' ', ' ' },
    res_name: [3]u8 = .{ ' ', ' ', ' ' },
    res_seq: i32 = 0,
    chain: u8 = ' ',
    /// Temperature factor: the B-factor column of a crystal structure, the one
    /// number in a PDB that says "do not trust this atom too much".
    bfactor: f32 = 0,
    hetatm: bool = false,
    /// Backbone atom of a protein (N, CA, C, O) — the ribbon, in ball-and-stick.
    backbone: bool = false,
};

pub const Structure = struct {
    gpa: std.mem.Allocator,
    atoms: []Atom,
    /// Bonds declared by the file (PDB CONECT). Inferred bonds come later.
    conect: [][2]u16,
    /// Title/name as the file gives it.
    title: []u8,
    is_pdb: bool,

    pub fn deinit(s: *Structure) void {
        s.gpa.free(s.atoms);
        if (s.conect.len > 0) s.gpa.free(s.conect);
        if (s.title.len > 0) s.gpa.free(s.title);
    }
};

fn fixed(line: []const u8, from: usize, to: usize) []const u8 {
    if (from >= line.len) return "";
    const end = @min(to, line.len);
    return std.mem.trim(u8, line[from..end], " \t\r");
}

/// XYZ: count, comment, then `symbol x y z` per line (Å).
fn loadXyz(gpa: std.mem.Allocator, text: []const u8, max_atoms: usize) !Structure {
    var atoms: std.ArrayList(Atom) = .empty;
    errdefer atoms.deinit(gpa);
    var title: []u8 = &.{};
    errdefer if (title.len > 0) gpa.free(title);
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line_no == 0) continue; // the count
        if (line_no == 1) { // the comment line is the molecule's name
            title = try gpa.dupe(u8, line);
            continue;
        }
        if (line.len == 0) continue;
        if (atoms.items.len >= max_atoms) break;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const sym = f.next() orelse continue;
        const x = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        const y = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        const z = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        try atoms.append(gpa, .{ .pos = .{ x, y, z }, .el = Element.fromSymbol(sym) });
    }
    return .{
        .gpa = gpa,
        .atoms = try atoms.toOwnedSlice(gpa),
        .conect = &.{},
        .title = title,
        .is_pdb = false,
    };
}

/// PDB: fixed-width ATOM/HETATM records, plus CONECT and the TITLE.
fn loadPdb(gpa: std.mem.Allocator, text: []const u8, max_atoms: usize) !Structure {
    var atoms: std.ArrayList(Atom) = .empty;
    errdefer atoms.deinit(gpa);
    var conect: std.ArrayList([2]u16) = .empty;
    errdefer conect.deinit(gpa);
    var title_buf: std.ArrayList(u8) = .empty;
    errdefer title_buf.deinit(gpa);
    // PDB atom serial → our index (CONECT speaks serials).
    var serial: std.AutoHashMap(i32, u16) = .init(gpa);
    defer serial.deinit();

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len < 6) continue;
        const rec = line[0..6];
        if (std.mem.startsWith(u8, rec, "TITLE")) {
            const t = fixed(line, 10, 80);
            if (title_buf.items.len > 0) try title_buf.append(gpa, ' ');
            try title_buf.appendSlice(gpa, t);
            continue;
        }
        if (std.mem.startsWith(u8, rec, "ENDMDL")) break; // first model only
        const is_atom = std.mem.startsWith(u8, rec, "ATOM");
        const is_het = std.mem.startsWith(u8, rec, "HETATM");
        if (std.mem.startsWith(u8, rec, "CONECT")) {
            const a = std.fmt.parseInt(i32, fixed(line, 6, 11), 10) catch continue;
            var col: usize = 11;
            while (col + 5 <= line.len and col < 31) : (col += 5) {
                const b = std.fmt.parseInt(i32, fixed(line, col, col + 5), 10) catch continue;
                const ia = serial.get(a) orelse continue;
                const ib = serial.get(b) orelse continue;
                if (ia < ib) try conect.append(gpa, .{ ia, ib });
            }
            continue;
        }
        if (!is_atom and !is_het) continue;
        if (atoms.items.len >= max_atoms) continue;
        if (line.len < 54) continue;

        // Alternate locations: keep the first conformer only.
        const altloc = line[16];
        if (altloc != ' ' and altloc != 'A') continue;

        const x = std.fmt.parseFloat(f32, fixed(line, 30, 38)) catch continue;
        const y = std.fmt.parseFloat(f32, fixed(line, 38, 46)) catch continue;
        const z = std.fmt.parseFloat(f32, fixed(line, 46, 54)) catch continue;
        // Columns 76-78 hold the element; older files leave them blank, and then
        // the atom name's first letters are the best guess there is.
        const el_field = fixed(line, 76, 78);
        const nm = fixed(line, 12, 16);
        const el = if (el_field.len > 0) Element.fromSymbol(el_field) else Element.fromSymbol(nm);

        var a: Atom = .{ .pos = .{ x, y, z }, .el = el, .hetatm = is_het };
        const nm4 = fixed(line, 12, 16);
        for (nm4, 0..) |c, k| {
            if (k < 4) a.atom_name[k] = c;
        }
        const rn = fixed(line, 17, 20);
        for (rn, 0..) |c, k| {
            if (k < 3) a.res_name[k] = c;
        }
        a.chain = if (line.len > 21) line[21] else ' ';
        a.res_seq = std.fmt.parseInt(i32, fixed(line, 22, 26), 10) catch 0;
        a.bfactor = std.fmt.parseFloat(f32, fixed(line, 60, 66)) catch 0;
        a.backbone = !is_het and (std.mem.eql(u8, nm4, "N") or std.mem.eql(u8, nm4, "CA") or
            std.mem.eql(u8, nm4, "C") or std.mem.eql(u8, nm4, "O"));

        const ser = std.fmt.parseInt(i32, fixed(line, 6, 11), 10) catch @as(i32, @intCast(atoms.items.len + 1));
        try serial.put(ser, @intCast(atoms.items.len));
        try atoms.append(gpa, a);
    }

    return .{
        .gpa = gpa,
        .atoms = try atoms.toOwnedSlice(gpa),
        .conect = try conect.toOwnedSlice(gpa),
        .title = try title_buf.toOwnedSlice(gpa),
        .is_pdb = true,
    };
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max_atoms: usize) !Structure {
    const text = try source.readAll(gpa, io, path, 256 * 1024 * 1024);
    defer gpa.free(text);
    const pdb = std.mem.endsWith(u8, path, ".pdb") or std.mem.endsWith(u8, path, ".ent") or
        std.mem.indexOf(u8, text[0..@min(text.len, 4096)], "\nATOM  ") != null;
    const s = if (pdb) try loadPdb(gpa, text, max_atoms) else try loadXyz(gpa, text, max_atoms);
    if (s.atoms.len == 0) return error.NoAtoms;
    return s;
}

/// The widest a bond can be: the two largest covalent radii plus the tolerance.
/// It sizes the grid cell below, so no bond can span more than one cell.
const max_bond_cut: f32 = 2.03 + 2.03 + 0.4; // K + K + 0.4 Å

/// True when atoms `a` and `b` are bonded — the whole chemistry of the inference,
/// in one place so the grid below cannot disagree with the rule it accelerates.
fn bonded(a: Atom, b: Atom) bool {
    // Two hydrogens never bond to each other; a pair closer than 0.4 Å is
    // a modeling error, not a bond.
    if (a.el == .h and b.el == .h) return false;
    const cut = a.el.covalentRadius() + b.el.covalentRadius() + 0.4;
    var d2: f32 = 0;
    for (0..3) |k| {
        const t = a.pos[k] - b.pos[k];
        d2 += t * t;
    }
    return d2 <= cut * cut and d2 >= 0.16;
}

/// The rule, applied the slow and obvious way: every pair, once. It is the
/// definition `inferBonds` accelerates — kept because a cloud too sparse to bin
/// falls back to it, and because a test holds the grid to its answer.
fn inferBondsBrute(gpa: std.mem.Allocator, atoms: []const Atom) ![][2]u16 {
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    for (atoms, 0..) |a, i| {
        for (atoms[i + 1 ..], i + 1..) |b, j| {
            if (bonded(a, b)) try out.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Bonds from covalent radii: two atoms are bonded when they sit closer than
/// r₁ + r₂ + 0.4 Å — the tolerance every viewer uses, and the reason a structure
/// with no CONECT records still comes up as a molecule.
///
/// Every pair used to be tested against every other, which is 200 million tests
/// at the 20 000-atom cap and a load that visibly stops — for a rule that can
/// never reach further than `max_bond_cut`. Binning the atoms into cells that
/// wide means a bond can only join atoms in the same cell or a touching one, so
/// each atom looks at its 27 cells and the work falls to O(n): a protein opens
/// as fast as it parses. It returns the brute force's own list — the same pairs,
/// pair for pair, in the same order — and a test holds it to that.
pub fn inferBonds(gpa: std.mem.Allocator, atoms: []const Atom) ![][2]u16 {
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    if (atoms.len == 0) return out.toOwnedSlice(gpa);

    // The bounding box, in cells of `max_bond_cut`.
    var lo = [3]f32{ atoms[0].pos[0], atoms[0].pos[1], atoms[0].pos[2] };
    var hi = lo;
    for (atoms) |a| {
        for (0..3) |k| {
            if (!std.math.isFinite(a.pos[k])) return inferBondsBrute(gpa, atoms);
            lo[k] = @min(lo[k], a.pos[k]);
            hi[k] = @max(hi[k], a.pos[k]);
        }
    }
    // A grid pays only when the atoms are packed the way matter is. Two atoms a
    // kilometre apart would ask for a hundred million empty cells — so measure
    // the grid first and hand a cloud that shape to the loop it was written for.
    var n_cells: usize = 1;
    var dim: [3]usize = undefined;
    const cell_cap = atoms.len * 8 + 1024;
    for (0..3) |k| {
        const span = (hi[k] - lo[k]) / max_bond_cut;
        if (!(span < @as(f32, @floatFromInt(cell_cap)))) return inferBondsBrute(gpa, atoms);
        dim[k] = @max(1, @as(usize, @intFromFloat(@floor(span))) + 1);
        n_cells = std.math.mul(usize, n_cells, dim[k]) catch return inferBondsBrute(gpa, atoms);
        if (n_cells > cell_cap) return inferBondsBrute(gpa, atoms);
    }

    const cellOf = struct {
        fn f(pos: [3]f32, o: [3]f32, d: [3]usize) [3]usize {
            var c: [3]usize = undefined;
            for (0..3) |k| {
                const t = @floor((pos[k] - o[k]) / max_bond_cut);
                c[k] = @min(d[k] - 1, @as(usize, @intFromFloat(@max(t, 0))));
            }
            return c;
        }
    }.f;

    // Counting sort the atoms into the cells: `start[c]` where cell c's atoms
    // begin in `items`. Two passes, no per-cell allocation.
    const start = try gpa.alloc(u32, n_cells + 1);
    defer gpa.free(start);
    @memset(start, 0);
    for (atoms) |a| {
        const c = cellOf(a.pos, lo, dim);
        start[(c[2] * dim[1] + c[1]) * dim[0] + c[0] + 1] += 1;
    }
    for (1..start.len) |i| start[i] += start[i - 1];

    const items = try gpa.alloc(u16, atoms.len);
    defer gpa.free(items);
    {
        const fill = try gpa.alloc(u32, n_cells);
        defer gpa.free(fill);
        @memcpy(fill, start[0..n_cells]);
        for (atoms, 0..) |a, i| {
            const c = cellOf(a.pos, lo, dim);
            const ci = (c[2] * dim[1] + c[1]) * dim[0] + c[0];
            items[fill[ci]] = @intCast(i);
            fill[ci] += 1;
        }
    }

    // Each atom against its own cell and the 26 around it. The pair is kept only
    // when i < j, so it is emitted once and the halves need no bookkeeping.
    //
    // The cells hand back neighbours in cell order, not in atom order, so each
    // atom's partners are sorted before they are emitted: the pairs then leave
    // here exactly as the all-against-all loop left them, and everything reading
    // this list — the CSV, `bondedPartner`'s "first neighbour" — is unmoved.
    //
    // The buffer grows rather than capping: chemistry bounds a real degree at a
    // handful, but a garbage file is not chemistry, and a cap would silently
    // drop the pairs past it — turning this from an optimization into a
    // different answer, which is the one thing it may not be.
    var mine: std.ArrayList(u16) = .empty;
    defer mine.deinit(gpa);
    for (atoms, 0..) |a, i| {
        mine.clearRetainingCapacity();
        const c = cellOf(a.pos, lo, dim);
        // The touching cells, clamped to the grid: `c[k] -| 1` is a saturating
        // subtract, so cell 0's neighbourhood simply starts at 0.
        var z = c[2] -| 1;
        while (z <= @min(c[2] + 1, dim[2] - 1)) : (z += 1) {
            var y = c[1] -| 1;
            while (y <= @min(c[1] + 1, dim[1] - 1)) : (y += 1) {
                var x = c[0] -| 1;
                while (x <= @min(c[0] + 1, dim[0] - 1)) : (x += 1) {
                    const ci = (z * dim[1] + y) * dim[0] + x;
                    for (items[start[ci]..start[ci + 1]]) |j| {
                        if (j <= i) continue;
                        if (bonded(a, atoms[j])) try mine.append(gpa, j);
                    }
                }
            }
        }
        std.mem.sort(u16, mine.items, {}, std.sort.asc(u16));
        for (mine.items) |j| try out.append(gpa, .{ @intCast(i), j });
    }
    return out.toOwnedSlice(gpa);
}

// --- tests -------------------------------------------------------------------------------------

// A pseudo-random cloud, dense enough that atoms really do bond: the grid must
// return the brute-force list, pair for pair and in the same order. This is the
// whole warrant for the grid — it is an optimization, and an optimization that
// changes the answer is a bug with better timings.
test "inferBonds: the grid agrees with all-against-all" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const els = [_]Element{ .c, .n, .o, .h, .s, .fe, .k };

    for ([_]usize{ 0, 1, 2, 37, 400 }) |n| {
        const atoms = try gpa.alloc(Atom, n);
        defer gpa.free(atoms);
        for (atoms) |*a| {
            a.* = .{
                // A 14 Å box: several grid cells across, and packed tightly
                // enough that most atoms have neighbours in a touching cell.
                .pos = .{
                    rnd.float(f32) * 14.0,
                    rnd.float(f32) * 14.0,
                    rnd.float(f32) * 14.0,
                },
                .el = els[rnd.uintLessThan(usize, els.len)],
            };
        }
        const fast = try inferBonds(gpa, atoms);
        defer gpa.free(fast);
        const slow = try inferBondsBrute(gpa, atoms);
        defer gpa.free(slow);
        try std.testing.expectEqualSlices([2]u16, slow, fast);
    }
}

// Degenerate geometry the grid has to survive: every atom on one point (one
// cell, and no bonds at all — coincident atoms are a modeling error, not a
// bond), and a line long enough to need many cells along one axis only.
test "inferBonds: coincident and collinear atoms" {
    const gpa = std.testing.allocator;

    var same: [16]Atom = undefined;
    for (&same) |*a| a.* = .{ .pos = .{ 1, 2, 3 }, .el = .c };
    const none = try inferBonds(gpa, &same);
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // A carbon chain at 1.5 Å: each atom bonds to the next and to nothing else
    // (1.5 < 1.92 = the C–C cutoff; 3.0 > 1.92).
    var chain: [64]Atom = undefined;
    for (&chain, 0..) |*a, i| a.* = .{ .pos = .{ @as(f32, @floatFromInt(i)) * 1.5, 0, 0 }, .el = .c };
    const bonds = try inferBonds(gpa, &chain);
    defer gpa.free(bonds);
    try std.testing.expectEqual(@as(usize, chain.len - 1), bonds.len);
    for (bonds, 0..) |b, i| try std.testing.expectEqual([2]u16{ @intCast(i), @intCast(i + 1) }, b);
}

// The escape hatch: a cloud so sparse that binning it would ask for more cells
// than there is memory. It must still answer, and answer the same thing.
test "inferBonds: a cloud too sparse to bin still gets its bonds" {
    const gpa = std.testing.allocator;
    // Two tight pairs, a kilometre apart: 1e3 Å / 4.46 Å is far past the cell
    // cap for four atoms, so this takes the fallback — and the two bonds are
    // still found.
    const atoms = [_]Atom{
        .{ .pos = .{ 0, 0, 0 }, .el = .c },
        .{ .pos = .{ 1.5, 0, 0 }, .el = .c },
        .{ .pos = .{ 100_000, 0, 0 }, .el = .c },
        .{ .pos = .{ 100_001.5, 0, 0 }, .el = .c },
    };
    const bonds = try inferBonds(gpa, &atoms);
    defer gpa.free(bonds);
    try std.testing.expectEqualSlices([2]u16, &.{ .{ 0, 1 }, .{ 2, 3 } }, bonds);
}

// A coordinate that is not a number reaches the reader from real files. It must
// not become a grid index.
test "inferBonds: a NaN coordinate does not crash the grid" {
    const gpa = std.testing.allocator;
    const nan = std.math.nan(f32);
    const atoms = [_]Atom{
        .{ .pos = .{ 0, 0, 0 }, .el = .c },
        .{ .pos = .{ 1.5, 0, 0 }, .el = .c },
        .{ .pos = .{ nan, nan, nan }, .el = .c },
    };
    const bonds = try inferBonds(gpa, &atoms);
    defer gpa.free(bonds);
    try std.testing.expectEqualSlices([2]u16, &.{.{ 0, 1 }}, bonds);
}
