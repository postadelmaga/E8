//! Graph readers: GraphML (what Gephi, NetworkX and igraph all export) and the
//! plain edge list every lab has lying around (`a b` per line, any whitespace,
//! `#` comments). Both land in the same node/edge pair.
//!
//! GraphML is parsed as tags, not as XML: we want `<node id=…>` and `<edge
//! source=… target=…>` and the optional `<data key=…>label</data>` under a node.
//! That is all a layout needs, and it never fails on a namespace it has not seen.

const std = @import("std");

pub const Graph = struct {
    gpa: std.mem.Allocator,
    /// The file, kept alive: every label points into it.
    text: []u8,
    /// Node names, in the order first seen.
    names: [][]const u8,
    edges: [][2]u16,
    directed: bool,

    pub fn deinit(g: *Graph) void {
        g.gpa.free(g.names);
        g.gpa.free(g.edges);
        g.gpa.free(g.text);
    }
};

const Nodes = struct {
    map: std.StringHashMap(u16),
    names: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
    max: usize,

    fn init(gpa: std.mem.Allocator, max: usize) Nodes {
        return .{ .map = .init(gpa), .names = .empty, .gpa = gpa, .max = max };
    }
    fn deinit(n: *Nodes) void {
        n.map.deinit();
        n.names.deinit(n.gpa);
    }
    /// The index of `name`, adding it if this is the first time we see it.
    fn intern(n: *Nodes, name: []const u8) !?u16 {
        if (n.map.get(name)) |i| return i;
        if (n.names.items.len >= n.max) return null;
        const idx: u16 = @intCast(n.names.items.len);
        try n.names.append(n.gpa, name);
        try n.map.put(name, idx);
        return idx;
    }
};

/// The value of `attr="…"` inside one tag.
fn attr(tag: []const u8, key: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "{s}=\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, tag, pat) orelse return null;
    const start = at + pat.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

fn loadGraphml(gpa: std.mem.Allocator, text: []u8, max_nodes: usize) !Graph {
    var nodes = Nodes.init(gpa, max_nodes);
    defer nodes.deinit();
    var edges: std.ArrayList([2]u16) = .empty;
    errdefer edges.deinit(gpa);
    var directed = false;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, text, lt, '>') orelse break;
        const tag = text[lt + 1 .. gt];
        i = gt + 1;
        if (std.mem.startsWith(u8, tag, "graph")) {
            if (attr(tag, "edgedefault")) |d| directed = std.mem.eql(u8, d, "directed");
        } else if (std.mem.startsWith(u8, tag, "node")) {
            if (attr(tag, "id")) |id| _ = try nodes.intern(id);
        } else if (std.mem.startsWith(u8, tag, "edge")) {
            const s = attr(tag, "source") orelse continue;
            const t = attr(tag, "target") orelse continue;
            const a = (try nodes.intern(s)) orelse continue;
            const b = (try nodes.intern(t)) orelse continue;
            if (a != b) try edges.append(gpa, .{ @min(a, b), @max(a, b) });
        }
    }
    return .{
        .gpa = gpa,
        .text = text,
        .names = try nodes.names.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
        .directed = directed,
    };
}

fn loadEdgeList(gpa: std.mem.Allocator, text: []u8, max_nodes: usize) !Graph {
    var nodes = Nodes.init(gpa, max_nodes);
    defer nodes.deinit();
    var edges: std.ArrayList([2]u16) = .empty;
    errdefer edges.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '%') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t,;");
        const s = f.next() orelse continue;
        const t = f.next() orelse continue;
        const a = (try nodes.intern(s)) orelse continue;
        const b = (try nodes.intern(t)) orelse continue;
        if (a != b) try edges.append(gpa, .{ @min(a, b), @max(a, b) });
    }
    return .{
        .gpa = gpa,
        .text = text,
        .names = try nodes.names.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
        .directed = false,
    };
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max_nodes: usize) !Graph {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024));
    errdefer gpa.free(text);
    const xml = std.mem.endsWith(u8, path, ".graphml") or std.mem.endsWith(u8, path, ".xml") or
        std.mem.indexOf(u8, text[0..@min(text.len, 2048)], "<graphml") != null;
    var g = if (xml) try loadGraphml(gpa, text, max_nodes) else try loadEdgeList(gpa, text, max_nodes);
    errdefer g.deinit();
    if (g.names.len == 0) return error.EmptyGraph;

    // Deduplicate: an undirected edge written twice is one edge.
    std.sort.pdq([2]u16, g.edges, {}, struct {
        fn lt(_: void, a: [2]u16, b: [2]u16) bool {
            return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
        }
    }.lt);
    var w: usize = 0;
    for (g.edges, 0..) |e, r| {
        if (r > 0 and e[0] == g.edges[r - 1][0] and e[1] == g.edges[r - 1][1]) continue;
        g.edges[w] = e;
        w += 1;
    }
    // Shrink through the allocator: `deinit` frees exactly what it holds.
    g.edges = try gpa.realloc(g.edges, w);
    return g;
}
