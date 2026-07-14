//! The slide editor (O, or `--editor`): author the deck without leaving the demo.
//!
//! It opens as its OWN glass window, next to the running scene, and that is a
//! design decision rather than a convenience. `zrame.Widgets` takes over all five
//! window callbacks, and the main window already spends them on the camera orbit,
//! the 3D pick and the HUD — so an editor drawn INTO the main window would have to
//! fight for them. In its own window it fights for nothing, the scene beside it
//! stays live (it is the preview), and the single-letter shortcuts the plugins bind
//! — P, K, E, C, F, X, O — never see the keys you type into a title field, because
//! those keys are delivered to a different window.
//!
//! THE ONE IDEA WORTH KNOWING. The editor does not hand slide structs across the
//! thread boundary. It serializes its model to ZON text and publishes that; the
//! render thread parses it and swaps the deck in. So "preview" is not a second
//! rendering path that could drift from the real one — it IS the F5 hot-reload
//! path, and "save" is the very same bytes written to disk. What you see is what
//! the file will say, because they are the same string.
//!
//! The dropdowns are not hardcoded either: preset / color / filter / edge are the
//! domain's own declarative tables (`D.presets`, `D.color_modes`, `D.filters`,
//! `D.relations`), so a new domain gets a working editor for free.

const std = @import("std");
const zrame = @import("zrame");
const widget = zrame.widget;
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;
const deck_mod = @import("../deck.zig");
const deck_write = @import("../deck_write.zig");
const slides = @import("slides.zig");
const panel = @import("panel.zig");

pub const id = "editor";

// --- what the two threads say to each other -----------------------------------------------

/// The whole cross-thread surface: a ZON string one way, the live camera the other.
/// Guarded by a spinlock, like the inspector's (`inspector.Shared`) — the contents
/// are small and the contention is a keystroke.
const Shared = struct {
    held: std.atomic.Value(bool) = .init(false),

    /// The deck as ZON, written by the editor thread whenever anything changes.
    zon: [64 * 1024]u8 = undefined,
    zlen: usize = 0,
    /// The editor changed something: the render thread should re-parse and preview.
    dirty: bool = false,
    /// Which slide to show after re-parsing.
    sel: usize = 0,
    /// The editor pressed save.
    save: bool = false,
    /// Edits published since the last successful save. Drives the close
    /// warning and the draft kept when the editor goes away unsaved.
    unsaved: bool = false,

    /// The live camera (yaw, pitch, dist), republished every frame so that
    /// "capture the camera" is a read, not a request.
    cam: [3]f32 = .{ 0, 0, 0 },
    /// What the render thread wants to tell the author (saved / parse error).
    note: [128]u8 = undefined,
    nlen: usize = 0,

    fn lock(s: *Shared) void {
        while (s.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(s: *Shared) void {
        s.held.store(false, .release);
    }
    fn setNote(s: *Shared, msg: []const u8) void {
        const n = @min(msg.len, s.note.len);
        @memcpy(s.note[0..n], msg[0..n]);
        s.nlen = n;
    }
};

// --- the editor's model (owned by the editor thread) ---------------------------------------

/// A slide, in the form the widgets want: text as growable buffers, choices as
/// indices into the option tables.
const EdSlide = struct {
    title: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    cite: std.ArrayList(u8) = .empty,
    fig: std.ArrayList(u8) = .empty,
    /// A picture instead of the scene, and the file the points come from — the
    /// two things that decide what the slide is LOOKING AT.
    image: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    preset: usize = 0,
    color: usize = 0, // 0 = none; else index+1 into D.color_modes
    filter: usize = 0, // 0 = none; else index+1 into D.filters
    edge: usize = 2, // index into edge_names ("all")
    tumble: bool = false,
    dwell: f32 = 22,
    cam: ?[3]f32 = null,

    fn deinit(s: *EdSlide, gpa: std.mem.Allocator) void {
        s.title.deinit(gpa);
        s.body.deinit(gpa);
        s.cite.deinit(gpa);
        s.fig.deinit(gpa);
        s.image.deinit(gpa);
        s.data.deinit(gpa);
    }
};

const Model = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    slides: std.ArrayList(EdSlide) = .empty,
    sel: usize = 0,
    /// Set by any widget that changed something; drives the republish.
    touched: bool = false,
    saved_note: [128]u8 = undefined,
    saved_len: usize = 0,
};

// --- the option tables, straight from the domain -------------------------------------------

/// The edge modes the framework itself understands, before the domain's relations.
const base_edges = [_][]const u8{ "off", "selection", "all" };

fn presetNames(gpa: std.mem.Allocator) [][]const u8 {
    const out = gpa.alloc([]const u8, D.presets.len) catch return &.{};
    for (D.presets, 0..) |p, i| out[i] = p.name;
    return out;
}

/// Colors and filters are OPTIONAL on a slide, so their tables carry a leading
/// "—" that means "leave it as it is".
fn colorNames(gpa: std.mem.Allocator) [][]const u8 {
    const out = gpa.alloc([]const u8, D.color_modes.len + 1) catch return &.{};
    out[0] = "—";
    for (D.color_modes, 0..) |c, i| out[i + 1] = c.name;
    return out;
}

fn filterNames(gpa: std.mem.Allocator) [][]const u8 {
    const out = gpa.alloc([]const u8, D.filters.len + 1) catch return &.{};
    out[0] = "—";
    for (D.filters, 0..) |f, i| out[i + 1] = f.name;
    return out;
}

fn edgeNames(gpa: std.mem.Allocator) [][]const u8 {
    const out = gpa.alloc([]const u8, base_edges.len + D.relations.len) catch return &.{};
    for (base_edges, 0..) |e, i| out[i] = e;
    for (D.relations, 0..) |r, i| out[base_edges.len + i] = r.name;
    return out;
}

fn indexOfName(names: []const []const u8, want: []const u8, comptime offset: usize) usize {
    for (names[offset..], offset..) |n, i| {
        if (std.mem.eql(u8, n, want)) return i;
    }
    return 0;
}

// --- plugin state --------------------------------------------------------------------------

pub const State = struct {
    win: ?*zrame.Window = null,
    thread: ?std.Thread = null,
    host: ?*zrame.Widgets = null,
    model: ?*Model = null,
    shared: Shared = .{},
    opened: bool = false,
    /// O pressed once with unsaved changes: the next O really closes.
    close_armed: bool = false,
};

/// zrame's `build` callback carries only a user pointer, and the option tables are
/// the same for the life of the process — building them once here keeps `build`
/// allocation-free.
var g_presets: [][]const u8 = &.{};
var g_colors: [][]const u8 = &.{};
var g_filters: [][]const u8 = &.{};
var g_edges: [][]const u8 = &.{};

pub fn init(a: *App) void {
    g_presets = presetNames(a.gpa);
    g_colors = colorNames(a.gpa);
    g_filters = filterNames(a.gpa);
    g_edges = edgeNames(a.gpa);
    // `--editor`: the launcher opens a demo straight into the editor, both when the
    // author is making a new one and when they are opening an existing one to read.
    if (app_mod.cli.editor) open(a);
}

pub fn deinit(a: *App) void {
    close(a);
    const gpa = a.gpa;
    if (g_presets.len > 0) gpa.free(g_presets);
    if (g_colors.len > 0) gpa.free(g_colors);
    if (g_filters.len > 0) gpa.free(g_filters);
    if (g_edges.len > 0) gpa.free(g_edges);
}

pub fn key(a: *App, code: u32) bool {
    // O, not E: E is the edge-mode cycle, `edges` is registered before this plugin
    // in every domain, and `dispatchKey` stops at the first plugin that claims a key.
    if (code != keys.editor) return false; // O
    const st = a.pluginState(@This());
    if (st.win == null) {
        open(a);
        return true;
    }
    // Closing throws the model away — warn once when there is unsaved work.
    st.shared.lock();
    const unsaved = st.shared.unsaved;
    st.shared.unlock();
    if (unsaved and !st.close_armed) {
        st.close_armed = true;
        a.hud.setLine2("the editor has unsaved changes — save there, or press O again to close (a draft is kept)");
        return true;
    }
    close(a);
    return true;
}

pub fn status(a: *App, buf: []u8) []const u8 {
    _ = buf;
    return if (a.pluginState(@This()).win != null) "editor (O closes)" else "";
}

// --- the render thread's half --------------------------------------------------------------

pub fn post(a: *App) void {
    const st = a.pluginState(@This());
    if (st.win) |w| {
        if (w.closed) {
            close(a);
            return;
        }
    } else return;

    const sh = &st.shared;
    sh.lock();
    defer sh.unlock();

    // Publish the camera, so the editor's "capture" button is a read.
    sh.cam = .{
        app_mod.loadF32(&app_mod.cam_yaw),
        app_mod.loadF32(&app_mod.cam_pitch),
        app_mod.loadF32(&app_mod.cam_dist),
    };

    if (sh.dirty) {
        sh.dirty = false;
        applyZon(a, sh);
    }
    if (sh.save) {
        sh.save = false;
        const path = slides.deckPath();
        std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = path, .data = sh.zon[0..sh.zlen] }) catch |e| {
            var buf: [128]u8 = undefined;
            sh.setNote(std.fmt.bufPrint(&buf, "save failed: {s}", .{@errorName(e)}) catch "save failed");
            return;
        };
        var buf: [128]u8 = undefined;
        sh.setNote(std.fmt.bufPrint(&buf, "saved to {s}", .{path}) catch "saved");
        sh.unsaved = false;
        st.close_armed = false;
    }
}

/// Re-parse the editor's ZON and swap it in as the live deck — the same two calls
/// F5 makes, which is exactly the point: the preview cannot diverge from the demo.
fn applyZon(a: *App, sh: *Shared) void {
    const sl = a.pluginState(slides);
    const z = a.gpa.dupeZ(u8, sh.zon[0..sh.zlen]) catch return;
    defer a.gpa.free(z);

    const d = deck_mod.parse(a.gpa, z) catch |e| {
        var buf: [128]u8 = undefined;
        sh.setNote(std.fmt.bufPrint(&buf, "the deck will not parse: {s}", .{@errorName(e)}) catch "deck will not parse");
        return;
    };
    deck_mod.deinit(a.gpa, sl.deck);
    sl.deck = d;
    if (d.slides.len == 0) return;

    sl.idx = @min(sh.sel, d.slides.len - 1);
    if (!a.pluginState(panel).on) panel.setOpen(a, true);
    slides.show(a, sl.idx);
    sh.setNote("");
}

// --- opening and closing the window ---------------------------------------------------------

fn winLoop(w: *zrame.Window) void {
    w.run() catch {};
}

fn open(a: *App) void {
    const st = a.pluginState(@This());
    if (st.win != null) return;
    st.close_armed = false;
    const gpa = a.gpa;

    const m = gpa.create(Model) catch return;
    m.* = .{ .gpa = gpa, .shared = &st.shared };
    // Seed the editor from the deck that is actually playing — which is how "open
    // an existing demo in the editor as an example" costs nothing: the example is
    // simply the deck already loaded.
    fromDeck(m, a.pluginState(slides).deck);
    republish(m);
    st.model = m;

    const host = gpa.create(zrame.Widgets) catch {
        freeModel(m);
        st.model = null;
        return;
    };
    host.* = zrame.Widgets.init(gpa, widget.Theme.dark(), build, m);
    st.host = host;

    const w = zrame.Window.init(gpa, host.options(.{
        .title = "editor",
        .app_id = "dev.presenter.editor",
        .width = 560,
        .height = 760,
        .titlebar = true,
        .close_on_esc = false, // Esc is the text field's business, not the window's
    })) catch |e| {
        std.debug.print("editor window unavailable: {s}\n", .{@errorName(e)});
        host.deinit();
        gpa.destroy(host);
        st.host = null;
        freeModel(m);
        st.model = null;
        return;
    };
    host.attach(w);
    st.win = w;
    st.thread = std.Thread.spawn(.{}, winLoop, .{w}) catch null;
}

fn close(a: *App) void {
    const st = a.pluginState(@This());
    const w = st.win orelse return;
    // However the editor goes away — O, its close button, app shutdown —
    // unsaved work leaves as a draft next to the deck, never silently.
    saveDraft(a, st);
    st.close_armed = false;
    w.close();
    if (st.thread) |t| t.join();
    w.deinit();
    st.win = null;
    st.thread = null;
    if (st.host) |h| {
        h.deinit();
        a.gpa.destroy(h);
        st.host = null;
    }
    if (st.model) |m| {
        freeModel(m);
        st.model = null;
    }
}

/// Write the last published ZON to `<deck>.draft` when it was never saved.
/// The bytes are already serialized — losing them to a stray Esc costs the
/// author a talk; a stale draft file costs nothing.
fn saveDraft(a: *App, st: *State) void {
    const sh = &st.shared;
    sh.lock();
    const data: []u8 = if (sh.unsaved and sh.zlen > 0)
        a.gpa.dupe(u8, sh.zon[0..sh.zlen]) catch &.{}
    else
        &.{};
    sh.unsaved = false;
    sh.unlock();
    if (data.len == 0) return;
    defer a.gpa.free(data);
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}.draft", .{slides.deckPath()}) catch return;
    std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = path, .data = data }) catch |e| {
        std.debug.print("editor: could not keep the draft ({s})\n", .{@errorName(e)});
        return;
    };
    var mbuf: [560]u8 = undefined;
    a.hud.setLine2(std.fmt.bufPrint(&mbuf, "editor closed with unsaved changes — draft kept in {s}", .{path}) catch "editor draft kept");
}

fn freeModel(m: *Model) void {
    for (m.slides.items) |*s| s.deinit(m.gpa);
    m.slides.deinit(m.gpa);
    m.gpa.destroy(m);
}

// --- model ⇄ deck --------------------------------------------------------------------------

fn setText(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    list.clearRetainingCapacity();
    list.appendSlice(gpa, s) catch {};
}

fn fromDeck(m: *Model, d: deck_mod.Deck) void {
    for (d.slides) |s| {
        var e = EdSlide{};
        setText(&e.title, m.gpa, s.title);
        setText(&e.body, m.gpa, s.body);
        setText(&e.cite, m.gpa, s.cite);
        setText(&e.fig, m.gpa, s.fig);
        setText(&e.image, m.gpa, s.image);
        setText(&e.data, m.gpa, s.data);
        e.preset = indexOfName(g_presets, s.preset, 0);
        e.color = if (s.color.len == 0) 0 else indexOfName(g_colors, s.color, 1);
        e.filter = if (s.filter.len == 0) 0 else indexOfName(g_filters, s.filter, 1);
        e.edge = if (s.edge.len == 0) 2 else indexOfName(g_edges, s.edge, 0);
        e.tumble = s.tumble;
        e.dwell = s.dwell;
        e.cam = s.cam;
        m.slides.append(m.gpa, e) catch {
            e.deinit(m.gpa);
            return;
        };
    }
}

/// Serialize the model and hand it to the render thread. This is the ONLY way the
/// editor speaks: one string, which is both the preview and the file.
fn republish(m: *Model) void {
    var list: std.ArrayList(deck_mod.Slide) = .empty;
    defer list.deinit(m.gpa);
    for (m.slides.items) |*e| {
        list.append(m.gpa, .{
            .title = e.title.items,
            .body = e.body.items,
            .cite = e.cite.items,
            .fig = e.fig.items,
            .image = e.image.items,
            .data = e.data.items,
            .preset = if (g_presets.len > 0) g_presets[@min(e.preset, g_presets.len - 1)] else "",
            .color = if (e.color == 0) "" else g_colors[@min(e.color, g_colors.len - 1)],
            .filter = if (e.filter == 0) "" else g_filters[@min(e.filter, g_filters.len - 1)],
            .edge = if (g_edges.len > 0) g_edges[@min(e.edge, g_edges.len - 1)] else "all",
            .tumble = e.tumble,
            .dwell = e.dwell,
            .cam = e.cam,
        }) catch return;
    }
    const src = deck_write.toStringAlloc(m.gpa, .{ .slides = list.items }) catch return;
    defer m.gpa.free(src);

    const sh = m.shared;
    sh.lock();
    defer sh.unlock();
    if (src.len > sh.zon.len) {
        sh.setNote("the deck is too large to preview");
        return;
    }
    @memcpy(sh.zon[0..src.len], src);
    sh.zlen = src.len;
    sh.sel = m.sel;
    sh.dirty = true;
}

// --- the UI (editor thread) -----------------------------------------------------------------

fn build(ui: *widget.Ui, user: ?*anyopaque) void {
    const m: *Model = @ptrCast(@alignCast(user.?));

    ui.heading("Slides");

    // The deck, as a list. Selecting a slide previews it in the window next door.
    ui.beginScroll("deck", 150);
    var buf: [128]u8 = undefined;
    for (m.slides.items, 0..) |*s, i| {
        ui.pushIdScopeIndex(i);
        const title = if (s.title.items.len > 0) s.title.items else "(untitled)";
        const row = std.fmt.bufPrint(&buf, "{d}. {s}", .{ i + 1, title }) catch title;
        if (ui.selectable(row, m.sel == i)) {
            m.sel = i;
            m.touched = true;
        }
        ui.popIdScope();
    }
    ui.endScroll();

    ui.beginRow();
    if (ui.button("＋ new")) {
        var e = EdSlide{};
        setText(&e.title, m.gpa, "New slide");
        setText(&e.body, m.gpa, "The text of the slide.");
        // A new slide starts from what is on screen: the preset in use and the
        // camera you are looking through. Authoring is aiming, then writing.
        e.preset = @min(@as(usize, 0), g_presets.len -| 1);
        m.slides.append(m.gpa, e) catch e.deinit(m.gpa);
        m.sel = m.slides.items.len -| 1;
        m.touched = true;
    }
    if (m.slides.items.len > 0 and ui.button("delete")) {
        var e = m.slides.orderedRemove(m.sel);
        e.deinit(m.gpa);
        m.sel = m.sel -| 1;
        m.touched = true;
    }
    if (m.sel > 0 and ui.button("↑")) {
        std.mem.swap(EdSlide, &m.slides.items[m.sel], &m.slides.items[m.sel - 1]);
        m.sel -= 1;
        m.touched = true;
    }
    if (m.slides.items.len > 1 and m.sel + 1 < m.slides.items.len and ui.button("↓")) {
        std.mem.swap(EdSlide, &m.slides.items[m.sel], &m.slides.items[m.sel + 1]);
        m.sel += 1;
        m.touched = true;
    }
    ui.endRow();
    ui.separator();

    if (m.slides.items.len == 0) {
        ui.labelDim("The deck is empty. Press ＋ for the first slide.");
        flush(m);
        return;
    }

    const s = &m.slides.items[@min(m.sel, m.slides.items.len - 1)];

    ui.labelDim("title");
    if (ui.textField("title", &s.title) != .idle) m.touched = true;
    ui.labelDim("body");
    if (ui.textArea("body", &s.body, 150) != .idle) m.touched = true;
    ui.labelDim("citation");
    if (ui.textField("cite", &s.cite) != .idle) m.touched = true;

    // What the slide LOOKS AT. Everything below this is how it is dressed; these
    // two decide whether there is a figure at all, and what it is made of.
    ui.gap(6);
    ui.separator();
    ui.labelDim("picture instead of the scene (a path — empty = show the scene)");
    if (ui.textField("image", &s.image) != .idle) m.touched = true;
    ui.labelDim("data for this slide (a file this demo can read — empty = the one it was opened with)");
    if (ui.textField("data", &s.data) != .idle) m.touched = true;
    ui.separator();

    ui.gap(6);
    ui.labelDim("projection");
    if (ui.dropdown("preset", g_presets, &s.preset)) m.touched = true;
    ui.labelDim("color");
    if (ui.dropdown("color", g_colors, &s.color)) m.touched = true;
    ui.labelDim("subset filter");
    if (ui.dropdown("filter", g_filters, &s.filter)) m.touched = true;
    ui.labelDim("edges");
    if (ui.dropdown("edge", g_edges, &s.edge)) m.touched = true;
    ui.labelDim("panel figure (the domain's id, empty = none)");
    if (ui.textField("fig", &s.fig) != .idle) m.touched = true;

    ui.gap(6);
    if (ui.toggle("slow tumble", &s.tumble)) m.touched = true;
    if (ui.slider("seconds in kiosk", &s.dwell, 5, 90)) m.touched = true;

    // The camera is not typed in, it is AIMED: orbit the scene next door until it
    // looks right, then take it.
    ui.beginRow();
    if (ui.button("take the camera")) {
        const sh = m.shared;
        sh.lock();
        s.cam = sh.cam;
        sh.unlock();
        m.touched = true;
    }
    if (s.cam != null and ui.button("drop the camera")) {
        s.cam = null;
        m.touched = true;
    }
    ui.endRow();
    if (s.cam) |c| {
        const cs = std.fmt.bufPrint(&buf, "camera  yaw {d:.2}  pitch {d:.2}  dist {d:.2}", .{ c[0], c[1], c[2] }) catch "";
        ui.labelDim(cs);
    } else ui.labelDim("free camera (this slide does not move it)");

    ui.gap(8);
    ui.separator();
    ui.beginRow();
    if (ui.buttonPrimary("save")) {
        republish(m); // save what is on screen, not what was last previewed
        const sh = m.shared;
        sh.lock();
        sh.save = true;
        sh.unlock();
        m.touched = false;
    }
    ui.endRow();

    // Whatever the render thread has to say — saved, or the deck would not parse.
    {
        const sh = m.shared;
        sh.lock();
        const n = sh.nlen;
        @memcpy(m.saved_note[0..n], sh.note[0..n]);
        m.saved_len = n;
        sh.unlock();
    }
    if (m.saved_len > 0) ui.labelDim(m.saved_note[0..m.saved_len]);

    flush(m);
}

/// One republish per frame at most, after the whole UI has run — a keystroke
/// re-serializes the deck once, not once per widget that noticed it.
fn flush(m: *Model) void {
    if (!m.touched) return;
    m.touched = false;
    republish(m);
    // Only USER edits mark the deck unsaved (open() also republishes, to seed).
    const sh = m.shared;
    sh.lock();
    sh.unsaved = true;
    sh.unlock();
}
