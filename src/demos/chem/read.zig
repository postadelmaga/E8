//! Readers for the two files a chemist or structural biologist actually has on
//! disk: XYZ (what every quantum-chemistry code writes) and PDB (what every
//! structure comes in). Both land in the same `Atom` list.
//!
//! PDB is read by column, not by whitespace — the format is fixed-width and real
//! files are full of atom names and residues that would split wrong otherwise.
//! Only ATOM/HETATM records matter here; CONECT is honored when present, and the
//! bonds nobody wrote down are inferred from covalent radii.

const std = @import("std");

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
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(text);
    const pdb = std.mem.endsWith(u8, path, ".pdb") or std.mem.endsWith(u8, path, ".ent") or
        std.mem.indexOf(u8, text[0..@min(text.len, 4096)], "\nATOM  ") != null;
    const s = if (pdb) try loadPdb(gpa, text, max_atoms) else try loadXyz(gpa, text, max_atoms);
    if (s.atoms.len == 0) return error.NoAtoms;
    return s;
}

/// Bonds from covalent radii: two atoms are bonded when they sit closer than
/// r₁ + r₂ + 0.4 Å — the tolerance every viewer uses, and the reason a structure
/// with no CONECT records still comes up as a molecule.
pub fn inferBonds(gpa: std.mem.Allocator, atoms: []const Atom) ![][2]u16 {
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    for (atoms, 0..) |a, i| {
        const ra = a.el.covalentRadius();
        for (atoms[i + 1 ..], i + 1..) |b, j| {
            const rb = b.el.covalentRadius();
            const cut = ra + rb + 0.4;
            var d2: f32 = 0;
            for (0..3) |k| {
                const t = a.pos[k] - b.pos[k];
                d2 += t * t;
            }
            // Two hydrogens never bond to each other; a pair closer than 0.4 Å is
            // a modeling error, not a bond.
            if (d2 > cut * cut or d2 < 0.16) continue;
            if (a.el == .h and b.el == .h) continue;
            try out.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }
    return out.toOwnedSlice(gpa);
}
