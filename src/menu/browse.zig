//! A file picker, because there isn't one.
//!
//! zrame has no file dialog and the desktop portal would drag DBus into a program
//! whose whole job is to list a directory. So: a path, its entries, and a click.
//! Directories descend, files return. That is the entire contract — `pick` returns
//! the chosen path on the frame it is chosen, and null on every other frame, which
//! is how an immediate-mode widget says "something happened".

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

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Browser {
        return .{ .gpa = gpa, .io = io };
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

    /// Read the directory. Hidden entries are skipped — a file picker that opens
    /// onto forty dotfiles is not a picker, it is a haystack.
    fn reload(b: *Browser) void {
        b.clearEntries();
        b.loaded = true;
        if (b.cwd.items.len == 0) {
            const p = std.process.currentPathAlloc(b.io, b.gpa) catch return;
            defer b.gpa.free(p);
            b.cwd.appendSlice(b.gpa, p) catch return;
        }
        var dir = std.Io.Dir.openDirAbsolute(b.io, b.cwd.items, .{ .iterate = true }) catch return;
        defer dir.close(b.io);
        var it = dir.iterate();
        while (it.next(b.io) catch return) |e| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            const kind_dir = e.kind == .directory;
            b.entries.append(b.gpa, .{
                .name = b.gpa.dupe(u8, e.name) catch continue,
                .is_dir = kind_dir,
            }) catch break;
        }
        // Directories first, then alphabetical — the order a person expects.
        std.mem.sort(Entry, b.entries.items, {}, lessThan);
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

    var out: ?[]const u8 = null;
    ui.beginScroll("files", 170);
    var buf: [512]u8 = undefined;
    for (b.entries.items, 0..) |e, i| {
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
    ui.endScroll();
    return out;
}
