//! Domain actions: named key-bound operations declared by the domain package
//! (Lisi's G = "ride the triality orbit"; a molecule's "follow the chain";
//! a polytope's "jump to the dual vertex").

const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "actions";

pub fn key(a: *App, code: u32) bool {
    for (D.actions) |act| {
        if (act.key == code) {
            act.run(a);
            return true;
        }
    }
    return false;
}
