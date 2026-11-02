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
    /// active slot; leave the job to it rather than run two engines. Matched on the
    /// installed script path, so a shell whose command line merely mentions
    /// "cswap auto" (an editor, a grep) doesn't count.
    static var runningElsewhere: Bool {
        !isRunning && CLI.run(["pgrep", "-f", "bin/(cswap|claude-swap) (auto|menubar)"], timeout: 5)
    }

    static func start() {
        guard enabled, !isRunning, !runningElsewhere else { return }
        // --json: one event per line; unbuffered, or Python holds them in an 8 KB block buffer.
        let proc = CLI.process(["cswap", "auto", "--json"], env: ["PYTHONUNBUFFERED": "1"])
        let pipe = Pipe()
        proc.standardOutput = pipe
        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { file in
            let chunk = file.availableData
            guard !chunk.isEmpty else { file.readabilityHandler = nil; return }   // EOF
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                DispatchQueue.main.async { handle(event) }
            }
        }
        proc.terminationHandler = { _ in
            // Exited on its own (crash, `cswap upgrade` replacing it): retry while still on.
            // ponytail: fixed 60 s retry, add backoff if it ever crash-loops.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { start() }
        }
        do { try proc.run(); process = proc } catch { process = nil }
    }

    // MARK: - Events → notifications

    /// Last poll's window usage per slot, to say *why* a switch happened.
    private static var lastWindows: [String: [String: Double]] = [:]
    /// cswap repeats all-exhausted every tick; say it once until something changes.
    private static var exhaustedNotified = false

    /// Handles one `cswap auto --json` event (schema: claude_swap/autoswitch.py, additive —
    /// unknown events and fields are ignored).
    static func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "poll":
            lastWindows = event["windowsPct"] as? [String: [String: Double]] ?? [:]
        case "switch":
            guard event["dryRun"] as? Bool != true,
                  let to = slotNumber(event["to"]) else { return }
            exhaustedNotified = false
            var body = L("已切号", "Switched")
            if let from = slotNumber(event["from"]) {
                body = String(format: L("%@ 额度快满", "%@ nearly out"), name(from))
                if let (window, pct) = lastWindows[from]?.max(by: { $0.value < $1.value }) {
                    body = String(format: L("%@ 的 %@ 已用 %d%%", "%@: %@ at %d%%"), name(from), window, Int(pct))
                }
            }
            QuotaAlert.post(id: "cswap-auto",
                            title: String(format: L("已自动切到 %@", "Auto-switched to %@"), name(to)),
                            body: body)
        case "all-exhausted":
            guard !exhaustedNotified else { return }
            exhaustedNotified = true
            let reset = (event["earliestResetAt"] as? String).flatMap(parseISO)
            QuotaAlert.post(id: "cswap-auto",
                            title: L("所有账号额度都用完了", "Every account is out of quota"),
                            body: reset.map { L("最早 \(Fmt.until($0)) 重置", "Earliest reset \(Fmt.until($0))") }
                                ?? L("没有可切的号", "Nothing left to switch to"))
        case "account-quarantined":
            guard let slot = (event["number"] as? String) ?? slotNumber(event) else { return }
            QuotaAlert.post(id: "cswap-quarantine-\(slot)",
                            title: String(format: L("%@ 登录失效", "%@ login expired"), name(slot)),
                            body: L("已移出自动切换，重新登录后用 cswap add 补回",
                                    "Taken out of rotation; log in again and re-add it with cswap add"))
        default:
            break
        }
    }

    private static func slotNumber(_ ref: Any?) -> String? {
        let number = (ref as? [String: Any])?["number"]
        return (number as? NSNumber)?.stringValue ?? number as? String
    }

    /// Slot → the name shown everywhere else (config alias, cswap alias, org).
    private static func name(_ slot: String) -> String {
        ProviderRegistry.readAllAccounts().first { $0.key == "claude-swap:\(slot)" }?.displayName
            ?? L("槽位 \(slot)", "Slot \(slot)")
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s)
    }

    static func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }
}
