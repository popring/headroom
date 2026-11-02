import Foundation

/// Keeps `cswap auto` running as a child process while the menu toggle is on.
///
/// The switching logic — threshold, which per-model weekly windows count, cooldown,
/// target choice — stays in cswap and its own settings
/// (`cswap config set autoswitch.model Fable`), so there is one source of truth and
/// nothing here to drift from it. Headroom launches at login, so "on" means always on.
enum CswapAuto {
    private static var process: Process?

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cswapAutoEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "cswapAutoEnabled")
            newValue ? start() : stop()
        }
    }

    static var isRunning: Bool { process?.isRunning == true }

    /// A terminal `cswap auto` or cswap's own menu bar app would race ours over the
    /// active slot; leave the job to it rather than run two engines.
    static var runningElsewhere: Bool {
        !isRunning && CLI.run(["pgrep", "-f", "cswap (auto|menubar)"], timeout: 5)
    }

    static func start() {
        guard enabled, !isRunning, !runningElsewhere else { return }
        let proc = CLI.process(["cswap", "auto"])
        proc.terminationHandler = { _ in
            // Exited on its own (crash, `cswap upgrade` replacing it): retry while still on.
            // ponytail: fixed 60 s retry, add backoff if it ever crash-loops.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { start() }
        }
        do { try proc.run(); process = proc } catch { process = nil }
    }

    static func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }
}
