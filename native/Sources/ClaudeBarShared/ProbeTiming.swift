import Foundation

/// How long a probe's refresh may take (docs/plans/2026-11-03-wsl-design.md,
/// The probe), known to the probe and to the app that waits for it.
public enum ProbeTiming {
    /// Seconds a CLI may take to start, on top of its timeout. Cold, Claude
    /// showed nothing for up to 24 s and Codex's app-server answered after up
    /// to 19 s (research, *Cold CLIs at the HUD's cadence*); 30 s covers both.
    public static let startAllowance: TimeInterval = 30

    /// The refresh's deadline the app passes: 60 s and the allowance. A CLI
    /// that never answers is stopped at its timeout plus the allowance, and
    /// the data source it falls back to starts only then (Codex's JSON-RPC,
    /// 15 s, then its terminal), so that one keeps the 45 s it had in 60 s.
    public static let deadline = 60 + Int(startAllowance)
}
