//! A file picker, because there isn't one.
//!
//! zrame has no file dialog and the desktop portal would drag DBus into a program
//! whose whole job is to list a directory. So: a path, its entries, and a click.
//! Directories descend, files return. That is the entire contract — `pick` returns
//! the chosen path on the frame it is chosen, and null on every other frame, which
//! is how an immediate-mode widget says "something happened".
//!
//! It FILTERS, though, and that is not cosmetic. A picker that opens on the process
//! cwd and lists everything in it opened, for a real user, on `zig-out/bin/` — and
//! cheerfully offered them `e8-chem`, a 16 MB executable, as a star catalog. They
//! took it. So: the caller says which extensions its domain can actually read, the
//! picker lists those and the directories, and the escape hatch for the person whose
//! catalog really is a `.txt` is one checkbox, not a dead end.

const std = @import("std");
const zrame = @import("zrame");
const widget = zrame.widget;

const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const Browser = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// The chosen file's full path, kept so the caller can read it back.
    chosen: std.ArrayList(u8) = .empty,
    loaded: bool = false,

    /// The extensions the caller can actually read, WITH the dot and in lowercase:
    /// `&.{ ".pdb", ".xyz" }`. Empty means "list everything" — the old behaviour, and
    /// still what a caller with no opinion gets.
    filter: []const []const u8 = &.{},
    /// The escape hatch: the filter is a guess about file naming, not a law. A star
    /// catalog saved as `.txt`, or a data file on a FAT mount that came out `0o777`,
    /// must still be reachable — one checkbox away.
    show_all: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, start_dir: []const u8) Browser {
        var b: Browser = .{ .gpa = gpa, .io = io };
        // The starting directory is COPIED, not borrowed: `setCwd` clears and refills
        // this list on every descent, and the caller's `$HOME` slice belongs to an
        // environment map it is free to free.
        if (start_dir.len > 0) b.cwd.appendSlice(gpa, start_dir) catch {};
        return b;
    }

    pub fn deinit(b: *Browser) void {
        b.clearEntries();
        b.entries.deinit(b.gpa);
        b.cwd.deinit(b.gpa);
        b.chosen.deinit(b.gpa);
    }

    fn clearEntries(b: *Browser) void {
        for (b.entries.items) |e| b.gpa.free(e.name);
        b.entries.clearRetainingCapacity();
    }

    fn setCwd(b: *Browser, path: []const u8) void {
        b.cwd.clearRetainingCapacity();
        b.cwd.appendSlice(b.gpa, path) catch {};
        b.loaded = false;
    }

    /// What the picker will accept from here on. The wizard calls this every frame
    /// with the chosen category's extensions — so it has to be cheap when nothing
    /// changed, and it is: the lists are comptime literals, so identity is enough.
    pub fn setFilter(b: *Browser, exts: []const []const u8) void {
        if (b.filter.ptr == exts.ptr and b.filter.len == exts.len) return;
        b.filter = exts;
        b.loaded = false; // the listing means something different now
    }

    fn accepts(b: *const Browser, name: []const u8) bool {
        if (b.show_all or b.filter.len == 0) return true;
        const ext = std.fs.path.extension(name);
        if (ext.len == 0) return false;
        for (b.filter) |f| if (std.ascii.eqlIgnoreCase(ext, f)) return true;
        return false;
    }

    /// Read the directory. Hidden entries are skipped — a file picker that opens
    /// onto forty dotfiles is not a picker, it is a haystack. So are files the
    /// caller could not read anyway (see `filter`), and so are executables: nobody's
    /// data is a program, and the one time the launcher let a person pick one it
    /// copied 16 MB of ELF into their demo and called it a star catalog.
    ///
    /// `show_all` turns both of those off at once — it is the one honest meaning of
    /// "show all files".
    fn reload(b: *Browser) void {
        b.clearEntries();
        b.loaded = true;
        if (b.cwd.items.len == 0) {
            const p = std.process.currentPathAlloc(b.io, b.gpa) catch return;
            defer b.gpa.free(p);
            b.cwd.appendSlice(b.gpa, p) catch return;
        }
        var dir = std.Io.Dir.openDirAbsolute(b.io, b.cwd.items, .{ .iterate = true }) catch {
            // A cwd that will not open (a stale $HOME, a directory since deleted) must
            // not leave the picker staring at an empty pane forever: fall back to the
            // process's own directory, which by definition exists.
            if (b.cwd.items.len > 0) {
                b.cwd.clearRetainingCapacity();
                b.loaded = false;
            }
            return;
        };
        defer dir.close(b.io);
        var it = dir.iterate();
        while (it.next(b.io) catch return) |e| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            const kind_dir = e.kind == .directory;
            // Directories always list: they are the way OUT of a directory with
            // nothing acceptable in it.
            if (!kind_dir) {
                if (!b.accepts(e.name)) continue;
                if (!b.show_all and isExecutable(b, dir, e.name)) continue;
            }
            b.entries.append(b.gpa, .{
                .name = b.gpa.dupe(u8, e.name) catch continue,
                .is_dir = kind_dir,
            }) catch break;
        }
        // Directories first, then alphabetical — the order a person expects.
        std.mem.sort(Entry, b.entries.items, {}, lessThan);
    }

    /// One `statat` per file that survived the extension filter — which, with a
    /// filter on, is a handful. A file we cannot stat is not assumed hostile: it
    /// lists, and the domain will say what it thinks of it.
    fn isExecutable(b: *const Browser, dir: std.Io.Dir, name: []const u8) bool {
        if (!std.Io.File.Permissions.has_executable_bit) return false;
        const st = dir.statFile(b.io, name, .{}) catch return false;
        if (st.kind != .file) return false;
        return st.permissions.toMode() & 0o111 != 0;
    }

    fn lessThan(_: void, a: Entry, c: Entry) bool {
        if (a.is_dir != c.is_dir) return a.is_dir;
        return std.mem.lessThan(u8, a.name, c.name);
    }
};

/// Draw the picker. Returns the full path of a file the moment one is clicked.
pub fn pick(ui: *widget.Ui, b: *Browser) ?[]const u8 {
    if (!b.loaded) b.reload();

    ui.beginRow();
    if (ui.button("↑ up")) {
        const up = std.fs.path.dirname(b.cwd.items) orelse "/";
        // dirname borrows from cwd, and setCwd clears cwd — copy first.
        const tmp = b.gpa.dupe(u8, up) catch return null;
        defer b.gpa.free(tmp);
        b.setCwd(tmp);
        return null;
    }
    ui.labelDim(b.cwd.items);
    ui.endRow();

    // What is being hidden, and how to stop hiding it — said in the same breath, so
    // an empty pane is never a mystery.
    ui.beginRow();
    if (b.filter.len > 0) {
        var fbuf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&fbuf);
        w.writeAll("showing ") catch {};
        for (b.filter, 0..) |f, i| {
            if (i > 0) w.writeAll(" ") catch {};
            w.writeAll(f) catch {};
        }
        ui.labelDim(w.buffered());
    } else {
        ui.labelDim("showing every data file");
    }
    if (ui.checkbox("show all files", &b.show_all)) b.loaded = false;
    ui.tooltip("list everything in this directory, including executables and files whose name does not end the way this field expects");
    ui.endRow();

    var out: ?[]const u8 = null;
    ui.beginScroll("files", 170);
    var buf: [512]u8 = undefined;
    var files: usize = 0;
    for (b.entries.items, 0..) |e, i| {
        if (!e.is_dir) files += 1;
        ui.pushIdScopeIndex(i);
        // A trailing slash, not a folder emoji: the UI font is the app's text font,
        // and an emoji it does not carry draws as a tofu box.
        const row = std.fmt.bufPrint(&buf, "{s}{s}", .{ e.name, if (e.is_dir) "/" else "" }) catch e.name;
        if (ui.selectable(row, false)) {
            const full = std.fmt.allocPrint(b.gpa, "{s}/{s}", .{ b.cwd.items, e.name }) catch {
                ui.popIdScope();
                break;
            };
            if (e.is_dir) {
                b.setCwd(full);
                b.gpa.free(full);
                ui.popIdScope();
                break; // the entry list is about to change under us
            }
            b.chosen.clearRetainingCapacity();
            b.chosen.appendSlice(b.gpa, full) catch {};
            b.gpa.free(full);
            out = b.chosen.items;
        }
        ui.popIdScope();
    }
    // A directory with nothing this field can read looks, otherwise, exactly like a
    // directory that failed to open.
    if (files == 0) ui.labelDim("no file here this field can read — go up, or tick “show all files”");
    ui.endScroll();
    return out;
}
