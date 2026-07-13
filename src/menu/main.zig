//! The launcher: the way in when you are not holding a build command.
//!
//! It picks a demo and RUNS it — as a separate process. That is not a shortcut, it
//! is what the architecture requires: a demo's point type and its dimension are
//! comptime (`geom.Vec = [dim]f32`), so `lisi` in 8D and `chem` in 3D are different
//! programs, `e8-lisi` and `e8-chem`. One process cannot be both. It can, however,
//! start either — so the launcher has no domain at all, links no engine, and is
//! just a window, a list, and `std.process.Child`.
//!
//! It also AUTHORS. A demo made here is nothing but a directory:
//!
//!     demos-user/mia-proteina/
//!       manifest.zon    .{ .name = "…", .domain = "chem", .asset = "1ubq.pdb" }
//!       1ubq.pdb        the data
//!       deck.zon        the slides
//!
//! and the domains that read files already exist — `chem` reads PDB and XYZ,
//! `astro` reads star catalogs, `data` any CSV. So authoring is not inventing a
//! demo: it is choosing which of the existing ones should look at your data, and
//! then writing the slides (which the demo's own editor does, `--editor`).
//!
//! For chemistry the asset does not even have to be yours. PubChem and RCSB hold
//! the molecule already; `fetch.zig` goes and gets it.

const std = @import("std");
const zrame = @import("zrame");
const widget = zrame.widget;
const fetch = @import("fetch.zig");
const browse = @import("browse.zig");
const deck_write = @import("deck_write");

// --- what there is to open -------------------------------------------------------------------

const Category = struct {
    label: []const u8,
    /// The domain that reads this kind of thing.
    domain: []const u8,
    /// What its asset looks like ("" = it has none: the points are computed).
    asset: []const u8,
    /// Which specialized tool the wizard offers.
    tool: enum { none, molecule, file },
};

/// The categories, and the tools each one gets. Every entry is a domain that
/// already exists — the wizard picks one, it does not create one.
const categories = [_]Category{
    .{ .label = "Chimica e biologia molecolare", .domain = "chem", .asset = "PDB, XYZ", .tool = .molecule },
    .{ .label = "Astronomia (cataloghi stellari)", .domain = "astro", .asset = "CSV (Gaia, SIMBAD, HYG)", .tool = .file },
    .{ .label = "Reti e grafi", .domain = "graph", .asset = "GraphML, lista di archi", .tool = .file },
    .{ .label = "Dati e tabelle", .domain = "data", .asset = "CSV, TSV", .tool = .file },
    .{ .label = "Embeddings / ML", .domain = "embed", .asset = ".npy, CSV", .tool = .file },
    .{ .label = "Matematica e fisica (solo slide)", .domain = "lisi", .asset = "", .tool = .none },
};

const Builtin = struct {
    domain: []const u8,
    title: []const u8,
    blurb: []const u8,
    /// A demo whose points come from a file cannot be opened without one.
    needs_asset: bool = false,
};

const builtins = [_]Builtin{
    .{ .domain = "lisi", .title = "Lisi — E8", .blurb = "Le 240 radici di E8, una per particella elementare. La figura di Coxeter." },
    .{ .domain = "mtheory", .title = "M-teoria — E10", .blurb = "E10, i campi della supergravita' a 11 dimensioni, il Calabi-Yau e il big bang di Damour-Nicolai." },
    .{ .domain = "polytope", .title = "Politopo 24-celle", .blurb = "Un politopo regolare in 4 dimensioni, ruotato in R4." },
    .{ .domain = "molecule", .title = "Molecola (giocattolo)", .blurb = "Quattordici atomi, per capire il framework in due minuti." },
    .{ .domain = "chem", .title = "Chimica — PDB / XYZ", .blurb = "Una struttura molecolare vera: catene, residui, il righello in angstrom.", .needs_asset = true },
    .{ .domain = "astro", .title = "Astronomia — catalogo", .blurb = "Un catalogo stellare nello spazio che occupa davvero, con il diagramma H-R.", .needs_asset = true },
    .{ .domain = "graph", .title = "Grafi — GraphML", .blurb = "Una rete disposta dal suo spettro laplaciano.", .needs_asset = true },
    .{ .domain = "data", .title = "Dati — CSV", .blurb = "Qualunque tabella, sui suoi assi principali.", .needs_asset = true },
    .{ .domain = "embed", .title = "Embeddings — .npy", .blurb = "PCA e t-SNE nello stesso punto.", .needs_asset = true },
};

/// A demo the user made: a directory with a manifest.
const Manifest = struct {
    name: []const u8,
    domain: []const u8,
    asset: []const u8 = "",
};

const UserDemo = struct {
    dir: []const u8, // demos-user/<slug>
    name: []const u8,
    domain: []const u8,
    asset: []const u8,
};

const user_root = "demos-user";

// --- the launcher's state ----------------------------------------------------------------------

const Menu = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The environment this process was started with. It has to be handed to every
    /// child EXPLICITLY: `std.process.spawn` with `environ_map = null` does not
    /// inherit it, it gives the child NOTHING — and a demo without XDG_RUNTIME_DIR
    /// and WAYLAND_DISPLAY cannot open a window, so it died on the spot and the
    /// launcher looked like it had never launched anything at all.
    env: *const std.process.Environ.Map,

    mine: std.ArrayList(UserDemo) = .empty,
    mine_loaded: bool = false,

    /// Hover, one animated 0..1 per poster, keyed by the card's index in the frame.
    /// The toolkit keeps its own hover animation, but only for its own widgets — a
    /// hand-drawn card has to remember it here.
    hov: [96]f32 = @splat(0),

    // the wizard
    cat: usize = 0,
    demo_name: std.ArrayList(u8) = .empty,
    molecule: std.ArrayList(u8) = .empty,
    pdb_id: std.ArrayList(u8) = .empty,
    picker: browse.Browser,
    /// The asset the wizard has secured, ready to be copied into the new demo.
    asset_path: std.ArrayList(u8) = .empty,
    /// Downloaded bytes, when the asset came from the network rather than the disk.
    got: ?fetch.Asset = null,

    note: std.ArrayList(u8) = .empty,
    /// A download runs on its own thread: the UI must not freeze on the network.
    job: Job = .{},
    /// The wizard finished and the dialog should go away — `createDemo` runs deep
    /// inside the dialog's body and has no `ui` to close it with.
    wizard_done: bool = false,
    /// A poster asked for the wizard. It cannot open it itself: `openDialog` hashes
    /// the dialog's name against the CURRENT id scope, and a card runs inside its
    /// own `pushIdScopeIndex` — so the id it registered was one nothing would ever
    /// look up again, and the dialog silently never appeared. The request is carried
    /// out at the root scope instead, where `dialogOpen` will recognize it.
    wizard_wanted: bool = false,

    fn say(m: *Menu, msg: []const u8) void {
        m.note.clearRetainingCapacity();
        m.note.appendSlice(m.gpa, msg) catch {};
    }
    fn sayFmt(m: *Menu, comptime f: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        m.say(std.fmt.bufPrint(&buf, f, args) catch "…");
    }
};

/// The network, off the UI thread. `state` is the whole handshake.
const Job = struct {
    state: std.atomic.Value(u8) = .init(0), // 0 idle · 1 running · 2 done · 3 failed
    thread: ?std.Thread = null,
    asset: ?fetch.Asset = null,
    err: [96]u8 = undefined,
    elen: usize = 0,
};

const JobArgs = struct {
    m: *Menu,
    kind: enum { pubchem, rcsb },
    query: []u8, // owned by the job
};

fn jobRun(args: *JobArgs) void {
    const m = args.m;
    const gpa = m.gpa;
    defer {
        gpa.free(args.query);
        gpa.destroy(args);
    }
    const r = switch (args.kind) {
        .pubchem => fetch.pubchem(gpa, m.io, args.query),
        .rcsb => fetch.rcsb(gpa, m.io, args.query),
    };
    if (r) |asset| {
        m.job.asset = asset;
        m.job.state.store(2, .release);
    } else |e| {
        const msg = switch (e) {
            error.NotFound => "non trovato",
            error.NoAtoms => "il file non contiene atomi leggibili",
            else => @errorName(e),
        };
        const n = @min(msg.len, m.job.err.len);
        @memcpy(m.job.err[0..n], msg[0..n]);
        m.job.elen = n;
        m.job.state.store(3, .release);
    }
}

fn startJob(m: *Menu, kind: @FieldType(JobArgs, "kind"), query: []const u8) void {
    if (m.job.state.load(.acquire) == 1) return; // one at a time
    if (query.len == 0) {
        m.say("scrivi prima cosa cercare");
        return;
    }
    const args = m.gpa.create(JobArgs) catch return;
    args.* = .{
        .m = m,
        .kind = kind,
        .query = m.gpa.dupe(u8, query) catch {
            m.gpa.destroy(args);
            return;
        },
    };
    m.job.state.store(1, .release);
    m.job.thread = std.Thread.spawn(.{}, jobRun, .{args}) catch {
        m.job.state.store(0, .release);
        m.gpa.free(args.query);
        m.gpa.destroy(args);
        m.say("non riesco ad avviare il download");
        return;
    };
    m.say("scarico…");
}

/// Collect a finished download on the UI thread — the only place the result is read.
fn reapJob(m: *Menu) void {
    switch (m.job.state.load(.acquire)) {
        2 => {
            if (m.job.thread) |t| t.join();
            m.job.thread = null;
            if (m.got) |g| g.deinit(m.gpa);
            m.got = m.job.asset;
            m.job.asset = null;
            m.job.state.store(0, .release);
            m.asset_path.clearRetainingCapacity();
            if (m.got) |g| {
                m.sayFmt("scaricato: {s} ({d} byte)", .{ g.name, g.bytes.len });
                // A downloaded molecule names the demo, unless you already did.
                if (m.demo_name.items.len == 0) {
                    const stem = std.fs.path.stem(g.name);
                    m.demo_name.appendSlice(m.gpa, stem) catch {};
                }
            }
        },
        3 => {
            if (m.job.thread) |t| t.join();
            m.job.thread = null;
            m.job.state.store(0, .release);
            m.sayFmt("download fallito: {s}", .{m.job.err[0..m.job.elen]});
        },
        else => {},
    }
}

// --- launching a demo ---------------------------------------------------------------------------

/// Run `e8-<domain>` — the sibling of this executable, so the launcher works from
/// wherever it was installed, not only from the build directory.
fn launch(m: *Menu, domain: []const u8, asset: ?[]const u8, deck: ?[]const u8, editor: bool) void {
    const gpa = m.gpa;
    // The sibling binary, found through this one: the launcher must work from
    // wherever it was installed, not only from the build directory.
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(m.io, "/proc/self/exe", &self_buf) catch {
        m.say("non trovo la cartella degli eseguibili");
        return;
    };
    const dir = std.fs.path.dirname(self_buf[0..n]) orelse ".";
    const exe = std.fmt.allocPrint(gpa, "{s}/e8-{s}", .{ dir, domain }) catch return;
    defer gpa.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, exe) catch return;
    if (asset) |a| {
        if (a.len > 0) argv.append(gpa, a) catch return;
    }
    var deck_arg: ?[]u8 = null;
    defer if (deck_arg) |d| gpa.free(d);
    if (deck) |d| {
        deck_arg = std.fmt.allocPrint(gpa, "--deck={s}", .{d}) catch return;
        argv.append(gpa, deck_arg.?) catch return;
    }
    if (editor) argv.append(gpa, "--editor") catch return;
    argv.append(gpa, "--gpu") catch return;

    _ = std.process.spawn(m.io, .{
        .argv = argv.items,
        .environ_map = m.env,
        .stdin = .ignore,
    }) catch |e| {
        m.sayFmt("non parte: {s} ({s})", .{ exe, @errorName(e) });
        return;
    };
    // Deliberately not waited on: the demo is a sibling window, not a subroutine.
    // The launcher stays open so you can start another.
    m.sayFmt("aperto {s}", .{domain});
}

// --- the user's demos on disk ---------------------------------------------------------------------

fn loadMine(m: *Menu) void {
    const gpa = m.gpa;
    for (m.mine.items) |d| {
        gpa.free(d.dir);
        gpa.free(d.name);
        gpa.free(d.domain);
        gpa.free(d.asset);
    }
    m.mine.clearRetainingCapacity();
    m.mine_loaded = true;

    var root = std.Io.Dir.cwd().openDir(m.io, user_root, .{ .iterate = true }) catch return;
    defer root.close(m.io);
    var it = root.iterate();
    while (it.next(m.io) catch return) |entry| {
        if (entry.kind != .directory) continue;
        const path = std.fmt.allocPrint(gpa, "{s}/{s}/manifest.zon", .{ user_root, entry.name }) catch continue;
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAllocOptions(m.io, path, gpa, .limited(1 << 16), .of(u8), 0) catch continue;
        defer gpa.free(bytes);
        const man = std.zon.parse.fromSliceAlloc(Manifest, gpa, bytes, null, .{ .ignore_unknown_fields = true }) catch continue;
        defer std.zon.parse.free(gpa, man);

        const d: UserDemo = .{
            .dir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ user_root, entry.name }) catch continue,
            .name = gpa.dupe(u8, man.name) catch continue,
            .domain = gpa.dupe(u8, man.domain) catch continue,
            .asset = gpa.dupe(u8, man.asset) catch continue,
        };
        m.mine.append(gpa, d) catch {
            gpa.free(d.dir);
            gpa.free(d.name);
            gpa.free(d.domain);
            gpa.free(d.asset);
        };
    }
}

/// Write the demo out: the directory, the manifest, the asset, and a deck with one
/// slide to start from. Then open it in the editor — which is the point.
fn createDemo(m: *Menu) void {
    const gpa = m.gpa;
    const cat = categories[m.cat];

    if (m.demo_name.items.len == 0) {
        m.say("dai un nome alla demo");
        return;
    }
    const needs_asset = cat.asset.len > 0;
    const from_net = m.got != null;
    if (needs_asset and !from_net and m.asset_path.items.len == 0) {
        m.say("scegli un file, o scaricane uno");
        return;
    }

    const slug = fetch.slugify(gpa, m.demo_name.items) catch return;
    defer gpa.free(slug);
    const dir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ user_root, slug }) catch return;
    defer gpa.free(dir);

    std.Io.Dir.cwd().createDirPath(m.io, dir) catch |e| {
        m.sayFmt("non riesco a creare {s}: {s}", .{ dir, @errorName(e) });
        return;
    };

    // The asset: either the bytes we downloaded, or a copy of the file you picked.
    var asset_rel: ?[]u8 = null;
    defer if (asset_rel) |a| gpa.free(a);
    if (needs_asset) {
        const base = if (from_net) m.got.?.name else std.fs.path.basename(m.asset_path.items);
        asset_rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, base }) catch return;
        if (from_net) {
            std.Io.Dir.cwd().writeFile(m.io, .{ .sub_path = asset_rel.?, .data = m.got.?.bytes }) catch |e| {
                m.sayFmt("non riesco a scrivere l'asset: {s}", .{@errorName(e)});
                return;
            };
        } else {
            std.Io.Dir.cwd().copyFile(m.asset_path.items, std.Io.Dir.cwd(), asset_rel.?, m.io, .{}) catch |e| {
                m.sayFmt("non riesco a copiare l'asset: {s}", .{@errorName(e)});
                return;
            };
        }
    }

    // The name goes into two .zon files as a string literal, and it is whatever the
    // author typed — a quote or a backslash in it would leave behind a demo that
    // nothing can parse, including the launcher that wrote it.
    const name_zon = deck_write.escapeAlloc(gpa, m.demo_name.items) catch return;
    defer gpa.free(name_zon);

    // The manifest.
    {
        const man = std.fmt.allocPrint(gpa,
            \\// Una demo. Il launcher la legge da qui; l'editor scrive deck.zon.
            \\.{{
            \\    .name = "{s}",
            \\    .domain = "{s}",
            \\    .asset = "{s}",
            \\}}
            \\
        , .{
            name_zon,
            cat.domain,
            if (asset_rel) |a| std.fs.path.basename(a) else "",
        }) catch return;
        defer gpa.free(man);
        const p = std.fmt.allocPrint(gpa, "{s}/manifest.zon", .{dir}) catch return;
        defer gpa.free(p);
        std.Io.Dir.cwd().writeFile(m.io, .{ .sub_path = p, .data = man }) catch return;
    }

    // The deck: one slide, so the editor opens onto something rather than nothing.
    const deck_path = std.fmt.allocPrint(gpa, "{s}/deck.zon", .{dir}) catch return;
    defer gpa.free(deck_path);
    {
        const d = std.fmt.allocPrint(gpa,
            \\// Le slide di "{s}". L'editor riscrive questo file; F5 lo ricarica.
            \\.{{
            \\    .slides = .{{
            \\        .{{
            \\            .title = "{s}",
            \\            .body = "Scrivi qui. Premi O nella demo per aprire l'editor: la scena accanto e' l'anteprima, e il bottone \"cattura camera\" prende l'inquadratura che stai guardando.",
            \\            .preset = "",
            \\        }},
            \\    }},
            \\}}
            \\
        , .{ slug, name_zon }) catch return;
        defer gpa.free(d);
        std.Io.Dir.cwd().writeFile(m.io, .{ .sub_path = deck_path, .data = d }) catch return;
    }

    m.mine_loaded = false; // it will show up among the posters
    m.wizard_done = true; // and the dialog has nothing left to ask
    launch(m, cat.domain, if (asset_rel) |a| a else null, deck_path, true);
}

// --- the UI: a wall of posters --------------------------------------------------------------------
//
// A launcher is a shelf, not a form. What a person wants to see when it opens is
// WHAT THEY CAN WATCH — so the window is a grid of posters, one per demo, and a
// click on a poster plays it. The tabs, the buttons and the lists are gone; the
// wizard is where it belongs, behind a "+ Nuova demo" card, in a dialog.
//
// The posters are DRAWN, not loaded. A thumbnail file per demo would be a build
// artifact to keep in sync with a scene it only approximates; instead each domain
// gets a few lines of `ui.canvas` — roots on their rings, atoms and bonds, a star
// field, a graph, two t-SNE blobs — deterministic from the card's own index, so the
// same demo always wears the same face. It costs nothing and it never goes stale.

const Art = enum { roots, e10, polytope, mol, chem, astro, graph, data, embed, plus };

const card_w: f32 = 210;
const card_h: f32 = 176;
const poster_h: f32 = 112;

/// The palette a poster is painted in: the two ends of its background gradient, and
/// the ink its shapes are drawn with.
fn palette(a: Art) struct { top: zrame.Color, bot: zrame.Color, ink: zrame.Color, ink2: zrame.Color } {
    return switch (a) {
        .roots => .{ .top = c(30, 40, 84), .bot = c(10, 12, 30), .ink = c(150, 205, 255), .ink2 = c(255, 190, 120) },
        .e10 => .{ .top = c(52, 26, 82), .bot = c(12, 8, 26), .ink = c(206, 160, 255), .ink2 = c(120, 230, 240) },
        .polytope => .{ .top = c(20, 60, 74), .bot = c(8, 18, 26), .ink = c(130, 240, 230), .ink2 = c(255, 255, 255) },
        .mol => .{ .top = c(64, 40, 26), .bot = c(20, 12, 10), .ink = c(255, 190, 130), .ink2 = c(230, 240, 255) },
        .chem => .{ .top = c(24, 62, 44), .bot = c(8, 20, 16), .ink = c(150, 240, 190), .ink2 = c(255, 140, 120) },
        .astro => .{ .top = c(14, 22, 54), .bot = c(4, 5, 14), .ink = c(255, 255, 255), .ink2 = c(255, 205, 130) },
        .graph => .{ .top = c(58, 30, 58), .bot = c(16, 8, 20), .ink = c(255, 160, 220), .ink2 = c(130, 200, 255) },
        .data => .{ .top = c(28, 48, 66), .bot = c(8, 16, 24), .ink = c(120, 210, 255), .ink2 = c(255, 200, 120) },
        .embed => .{ .top = c(30, 56, 52), .bot = c(8, 18, 18), .ink = c(140, 240, 210), .ink2 = c(255, 170, 200) },
        .plus => .{ .top = c(38, 38, 44), .bot = c(14, 14, 18), .ink = c(200, 210, 230), .ink2 = c(200, 210, 230) },
    };
}

fn c(r: u8, g: u8, b: u8) zrame.Color {
    return zrame.Color.rgba(r, g, b, 1);
}

fn artOf(domain: []const u8) Art {
    const eq = std.mem.eql;
    if (eq(u8, domain, "lisi")) return .roots;
    if (eq(u8, domain, "mtheory")) return .e10;
    if (eq(u8, domain, "polytope")) return .polytope;
    if (eq(u8, domain, "molecule")) return .mol;
    if (eq(u8, domain, "chem")) return .chem;
    if (eq(u8, domain, "astro")) return .astro;
    if (eq(u8, domain, "graph")) return .graph;
    if (eq(u8, domain, "data")) return .data;
    if (eq(u8, domain, "embed")) return .embed;
    return .plus;
}

/// A deterministic little noise source: the same card draws the same face on every
/// frame and in every session, without storing a single pixel.
const Rng = struct {
    s: u32,
    fn next(r: *Rng) f32 {
        r.s = r.s *% 1664525 +% 1013904223;
        return @as(f32, @floatFromInt(r.s >> 8)) / 16777216.0; // 0..1
    }
    fn range(r: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * r.next();
    }
};

fn dot(ui: *widget.Ui, x: f32, y: f32, rad: f32, col: zrame.Color) void {
    ui.canvas.fillRoundedRect(x - rad, y - rad, 2 * rad, 2 * rad, rad, col);
}

/// A poster's title has to fit the poster: the toolkit's own text wraps to the
/// layout, but these are drawn straight onto the canvas, where nothing stops them
/// from running into the next card. So they are cut — on a UTF-8 boundary, with an
/// ellipsis, at whatever the card is actually wide enough to say.
fn fit(ui: *widget.Ui, s: []const u8, size: u16, style: zrame.TextStyle, max_w: f32, buf: []u8) []const u8 {
    if (ui.measureText(s, size, style) <= max_w) return s;
    const dots = "…";
    const dots_w = ui.measureText(dots, size, style);
    var end: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const step = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const next = @min(i + step, s.len);
        if (ui.measureText(s[0..next], size, style) + dots_w > max_w) break;
        end = next;
        i = next;
    }
    if (end + dots.len > buf.len) return s[0..@min(s.len, buf.len)];
    @memcpy(buf[0..end], s[0..end]);
    @memcpy(buf[end..][0..dots.len], dots);
    return buf[0 .. end + dots.len];
}

/// The poster itself: a gradient, and a sketch of what the demo actually shows. `t`
/// is the hover factor — the art brightens as the pointer comes to rest on it, the
/// way a thumbnail begins to play.
fn poster(ui: *widget.Ui, r: widget.Rect, a: Art, seed: u32, t: f32) void {
    const p = palette(a);
    const top = zrame.Color.lerp(p.top, c(255, 255, 255), 0.10 * t);
    ui.canvas.fillRoundedRectVGradient(r.x, r.y, r.w, r.h, 12, top, p.bot);

    const ink = zrame.Color.lerp(p.ink, c(255, 255, 255), 0.35 * t);
    const ink2 = p.ink2;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    var rng = Rng{ .s = seed *% 2654435761 +% 12345 };

    switch (a) {
        // The Coxeter rosette: concentric rings of roots, and a few of the chords
        // between them. It is, quite literally, what the demo opens on.
        .roots, .e10 => {
            const rings = [_]struct { rad: f32, n: usize }{
                .{ .rad = 0.20, .n = 6 },
                .{ .rad = 0.38, .n = 12 },
                .{ .rad = 0.56, .n = 18 },
            };
            const unit = @min(r.w, r.h);
            for (rings, 0..) |ring, ri| {
                const rad = ring.rad * unit;
                var i: usize = 0;
                while (i < ring.n) : (i += 1) {
                    const th = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ring.n)) + 0.3 * @as(f32, @floatFromInt(ri));
                    const x = cx + rad * @cos(th);
                    const y = cy + rad * @sin(th) * 0.72; // the projection is not a circle
                    if (i % 4 == 0) {
                        const th2 = th + std.math.tau / 3.0;
                        ui.canvas.strokeSegment(x, y, cx + rad * @cos(th2), cy + rad * @sin(th2) * 0.72, 1, ink.withAlpha(0.22));
                    }
                    dot(ui, x, y, if (ri == 2) 2.0 else 2.6, if (i % 5 == 0) ink2 else ink);
                }
            }
            if (a == .e10) { // E10's light cone: the two null directions
                ui.canvas.strokeSegment(cx - 0.44 * r.w, cy + 0.30 * r.h, cx + 0.44 * r.w, cy - 0.30 * r.h, 1.5, ink2.withAlpha(0.5));
                ui.canvas.strokeSegment(cx - 0.44 * r.w, cy - 0.30 * r.h, cx + 0.44 * r.w, cy + 0.30 * r.h, 1.5, ink2.withAlpha(0.5));
            }
        },
        // The 24-cell: two squares out of phase, and the edges between them.
        .polytope => {
            const rad = 0.34 * @min(r.w, r.h);
            var prev: [8][2]f32 = undefined;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const th = std.math.tau * @as(f32, @floatFromInt(i)) / 8.0 + 0.2;
                const k: f32 = if (i % 2 == 0) 1.0 else 0.62;
                prev[i] = .{ cx + rad * k * @cos(th), cy + rad * k * @sin(th) * 0.8 };
            }
            for (prev, 0..) |v, j| {
                const w = prev[(j + 1) % 8];
                const z = prev[(j + 3) % 8];
                ui.canvas.strokeSegment(v[0], v[1], w[0], w[1], 1.4, ink.withAlpha(0.75));
                ui.canvas.strokeSegment(v[0], v[1], z[0], z[1], 1, ink.withAlpha(0.28));
            }
            for (prev) |v| dot(ui, v[0], v[1], 3, ink2);
        },
        // Atoms and bonds — a ring with substituents, the shape of every molecule
        // anyone has ever drawn on a napkin.
        .mol, .chem => {
            const n: usize = if (a == .chem) 9 else 6;
            const rad = 0.26 * @min(r.w, r.h);
            var pts: [12][2]f32 = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const th = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                const k = if (a == .chem) rng.range(0.7, 1.45) else 1.0;
                pts[i] = .{ cx + rad * k * @cos(th), cy + rad * k * @sin(th) * 0.85 };
            }
            i = 0;
            while (i < n) : (i += 1) {
                const j = (i + 1) % n;
                ui.canvas.strokeSegment(pts[i][0], pts[i][1], pts[j][0], pts[j][1], 1.6, ink.withAlpha(0.55));
            }
            i = 0;
            while (i < n) : (i += 1) {
                dot(ui, pts[i][0], pts[i][1], if (i % 3 == 0) 5.5 else 4, if (i % 3 == 0) ink2 else ink);
            }
        },
        // A star field, with the two or three that carry a name.
        .astro => {
            var i: usize = 0;
            while (i < 90) : (i += 1) {
                const x = rng.range(r.x + 6, r.x + r.w - 6);
                const y = rng.range(r.y + 6, r.y + r.h - 6);
                const b = rng.next();
                dot(ui, x, y, 0.6 + 1.6 * b * b, ink.withAlpha(0.25 + 0.75 * b));
            }
            i = 0;
            while (i < 3) : (i += 1) {
                const x = rng.range(r.x + 20, r.x + r.w - 20);
                const y = rng.range(r.y + 16, r.y + r.h - 16);
                dot(ui, x, y, 3.4, ink2);
                ui.canvas.strokeSegment(x - 8, y, x + 8, y, 1, ink2.withAlpha(0.35));
                ui.canvas.strokeSegment(x, y - 8, x, y + 8, 1, ink2.withAlpha(0.35));
            }
        },
        // Three communities and the edges that betray them — a spectral layout in
        // miniature.
        .graph => {
            var pts: [18][2]f32 = undefined;
            const hubs = [_][2]f32{
                .{ cx - 0.26 * r.w, cy - 0.14 * r.h },
                .{ cx + 0.24 * r.w, cy - 0.18 * r.h },
                .{ cx - 0.02 * r.w, cy + 0.22 * r.h },
            };
            for (0..18) |i| {
                const h = hubs[i % 3];
                pts[i] = .{ h[0] + rng.range(-22, 22), h[1] + rng.range(-16, 16) };
            }
            for (0..18) |i| {
                const j = (i + 3) % 18;
                const same = (i % 3) == (j % 3);
                ui.canvas.strokeSegment(pts[i][0], pts[i][1], pts[j][0], pts[j][1], 1, (if (same) ink else ink2).withAlpha(if (same) 0.45 else 0.18));
            }
            for (0..18) |i| dot(ui, pts[i][0], pts[i][1], if (i < 3) 4.5 else 2.8, if (i < 3) ink2 else ink);
        },
        // A scatter on its principal axes: three classes, and the axes themselves.
        .data, .embed => {
            const centers = [_][2]f32{
                .{ cx - 0.22 * r.w, cy + 0.10 * r.h },
                .{ cx + 0.06 * r.w, cy - 0.14 * r.h },
                .{ cx + 0.26 * r.w, cy + 0.16 * r.h },
            };
            for (0..80) |i| {
                const k = i % 3;
                const h = centers[k];
                const spread: f32 = if (a == .embed) 16 else 22;
                const x = h[0] + rng.range(-spread, spread);
                const y = h[1] + rng.range(-spread * 0.7, spread * 0.7);
                dot(ui, x, y, 2.2, switch (k) {
                    0 => ink,
                    1 => ink2,
                    else => zrame.Color.lerp(ink, ink2, 0.5),
                });
            }
            if (a == .data) {
                ui.canvas.strokeSegment(r.x + 14, r.y + r.h - 16, r.x + r.w - 14, r.y + r.h - 16, 1, ink.withAlpha(0.3));
                ui.canvas.strokeSegment(r.x + 14, r.y + 12, r.x + 14, r.y + r.h - 16, 1, ink.withAlpha(0.3));
            }
        },
        // The new demo: a plus, and nothing else to say.
        .plus => {
            const s: f32 = 16;
            ui.canvas.strokeSegment(cx - s, cy, cx + s, cy, 2.5, ink.withAlpha(0.75));
            ui.canvas.strokeSegment(cx, cy - s, cx, cy + s, 2.5, ink.withAlpha(0.75));
            ui.canvas.strokeRoundedRect(cx - 34, cy - 34, 68, 68, 16, 1.2, ink.withAlpha(0.25));
        },
    }
    // The scrim: posters carry text, and text on a picture needs a floor to stand on.
    ui.canvas.fillRoundedRectVGradient(r.x, r.y + r.h * 0.55, r.w, r.h * 0.45, 10, zrame.Color.rgba(0, 0, 0, 0), zrame.Color.rgba(0, 0, 0, 0.55));
}

/// What a click on a card asked for.
const Pick = enum { none, play, edit };

/// One poster: art, title, subtitle, and — once the pointer is on it — the two
/// things you can do with it. The whole card is the play button (that is the point
/// of a poster); the pencil in the corner opens the same demo in the editor.
fn card(
    ui: *widget.Ui,
    m: *Menu,
    slot: usize,
    art: Art,
    title: []const u8,
    sub: []const u8,
    editable: bool,
) Pick {
    const t_theme = ui.theme;
    const r = ui.allocRect(card_w, card_h);

    const id = ui.makeId("card");
    const edit_id = ui.makeId("card_edit");

    // The pencil interacts FIRST: `interact` gives the press to whoever claims it,
    // so asking in this order is what keeps a click on the pencil from also being a
    // click on the poster underneath it.
    var pick: Pick = .none;
    const pencil = widget.Rect{ .x = r.x + card_w - 34, .y = r.y + 8, .w = 26, .h = 26 };
    const esig = if (editable) ui.interact(edit_id, pencil) else widget.Ui.Sig{};
    if (esig.clicked) pick = .edit;

    const sig = ui.interact(id, r);
    if (sig.clicked and pick == .none) pick = .play;

    // Hover, animated by hand: these are not toolkit widgets, so nothing else is
    // keeping this number for us.
    const slot_i = @min(slot, m.hov.len - 1);
    const target: f32 = if (sig.hovered or esig.hovered) 1 else 0;
    const k = @min(1.0, ui.dt * 12.0);
    m.hov[slot_i] += (target - m.hov[slot_i]) * k;
    const t = m.hov[slot_i];
    if (t > 0.001 and t < 0.999) ui.animating = true;

    // Hovered posters LIFT — the row's own rect does not move, only what is drawn in
    // it, so nothing reflows under the pointer.
    const lift = 4 * t;
    const g = widget.Rect{ .x = r.x - lift, .y = r.y - lift, .w = r.w + 2 * lift, .h = r.h + 2 * lift };

    ui.canvas.dropShadowRoundedRect(g.x, g.y + 4, g.w, g.h, 14, 18 + 16 * t, 6, zrame.Color.rgba(0, 0, 0, 0.35 + 0.25 * t));
    ui.canvas.fillRoundedRect(g.x, g.y, g.w, g.h, 14, zrame.Color.lerp(c(22, 23, 30), c(38, 40, 52), t));

    const pr = widget.Rect{ .x = g.x, .y = g.y, .w = g.w, .h = poster_h + 2 * lift };
    poster(ui, pr, art, @intCast(slot + 1), t);

    // Title on the art, subtitle in the card's own strip below it. Both are cut to
    // the card — a poster that spills its title onto its neighbour is not a poster.
    const inner_w = g.w - 24;
    var tbuf: [192]u8 = undefined;
    var sbuf: [192]u8 = undefined;
    ui.canvas.drawText(ui.font, @intFromFloat(g.x + 12), @intFromFloat(pr.y + pr.h - 12), fit(ui, title, 15, .bold, inner_w, &tbuf), .{
        .size = 15,
        .style = .bold,
        .color = c(245, 246, 250),
    });
    ui.canvas.drawText(ui.font, @intFromFloat(g.x + 12), @intFromFloat(g.y + g.h - 20), fit(ui, sub, 12, .regular, inner_w, &sbuf), .{
        .size = 12,
        .style = .regular,
        .color = zrame.Color.lerp(t_theme.text_dim, t_theme.text, 0.4 * t),
    });

    if (t > 0.01) {
        ui.canvas.strokeRoundedRect(g.x, g.y, g.w, g.h, 14, 1.5, t_theme.accent.withAlpha(0.85 * t));
        if (editable) {
            // The pencil is DRAWN, not typed: a glyph the font happened not to have
            // would be a tofu box sitting on every poster.
            const p2 = widget.Rect{ .x = g.x + g.w - 34, .y = g.y + 8, .w = 26, .h = 26 };
            ui.canvas.fillRoundedRect(p2.x, p2.y, p2.w, p2.h, 8, zrame.Color.rgba(0, 0, 0, 0.55 * t));
            const col = if (esig.hovered) t_theme.accent else c(230, 232, 240).withAlpha(t);
            const x0 = p2.x + 8;
            const y0 = p2.y + 18;
            const x1 = p2.x + 18;
            const y1 = p2.y + 8;
            ui.canvas.strokeSegment(x0, y0, x1, y1, 2, col); // the body
            ui.canvas.strokeSegment(x0, y0, x0 + 3, y0 + 1, 2, col); // the nib
            ui.canvas.strokeSegment(x0 - 1, p2.y + 20, x0 + 10, p2.y + 20, 1.5, col.withAlpha(col.a * 0.6)); // the line it writes
        }
    }
    return pick;
}

/// A shelf: a heading, then as many posters per line as the window is wide enough
/// for. `render` places one card and says what was clicked.
fn shelfTitle(ui: *widget.Ui, s: []const u8) void {
    ui.gap(6);
    ui.textLine(s, 17, .bold, ui.theme.text);
    ui.gap(2);
}

fn perRow(ui: *widget.Ui) usize {
    const avail = ui.availW();
    const n: usize = @intFromFloat(@max(1, @floor(avail / (card_w + ui.theme.gap))));
    return @max(1, n);
}

fn build(ui: *widget.Ui, user: ?*anyopaque) void {
    const m: *Menu = @ptrCast(@alignCast(user.?));
    reapJob(m);

    // The room the posters hang in: darker than the toolkit's own surface, so the
    // cards read as lit and the window as unlit.
    const room = ui.bounds;
    ui.canvas.fillRoundedRectVGradient(room.x - 8, room.y - 8, room.w + 16, room.h + 16, 0, c(16, 17, 22), c(9, 9, 12));

    // The header — the title, and the one action that is not a poster.
    ui.beginRow();
    ui.textLine("E8", 26, .bold, ui.theme.accent);
    ui.gap(8);
    ui.textLine("presentazioni interattive", 15, .regular, ui.theme.text_dim);
    ui.endRow();
    ui.gap(2);

    const foot: f32 = if (m.note.items.len > 0) 42 else 8;
    const view_h = @max(200, ui.bounds.h - 96 - foot);
    ui.beginScroll("wall", view_h);

    var slot: usize = 0;

    // What you made comes first — it is the reason you opened this.
    if (!m.mine_loaded) loadMine(m);
    if (m.mine.items.len > 0) {
        shelfTitle(ui, "Le tue demo");
        const per = perRow(ui);
        var col: usize = 0;
        for (m.mine.items) |d| {
            if (col == 0) ui.beginRow();
            ui.pushIdScopeIndex(slot);
            var buf: [96]u8 = undefined;
            const sub = std.fmt.bufPrint(&buf, "{s} · {s}", .{ d.domain, if (d.asset.len > 0) d.asset else "solo slide" }) catch d.domain;
            switch (card(ui, m, slot, artOf(d.domain), d.name, sub, true)) {
                .play => openMine(m, d, false),
                .edit => openMine(m, d, true),
                .none => {},
            }
            ui.popIdScope();
            slot += 1;
            col += 1;
            if (col == per) {
                ui.endRow();
                col = 0;
            }
        }
        if (col > 0) ui.endRow();
        ui.gap(10);
    }

    // The demos that need nothing: they compute their own points.
    shelfTitle(ui, "Pronte da guardare");
    {
        const per = perRow(ui);
        var col: usize = 0;
        for (builtins) |b| {
            if (b.needs_asset) continue;
            if (col == 0) ui.beginRow();
            ui.pushIdScopeIndex(slot);
            switch (card(ui, m, slot, artOf(b.domain), b.title, b.blurb, true)) {
                .play => launch(m, b.domain, null, null, false),
                .edit => launch(m, b.domain, null, null, true),
                .none => {},
            }
            ui.popIdScope();
            slot += 1;
            col += 1;
            if (col == per) {
                ui.endRow();
                col = 0;
            }
        }
        if (col > 0) ui.endRow();
    }
    ui.gap(10);

    // The demos that need YOUR file: clicking one opens the wizard on that category,
    // which is the only honest thing a poster with no data behind it can do.
    shelfTitle(ui, "Porta i tuoi dati");
    {
        const per = perRow(ui);
        var col: usize = 0;
        for (categories, 0..) |cat, ci| {
            if (col == 0) ui.beginRow();
            ui.pushIdScopeIndex(slot);
            const sub = if (cat.asset.len > 0) cat.asset else "nessun file: solo slide";
            if (card(ui, m, slot, artOf(cat.domain), cat.label, sub, false) == .play) {
                m.cat = ci;
                m.wizard_wanted = true;
            }
            ui.popIdScope();
            slot += 1;
            col += 1;
            if (col == per) {
                ui.endRow();
                col = 0;
            }
        }
        // The plus card lives at the end of the same shelf: it is the same wizard,
        // just without a category chosen for you.
        if (col == per) {
            ui.endRow();
            col = 0;
        }
        if (col == 0) ui.beginRow();
        ui.pushIdScopeIndex(slot);
        if (card(ui, m, slot, .plus, "Nuova demo", "dai un file, esce una presentazione", false) == .play) {
            m.wizard_wanted = true;
        }
        ui.popIdScope();
        slot += 1;
        ui.endRow();
    }

    ui.endScroll();

    // Back at the root scope, where the dialog's id means what `wizard()` thinks it
    // means.
    if (m.wizard_wanted) {
        m.wizard_wanted = false;
        ui.openDialog("wizard");
    }

    if (m.note.items.len > 0) {
        ui.gap(6);
        ui.separator();
        ui.labelDim(m.note.items);
    }

    wizard(ui, m);
}

// --- the wizard, now a dialog ------------------------------------------------------------------

fn wizard(ui: *widget.Ui, m: *Menu) void {
    if (!ui.dialogOpen("wizard")) return;
    if (!ui.beginDialog("wizard", "Nuova demo", 560, 520)) return;
    defer ui.endDialog();

    var names: [categories.len][]const u8 = undefined;
    for (categories, 0..) |cat, i| names[i] = cat.label;

    ui.labelDim("categoria");
    _ = ui.dropdown("cat", &names, &m.cat);
    const cat = categories[m.cat];

    ui.gap(4);
    switch (cat.tool) {
        .molecule => toolMolecule(ui, m),
        .file => toolFile(ui, m, cat),
        .none => ui.labelDim("Questa categoria calcola i suoi punti da sola: non serve nessun file, scrivi solo le slide."),
    }

    ui.gap(8);
    ui.separator();
    ui.labelDim("nome della demo");
    _ = ui.textField("demo_name", &m.demo_name);

    ui.beginRow();
    if (ui.buttonPrimary("crea e apri nell'editor")) createDemo(m);
    if (ui.button("annulla")) ui.closeDialog();
    ui.endRow();

    // `createDemo` spawned the demo and has no `ui` of its own: it says so with a
    // flag, and the dialog closes itself here.
    if (m.wizard_done) {
        m.wizard_done = false;
        ui.closeDialog();
    }
}

fn openMine(m: *Menu, d: UserDemo, editor: bool) void {
    const gpa = m.gpa;
    const deck = std.fmt.allocPrint(gpa, "{s}/deck.zon", .{d.dir}) catch return;
    defer gpa.free(deck);
    if (d.asset.len == 0) {
        launch(m, d.domain, null, deck, editor);
        return;
    }
    const asset = std.fmt.allocPrint(gpa, "{s}/{s}", .{ d.dir, d.asset }) catch return;
    defer gpa.free(asset);
    launch(m, d.domain, asset, deck, editor);
}

/// Chemistry's specialized tool: the molecule need not be a file you already have.
fn toolMolecule(ui: *widget.Ui, m: *Menu) void {
    ui.labelDim("Scarica la molecola: per nome da PubChem, o per codice dalla Protein Data Bank.");

    ui.labelDim("nome (es. caffeine, aspirin, glucose)");
    const q = ui.textField("molecule", &m.molecule);
    ui.beginRow();
    if (ui.button("cerca su PubChem") or q == .submitted) startJob(m, .pubchem, m.molecule.items);
    ui.endRow();

    ui.labelDim("codice PDB (es. 1ubq, 4hhb)");
    const p = ui.textField("pdb", &m.pdb_id);
    ui.beginRow();
    if (ui.button("scarica da RCSB") or p == .submitted) startJob(m, .rcsb, m.pdb_id.items);
    ui.endRow();

    if (m.job.state.load(.acquire) == 1) {
        ui.beginRow();
        ui.spinner();
        ui.labelDim("scarico…");
        ui.endRow();
    } else if (m.got) |g| {
        var buf: [160]u8 = undefined;
        ui.labelDim(std.fmt.bufPrint(&buf, "pronto: {s}", .{g.name}) catch "");
    }

    ui.gap(4);
    ui.labelDim("oppure usa un file tuo (PDB o XYZ):");
    filePicker(ui, m);
}

fn toolFile(ui: *widget.Ui, m: *Menu, cat: Category) void {
    var buf: [128]u8 = undefined;
    ui.labelDim(std.fmt.bufPrint(&buf, "scegli il file ({s})", .{cat.asset}) catch "scegli il file");
    filePicker(ui, m);
}

fn filePicker(ui: *widget.Ui, m: *Menu) void {
    if (browse.pick(ui, &m.picker)) |path| {
        m.asset_path.clearRetainingCapacity();
        m.asset_path.appendSlice(m.gpa, path) catch {};
        if (m.got) |g| { // a picked file replaces a download
            g.deinit(m.gpa);
            m.got = null;
        }
        if (m.demo_name.items.len == 0) {
            m.demo_name.appendSlice(m.gpa, std.fs.path.stem(std.fs.path.basename(path))) catch {};
        }
    }
    if (m.asset_path.items.len > 0) {
        var buf: [256]u8 = undefined;
        ui.labelDim(std.fmt.bufPrint(&buf, "scelto: {s}", .{m.asset_path.items}) catch "");
    }
}

// --- main -------------------------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try init.environ.createMap(gpa);
    defer env.deinit();

    var m = Menu{ .gpa = gpa, .io = io, .env = &env, .picker = browse.Browser.init(gpa, io) };
    defer {
        if (m.job.thread) |t| t.join();
        if (m.job.asset) |a| a.deinit(gpa);
        if (m.got) |g| g.deinit(gpa);
        for (m.mine.items) |d| {
            gpa.free(d.dir);
            gpa.free(d.name);
            gpa.free(d.domain);
            gpa.free(d.asset);
        }
        m.mine.deinit(gpa);
        m.demo_name.deinit(gpa);
        m.molecule.deinit(gpa);
        m.pdb_id.deinit(gpa);
        m.asset_path.deinit(gpa);
        m.note.deinit(gpa);
        m.picker.deinit();
    }

    var host = zrame.Widgets.init(gpa, widget.Theme.dark(), build, &m);
    defer host.deinit();

    // Wide enough for four posters on a line, tall enough to see two shelves at once
    // — a wall of demos is only a wall if you can see it.
    const win = try zrame.Window.init(gpa, host.options(.{
        .title = "E8 — presentazioni interattive",
        .app_id = "dev.presenter.menu",
        .width = 980,
        .height = 720,
        .titlebar = true,
    }));
    defer win.deinit();
    host.attach(win);

    try win.run();
}
