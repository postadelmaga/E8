//! NumPy `.npy` reader — the format every embedding actually ships in.
//!
//! Only what an embedding matrix needs: version 1/2 headers, C order, 2-D shape,
//! little-endian float32/float64. Anything else — integer dtypes included — is
//! refused with a clear error rather than misread.

const std = @import("std");

pub const Matrix = struct {
    gpa: std.mem.Allocator,
    /// Row-major `rows`×`cols`, always f32 whatever the file held.
    data: []f32,
    rows: usize,
    cols: usize,

    pub fn deinit(m: *Matrix) void {
        m.gpa.free(m.data);
    }

    pub fn row(m: *const Matrix, r: usize) []const f32 {
        return m.data[r * m.cols ..][0..m.cols];
    }
};

const magic = "\x93NUMPY";

/// Pull `key: value` out of the header's Python dict literal.
fn headerValue(header: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, header, key) orelse return null;
    var i = at + key.len;
    while (i < header.len and (header[i] == ':' or header[i] == ' ' or header[i] == '\'')) i += 1;
    var j = i;
    while (j < header.len and header[j] != ',' and header[j] != '}' and header[j] != '\'') j += 1;
    return std.mem.trim(u8, header[i..j], " '");
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max_rows: usize) !Matrix {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 * 1024 * 1024 * 1024));
    defer gpa.free(bytes);
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..6], magic)) return error.NotNpy;

    const major = bytes[6];
    const hlen: usize = if (major == 1)
        std.mem.readInt(u16, bytes[8..10], .little)
    else
        std.mem.readInt(u32, bytes[8..12], .little);
    const hstart: usize = if (major == 1) 10 else 12;
    if (hstart + hlen > bytes.len) return error.BadNpyHeader;
    const header = bytes[hstart .. hstart + hlen];
    const body = bytes[hstart + hlen ..];

    const descr = headerValue(header, "descr") orelse return error.BadNpyHeader;
    const fortran = headerValue(header, "fortran_order") orelse "False";
    if (std.mem.startsWith(u8, fortran, "True")) return error.FortranOrderUnsupported;

    // shape: (rows, cols)
    const sh_at = std.mem.indexOf(u8, header, "shape") orelse return error.BadNpyHeader;
    const open = std.mem.indexOfScalarPos(u8, header, sh_at, '(') orelse return error.BadNpyHeader;
    const close = std.mem.indexOfScalarPos(u8, header, open, ')') orelse return error.BadNpyHeader;
    var dims: [4]usize = undefined;
    var n_dims: usize = 0;
    var it = std.mem.tokenizeAny(u8, header[open + 1 .. close], ", ");
    while (it.next()) |tok| {
        if (n_dims >= dims.len) break;
        dims[n_dims] = std.fmt.parseInt(usize, tok, 10) catch break;
        n_dims += 1;
    }
    if (n_dims == 0) return error.EmptyNpy;
    const rows_all = dims[0];
    const cols = if (n_dims >= 2) dims[1] else 1;
    const rows = @min(rows_all, max_rows);
    if (rows == 0 or cols == 0) return error.EmptyNpy;
    // The shape is untrusted input: a fabricated header must not overflow the
    // size arithmetic below, and no embedding is a million columns wide.
    if (cols > 1_000_000) return error.BadNpyHeader;

    const elem: usize = if (std.mem.endsWith(u8, descr, "f4"))
        4
    else if (std.mem.endsWith(u8, descr, "f8"))
        8
    else
        return error.UnsupportedDtype; // ints/objects: not an embedding matrix
    if (descr.len > 0 and descr[0] == '>') return error.BigEndianUnsupported;
    const cells = try std.math.mul(usize, rows, cols);
    if (body.len < try std.math.mul(usize, cells, elem)) return error.TruncatedNpy;

    const out = try gpa.alloc(f32, cells);
    errdefer gpa.free(out);
    for (0..cells) |i| {
        const off = i * elem;
        out[i] = if (elem == 4)
            @bitCast(std.mem.readInt(u32, body[off..][0..4], .little))
        else
            @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, body[off..][0..8], .little))));
    }
    return .{ .gpa = gpa, .data = out, .rows = rows, .cols = cols };
}
