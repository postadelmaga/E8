//! The online vocabulary: getting a real molecule without owning a file.
//!
//! Authoring a chemistry demo should not begin with "first, find a PDB somewhere".
//! Two public services already hold the answer, and both hand it over as plain
//! HTTP:
//!
//!   • PUBCHEM, by NAME. "caffeine" → a 3D SDF of the molecule. PubChem's 3D
//!     records are computed conformers, so what you get is a real geometry, not a
//!     flat diagram — but it is SDF, and the `chem` domain reads PDB and XYZ. The
//!     conversion is at the bottom of this file and it is honest work: an SDF's
//!     atom block already IS an xyz table, so the translation loses nothing.
//!   • RCSB, by PDB ID. "1ubq" → the deposited structure of ubiquitin, exactly the
//!     file a structural biologist would download, saved unchanged.
//!
//! Nothing here runs unless the author presses the button. There is no background
//! traffic, no telemetry, and no other executable in this project touches the
//! network.

const std = @import("std");

pub const Error = error{
    NotFound,
    BadResponse,
    NoAtoms,
} || std.mem.Allocator.Error;

/// What a download produced: bytes to write, and the file name to write them under
/// (the extension is what tells the `chem` domain how to read them).
pub const Asset = struct {
    name: []const u8,
    bytes: []const u8,

    pub fn deinit(a: Asset, gpa: std.mem.Allocator) void {
        gpa.free(a.name);
        gpa.free(a.bytes);
    }
};

fn get(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    // The errdefer above owns the body on every error path — freeing it here too
    // was a double free, and a name PubChem does not know is exactly how you find
    // that out.
    if (res.status != .ok) {
        return if (res.status == .not_found) Error.NotFound else Error.BadResponse;
    }
    return body.toOwnedSlice();
}

/// A molecule by name, from PubChem: the 3D conformer, converted to XYZ.
pub fn pubchem(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !Asset {
    const esc = try urlEscape(gpa, name);
    defer gpa.free(esc);

    const url = try std.fmt.allocPrint(
        gpa,
        "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{s}/SDF?record_type=3d",
        .{esc},
    );
    defer gpa.free(url);

    const sdf = try get(gpa, io, url);
    defer gpa.free(sdf);

    const xyz = try sdfToXyz(gpa, sdf, name);
    errdefer gpa.free(xyz);

    const slug = try slugify(gpa, name);
    defer gpa.free(slug);
    const file = try std.fmt.allocPrint(gpa, "{s}.xyz", .{slug});
    return .{ .name = file, .bytes = xyz };
}

/// A structure by PDB ID, from RCSB: the deposited file, untouched.
pub fn rcsb(gpa: std.mem.Allocator, io: std.Io, pdb_id: []const u8) !Asset {
    var id_buf: [16]u8 = undefined;
    const n = @min(pdb_id.len, id_buf.len);
    for (pdb_id[0..n], 0..) |c, i| id_buf[i] = std.ascii.toLower(c);
    const id = id_buf[0..n];

    const url = try std.fmt.allocPrint(gpa, "https://files.rcsb.org/download/{s}.pdb", .{id});
    defer gpa.free(url);

    const bytes = try get(gpa, io, url);
    errdefer gpa.free(bytes);
    const file = try std.fmt.allocPrint(gpa, "{s}.pdb", .{id});
    return .{ .name = file, .bytes = bytes };
}

// --- SDF → XYZ ------------------------------------------------------------------------------

/// An SDF (MDL molfile) opens with three title lines, then a counts line whose
/// first two fields are the number of atoms and bonds, then one line per atom:
///
///     ` -0.9204    0.5321    0.0000 O   0  0  0  0 ...`
///        x          y         z      element
///
/// which is an XYZ record with extra columns. So the conversion is a projection,
/// not an interpretation — nothing is inferred and nothing is lost that `chem`
/// would have read. (Bonds are dropped: the domain infers them from distances and
/// covalent radii anyway.)
pub fn sdfToXyz(gpa: std.mem.Allocator, sdf: []const u8, title: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, sdf, '\n');
    _ = lines.next(); // title
    _ = lines.next(); // program
    _ = lines.next(); // comment
    const counts = lines.next() orelse return Error.NoAtoms;

    var it = std.mem.tokenizeAny(u8, counts, " \t\r");
    const n_atoms = std.fmt.parseInt(usize, it.next() orelse return Error.NoAtoms, 10) catch return Error.NoAtoms;
    if (n_atoms == 0) return Error.NoAtoms;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [128]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}\n", .{n_atoms}) catch unreachable);
    try out.appendSlice(gpa, title);
    try out.appendSlice(gpa, " — PubChem 3D conformer\n");

    var written: usize = 0;
    while (written < n_atoms) {
        const line = lines.next() orelse return Error.NoAtoms;
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const xs = f.next() orelse return Error.NoAtoms;
        const ys = f.next() orelse return Error.NoAtoms;
        const zs = f.next() orelse return Error.NoAtoms;
        const el = f.next() orelse return Error.NoAtoms;
        const x = std.fmt.parseFloat(f64, xs) catch return Error.NoAtoms;
        const y = std.fmt.parseFloat(f64, ys) catch return Error.NoAtoms;
        const z = std.fmt.parseFloat(f64, zs) catch return Error.NoAtoms;
        try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{s} {d:.4} {d:.4} {d:.4}\n", .{ el, x, y, z }) catch unreachable);
        written += 1;
    }
    return out.toOwnedSlice(gpa);
}

// --- small helpers --------------------------------------------------------------------------

fn urlEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [8]u8 = undefined;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A name a directory can carry: lowercase, no spaces, no surprises.
pub fn slugify(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var last_dash = true; // no leading dash
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(gpa, std.ascii.toLower(c));
            last_dash = false;
        } else if (!last_dash) {
            try out.append(gpa, '-');
            last_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(gpa, "demo");
    return out.toOwnedSlice(gpa);
}

// --- tests ------------------------------------------------------------------------------------

const testing = std.testing;

test "an SDF atom block becomes an XYZ" {
    // A real PubChem 3D SDF, in the exact shape the service returns (three header
    // lines, a counts line, the atom block, then bonds) — two atoms of it.
    const sdf =
        \\7845
        \\  -OEChem-01012400003D
        \\
        \\  2  1  0     0  0  0  0  0  0999 V2000
        \\    0.4700   -1.6900    0.0100 O   0  0  0  0  0  0  0  0  0  0  0  0
        \\   -2.0300    1.5100   -0.0200 N   0  0  0  0  0  0  0  0  0  0  0  0
        \\  1  2  1  0  0  0  0
        \\
    ;
    const xyz = try sdfToXyz(testing.allocator, sdf, "caffeine");
    defer testing.allocator.free(xyz);

    var lines = std.mem.splitScalar(u8, xyz, '\n');
    try testing.expectEqualStrings("2", lines.next().?); // the count line is the SDF's own
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "caffeine") != null);
    // The atoms come through as `element x y z` — the order XYZ wants, not SDF's.
    try testing.expectEqualStrings("O 0.4700 -1.6900 0.0100", lines.next().?);
    try testing.expectEqualStrings("N -2.0300 1.5100 -0.0200", lines.next().?);
}

test "a truncated SDF is an error, not a half molecule" {
    const sdf =
        \\x
        \\y
        \\z
        \\ 24 25  0     0  0  0  0  0  0999 V2000
        \\    0.4700   -1.6900    0.0100 O   0  0  0  0
        \\
    ;
    // It claims 24 atoms and gives 1: refuse it rather than silently write a
    // one-atom molecule the author would then have to debug.
    try testing.expectError(Error.NoAtoms, sdfToXyz(testing.allocator, sdf, "x"));
}

test "names become directories that behave" {
    const gpa = testing.allocator;
    const a = try slugify(gpa, "Acido acetilsalicilico (aspirina)!");
    defer gpa.free(a);
    try testing.expectEqualStrings("acido-acetilsalicilico-aspirina", a);

    const b = try slugify(gpa, "   ");
    defer gpa.free(b);
    try testing.expectEqualStrings("demo", b);
}

test "an escaped name survives the URL" {
    const gpa = testing.allocator;
    const e = try urlEscape(gpa, "acetic acid");
    defer gpa.free(e);
    try testing.expectEqualStrings("acetic%20acid", e);
}
