/// FirmamentKit — the platform-free core of Firmament.
///
/// Holds the Ledger (append-only event log with per-device hash chains),
/// the Lenses (deterministic folds: Vault at M0), capture pipeline,
/// transcription queue, and sync mapping. See docs/SPEC.md — the
/// constitution of the build.
public enum FirmamentKit {
    /// Kit version, stamped for diagnostics.
    public static let version = "0.1.0-m0"
}
