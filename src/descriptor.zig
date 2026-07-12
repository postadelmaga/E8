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
