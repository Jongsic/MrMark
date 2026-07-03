import AppKit

/// Measures cold launch → first visible viewer. Run with `--benchmark` to print it.
/// The budget is <200ms perceived.
enum LaunchClock {
    static let start = CFAbsoluteTimeGetCurrent()
    private static var reported = false
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--benchmark")

    /// Intermediate breakdown line, e.g. `mark("document-read")`.
    static func mark(_ label: String) {
        guard enabled, !reported else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "  %@: %.0f ms", label, elapsed))
        fflush(stdout) // stdout is fully buffered when redirected; benchmark runs get killed
    }

    static func viewerDidAppear() {
        guard !reported else { return }
        reported = true
        guard enabled else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "launch-to-viewer: %.0f ms", elapsed))
        fflush(stdout)
    }
}
