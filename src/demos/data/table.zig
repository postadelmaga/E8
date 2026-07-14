//! A delimited table (CSV/TSV) read into columns, with the type of each column
//! inferred from its cells: numeric (every non-empty cell parses as a float) or
//! categorical (anything else — the distinct values become the categories).
//!
//! This is the universal front door of the framework: give it any table a
//! scientist already has, and the domain above turns numeric columns into the
//! coordinates of a point in R^k, a categorical column into the classes that
//! color and filter them, and a text column into the labels the HUD reads out.
//!
//! Deliberately dependency-free and forgiving: it sniffs the delimiter, tolerates
//! quoted cells and ragged rows, and never fails on a cell it cannot parse — that
//! cell simply makes its column categorical.

const std = @import("std");

pub const Kind = enum { numeric, categorical };

pub const Column = struct {
    name: []const u8,
    kind: Kind,
    /// Numeric columns: one value per row (NaN for a blank cell).
    nums: []f32 = &.{},
    /// Categorical columns: the row's category index into `cats`.
    codes: []u16 = &.{},
    /// Categorical columns: the distinct values, in first-seen order.
    cats: [][]const u8 = &.{},
};

pub const Table = struct {
    gpa: std.mem.Allocator,
    /// The whole file: every name/category slice points into it.
    text: []u8,
    /// Synthesized column names (a table with no header row).
    synth: []u8 = &.{},
    columns: []Column,
    rows: usize,
    /// Every row's cells, as slices into `text` — what the inspector reads out.
    cells: [][]const u8 = &.{},
    n_cols: usize = 0,

    pub fn deinit(t: *Table) void {
        for (t.columns) |c| {
            if (c.nums.len > 0) t.gpa.free(c.nums);
            if (c.codes.len > 0) t.gpa.free(c.codes);
            if (c.cats.len > 0) t.gpa.free(c.cats);
        }
        t.gpa.free(t.columns);
        if (t.cells.len > 0) t.gpa.free(t.cells);
        if (t.synth.len > 0) t.gpa.free(t.synth);
        t.gpa.free(t.text);
    }

    /// Cell (row, col) as text — for labels and the inspector's readout.
    pub fn cell(t: *const Table, row: usize, col: usize) []const u8 {
        const idx = row * t.n_cols + col;
        if (idx >= t.cells.len) return "";
        return t.cells[idx];
    }

    pub fn columnByName(t: *const Table, name: []const u8) ?usize {
        for (t.columns, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
        }
        return null;
    }
};

/// The delimiter is whichever of tab/semicolon/comma splits the first line into
/// the most fields — sniffing beats asking the user for a flag they'd forget.
fn sniffDelimiter(first_line: []const u8) u8 {
    var best: u8 = ',';
    var best_n: usize = 0;
    for ([_]u8{ '\t', ';', ',' }) |d| {
        var n: usize = 0;
        for (first_line) |c| {
            if (c == d) n += 1;
        }
        if (n > best_n) {
            best_n = n;
            best = d;
        }
    }
    return best;
}

fn trim(s: []const u8) []const u8 {
    var out = std.mem.trim(u8, s, " \t\r\n");
    if (out.len >= 2 and out[0] == '"' and out[out.len - 1] == '"') out = out[1 .. out.len - 1];
    return out;
}

/// Split one line on `delim`, honoring double quotes (a delimiter inside quotes
/// is part of the cell — the one CSV subtlety worth having).
fn splitRow(line: []const u8, delim: u8, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    var start: usize = 0;
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quotes = !in_quotes;
        if (c == delim and !in_quotes) {
            try out.append(gpa, trim(line[start..i]));
            start = i + 1;
        }
    }
    try out.append(gpa, trim(line[start..]));
}

fn parseNum(s: []const u8) ?f32 {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f32, s) catch null;
}

/// Read `path` as a delimited table. `max_rows` caps what we keep (a catalog of
/// millions is not something you orbit interactively).
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max_rows: usize) !Table {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024));
    errdefer gpa.free(text);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, "\r");
        if (l.len == 0) continue;
        if (l[0] == '#') continue; // comment lines: FITS-ish exports are full of them
        try lines.append(gpa, l);
        if (lines.items.len >= max_rows + 1) break; // enough for a header + max_rows data
    }
    if (lines.items.len == 0) return error.EmptyTable;

    const delim = sniffDelimiter(lines.items[0]);
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(gpa);
    try splitRow(lines.items[0], delim, &fields, gpa);
    const n_cols = fields.items.len;

    // A header row is one whose cells are not all numbers.
    var header = false;
    for (fields.items) |f| {
        if (parseNum(f) == null and f.len > 0) header = true;
    }
    const first_data: usize = if (header) 1 else 0;
    const rows = @min(lines.items.len - first_data, max_rows);
    if (rows == 0) return error.EmptyTable;

    // Names: the header's cells (they point into `text`), or synthesized ones in
    // a buffer the table owns — a name must outlive this call either way. The
    // fallbacks exist for every column: a header row may still leave cells empty.
    var synth: std.ArrayList(u8) = .empty;
    errdefer synth.deinit(gpa);
    var synth_at = try gpa.alloc([2]u32, n_cols); // (offset, len) into `synth`
    defer gpa.free(synth_at);
    for (0..n_cols) |c| {
        const off: u32 = @intCast(synth.items.len);
        try synth.print(gpa, "c{d}", .{c});
        synth_at[c] = .{ off, @intCast(synth.items.len - off) };
    }
    const synth_buf = try synth.toOwnedSlice(gpa);
    errdefer gpa.free(synth_buf);

    var columns = try gpa.alloc(Column, n_cols);
    errdefer gpa.free(columns);
    for (0..n_cols) |c| {
        const nm: []const u8 = if (header and c < fields.items.len and fields.items[c].len > 0)
            fields.items[c]
        else
            synth_buf[synth_at[c][0]..][0..synth_at[c][1]];
        columns[c] = .{ .name = nm, .kind = .numeric };
    }

    // Cells: one pass, kept as slices into `text`.
    const cells = try gpa.alloc([]const u8, rows * n_cols);
    errdefer gpa.free(cells);
    for (0..rows) |r| {
        try splitRow(lines.items[first_data + r], delim, &fields, gpa);
        for (0..n_cols) |c| {
            cells[r * n_cols + c] = if (c < fields.items.len) fields.items[c] else "";
        }
    }

    // Infer each column's kind, then fill it.
    for (0..n_cols) |c| {
        var numeric = true;
        var seen: usize = 0;
        for (0..rows) |r| {
            const s = cells[r * n_cols + c];
            if (s.len == 0) continue;
            seen += 1;
            if (parseNum(s) == null) {
                numeric = false;
                break;
            }
        }
        if (numeric and seen > 0) {
            const nums = try gpa.alloc(f32, rows);
            for (0..rows) |r| nums[r] = parseNum(cells[r * n_cols + c]) orelse std.math.nan(f32);
            columns[c].kind = .numeric;
            columns[c].nums = nums;
        } else {
            const codes = try gpa.alloc(u16, rows);
            var cats: std.ArrayList([]const u8) = .empty;
            for (0..rows) |r| {
                const s = cells[r * n_cols + c];
                var found: ?u16 = null;
                for (cats.items, 0..) |cat, k| {
                    if (std.mem.eql(u8, cat, s)) found = @intCast(k);
                }
                if (found == null and cats.items.len < 4096) {
                    try cats.append(gpa, s);
                    found = @intCast(cats.items.len - 1);
                }
                codes[r] = found orelse 0;
            }
            columns[c].kind = .categorical;
            columns[c].codes = codes;
            columns[c].cats = try cats.toOwnedSlice(gpa);
        }
    }

    return .{
        .gpa = gpa,
        .text = text,
        .synth = synth_buf,
        .columns = columns,
        .rows = rows,
        .cells = cells,
        .n_cols = n_cols,
    };
}
