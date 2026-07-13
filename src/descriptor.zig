//! Declarative object descriptors: how a class of points looks and behaves.
//! The domain maps each point to one `Object`; the framework's effects plugin
//! and rasterizers consume it. This is the authoring half of the
//! Visual/EdgeVisual runtime contract — "gluon → orange emissive, breathing"
//! and "hydrophobic residue → warm tint" are written the same way.

/// Periodic emphasis animation for special objects.
pub const Pulse = struct {
    /// Kind of motion: a traveling `wave` (phase matters) or a slow `breathe`.
    kind: enum { wave, breathe } = .breathe,
    /// Radians/second.
    rate: f32 = 1.1,
    /// Amplitude of the glow modulation (0 = none).
    amp: f32 = 0.35,
    /// Phase offset, typically derived from a per-object charge.
    phase: f32 = 0,
};

pub const Object = struct {
    /// Multiplier on the base point radius.
    radius: f32 = 1.0,
    /// Multiplier on the resting emissive.
    glow: f32 = 1.0,
    /// Optional periodic emphasis (the theory's "special" objects).
    pulse: ?Pulse = null,
    /// Color and phase used when this object flares as a relation-orbit
    /// member of the selection (the lighthouse effect).
    orbit_rgb: [3]f32 = .{ 1, 1, 1 },
    orbit_phase: f32 = 0,
};

/// A domain's OWN mesh, attached to the inspector's zengine scene.
///
/// The framework bakes two meshes and knows what they are for (a sphere per
/// point, a tube per edge). Anything beyond that is the science's business, so a
/// domain may hand over meshes of its own — `extraMeshes(gpa)` builds them,
/// `sceneExtra(a, i, part)` places and lights each one per selected point.
///
/// Several PARTS rather than one, because a zengine instance carries a single
/// material: parts are how a domain gets more than one colour into its object.
/// The M-theory demo hands over the twenty-five patches of a Calabi–Yau, one per
/// root of unity, so each can be lit its own hue. Nothing in the framework knows
/// that is what they are.
pub const Extra = struct {
    /// Column-major 4×4 model matrix.
    model: [16]f32,
    base_color: [3]f32,
    emissive: [3]f32,
    roughness: f32 = 0.42,
    metallic: f32 = 0.0,
};

/// Interleaved vertices — position(3), normal(3), uv(2) — plus triangle indices.
/// What a domain's `extraMesh(gpa)` returns; the framework owns the memory after.
pub const MeshData = struct {
    verts: []f32,
    idx: []u32,
};
