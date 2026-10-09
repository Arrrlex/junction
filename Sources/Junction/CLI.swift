import Foundation

/// Command-line mode, used by Claude (and you) to inspect and test routing:
///
///   junction eval <url> [--from <bundleId>] [--title <window title>]
///   junction replay [--json] [--all]
///   junction review [--mark]
///   junction recent [n]
enum CLI {
    static let commands: Set<String> = ["eval", "replay", "review", "recent", "snapshot", "help", "--help"]

    static func run(_ args: [String]) -> Int32 {
        do {
            switch args.first {
            case "eval": return try eval(Array(args.dropFirst()))
            case "replay": return try replay(Array(args.dropFirst()))
            case "review": return review(Array(args.dropFirst()))
            case "recent": return recent(Array(args.dropFirst()))
            case "snapshot": return try MainActor.assumeIsolated { try Snapshot.run(dir: args.dropFirst().first ?? ".") }
            default:
                print(usage)
                return 0
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            return 2
        }
    }

    static let usage = """
    junction eval <url> [--from <bundleId>] [--name <app name>] [--title <window title>]
        Show where the current config would send a URL.
    junction replay [--json] [--all]
        Run the current config over every logged decision and report what would change.
        Exits 1 if it contradicts feedback or a choice you made in the picker.
    junction review [--mark]
        Print feedback, picker choices and rule errors since the last review,
        plus patterns in picker choices. --mark records that a review just happened.
    junction recent [n]
        Print the last n decisions (default 20) with any feedback.
    """

    // MARK: - eval

    private static func eval(_ args: [String]) throws -> Int32 {
        var opts = Options(args)
        guard let urlString = opts.positional.first, let url = URL(string: urlString) else {
            throw ConfigError(description: "usage: junction eval <url> [--from <bundleId>] [--title <title>]")
        }
        let opener = Opener(bundleId: opts.take("--from"), name: opts.take("--name"), windowTitle: opts.take("--title"))
        let context = RouteContext(url: url, opener: opener)
        let config = try Config()
        let result = config.route(context)
        var out: [String: Any] = ["target": result.target, "rule": result.rule ?? NSNull()]
        if let ws = context.slackWorkspace { out["slackWorkspace"] = ws }
        if !result.errors.isEmpty { out["errors"] = result.errors }
        if let t = config.target(result.target) { out["label"] = t.label }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    // MARK: - replay

    struct ReplayRow: Encodable {
        var decisionId: String
        var time: Date
        var url: String
        var source: String
        var label: String      // where the evidence says it should go
        var evidence: String   // "feedback", "picked" or "unconfirmed"
        var was: String        // where it went
        var now: String        // where the config sends it now
        var nowRule: String?
        var status: String
        var comment: String?
    }

    private static func replay(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let config = try Config()
        let store = Store.shared
        let feedback = latestVerdicts(store.feedback())
        var rows: [ReplayRow] = []

        for d in store.decisions() {
            guard let url = URL(string: d.url) else { continue }
            let fb = feedback[d.id]
            let label: String
            let evidence: String
            if let fb, fb.verdict == "wrong", let correct = fb.correctTarget {
                (label, evidence) = (correct, "feedback")
            } else if let fb, fb.verdict == "right", let target = d.target {
                (label, evidence) = (target, "feedback")
            } else if d.via == "picker", let target = d.target {
                (label, evidence) = (target, "picked")
            } else if let target = d.target {
                (label, evidence) = (target, "unconfirmed")
            } else {
                continue // cancelled picker: no label
            }

            let result = config.route(RouteContext(url: url, opener: d.opener))
            let now = result.target
            let was = d.via == "picker" ? "picker→\(d.target ?? "none")" : (d.target ?? "none")
            let status: String = switch evidence {
            case "feedback":
                now == label ? (d.target == label ? "ok" : "fixed")
                    : now == "picker" ? "asks" : "WRONG"
            case "picked":
                now == label ? "learned" : now == "picker" ? "ok" : "CONFLICT"
            default:
                now == label ? "ok" : "changed"
            }
            rows.append(ReplayRow(decisionId: d.id, time: d.time, url: d.url,
                                  source: RouteContext(url: url, opener: d.opener).sourceDescription,
                                  label: label, evidence: evidence, was: was, now: now, nowRule: result.rule,
                                  status: status, comment: fb?.comment ?? d.reason))
        }

        let failing = rows.contains { $0.status == "WRONG" || $0.status == "CONFLICT" }
        if opts.has("--json") {
            let shown = opts.has("--all") ? rows : rows.filter { $0.status != "ok" }
            let encoder = JSON.encoder
            encoder.outputFormatting.insert(.prettyPrinted)
            print(String(decoding: try encoder.encode(shown), as: UTF8.self))
            return failing ? 1 : 0
        }

        let counts = Dictionary(grouping: rows, by: \.status).mapValues(\.count)
        print("Replayed \(rows.count) labelled decisions against \(config.path.path)")
        for status in ["ok", "fixed", "learned", "asks", "changed", "WRONG", "CONFLICT"] where counts[status] != nil {
            print("  \(status.padding(toLength: 9, withPad: " ", startingAt: 0)) \(counts[status]!)")
        }
        print("""

        ok        matches the evidence
        fixed     feedback said it was wrong; the config now gets it right
        learned   you picked this in the picker; the config now does it automatically
        asks      feedback named a target; the config now shows the picker instead
        changed   auto-routed with no feedback, and the config now sends it elsewhere (check these)
        WRONG     contradicts explicit feedback
        CONFLICT  you picked X in the picker; the config now sends it somewhere else
        """)
        for status in ["WRONG", "CONFLICT", "changed", "fixed", "learned", "asks"] {
            let group = rows.filter { $0.status == status }
            guard !group.isEmpty else { continue }
            print("\n## \(status) (\(group.count))")
            for r in group.prefix(opts.has("--all") ? .max : 40) {
                print("- [\(r.decisionId)] \(r.url)")
                print("    \(r.source) · \(r.evidence) says \(r.label) · was \(r.was) · now \(r.now)\(r.nowRule.map { " (rule: \($0))" } ?? "")")
                if let c = r.comment { print("    “\(c)”") }
            }
            if group.count > 40, !opts.has("--all") { print("  … \(group.count - 40) more (use --all)") }
        }
        return failing ? 1 : 0
    }

    /// The latest right/wrong verdict per decision. Notes don't override verdicts,
    /// but a note's comment is kept if the verdict had none.
    private static func latestVerdicts(_ feedback: [Feedback]) -> [String: Feedback] {
        var out: [String: Feedback] = [:]
        for f in feedback.sorted(by: { $0.time < $1.time }) {
            if f.verdict == "note" {
                if out[f.decisionId] == nil { out[f.decisionId] = f }
                else if out[f.decisionId]?.comment == nil { out[f.decisionId]?.comment = f.comment }
            } else {
                out[f.decisionId] = f
            }
        }
        return out
    }

    // MARK: - review

    private static func review(_ args: [String]) -> Int32 {
        let opts = Options(args)
        let store = Store.shared
        if opts.has("--mark") {
            do { try store.markReviewed() } catch { fputs("error: \(error)\n", stderr); return 2 }
            print("Marked reviewed at \(local(Date()))")
            return 0
        }
        let since = store.lastReview ?? .distantPast
        let decisions = store.decisions()
        let byId = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let config = try? Config()
        let label = { (id: String?) in config?.target(id)?.label.appending(" [\(id!)]") ?? id ?? "nowhere (cancelled)" }

        print("# Junction review")
        print("Last review: \(store.lastReview.map(local) ?? "never")")
        print("Config: \(Config.defaultPath.path)\(config == nil ? " (FAILS TO LOAD)" : "")")

        let newFeedback = store.feedback().filter { $0.time > since }
        print("\n## Feedback since last review (\(newFeedback.count))")
        for f in newFeedback {
            guard let d = byId[f.decisionId] else { continue }
            print("- [\(d.id)] \(local(d.time)) \(d.url)")
            print("    \(source(d)) → \(label(d.target)) via \(how(d))")
            switch f.verdict {
            case "wrong": print("    ✗ WRONG, should have been \(label(f.correctTarget))\(f.reopened == true ? " (reopened there)" : "")")
            case "right": print("    ✓ right")
            default: print("    ✎ note")
            }
            if let c = f.comment { print("    comment: “\(c)”") }
            if let t = d.opener.windowTitle { print("    window: \(t)") }
            if let config, let url = URL(string: d.url) {
                let r = config.route(RouteContext(url: url, opener: d.opener))
                print("    current config → \(r.target)\(r.rule.map { " (rule: \($0))" } ?? "")")
            }
        }

        let picks = decisions.filter { $0.via == "picker" && $0.time > since }
        print("\n## Picker decisions since last review (\(picks.count))")
        for d in picks {
            print("- [\(d.id)] \(local(d.time)) \(d.url)")
            print("    \(source(d)) → \(label(d.target))\(d.pickerMillis.map { " after \(Double($0) / 1000)s" } ?? "")\(d.rule.map { " (rule \($0) sent it to the picker)" } ?? "")")
            if let r = d.reason { print("    reason: “\(r)”") }
        }

        let errors = decisions.filter { $0.time > since && $0.ruleErrors != nil }
        if !errors.isEmpty {
            print("\n## Rule errors since last review (\(errors.count))")
            for d in errors { print("- [\(d.id)] \(d.url): \(d.ruleErrors!.joined(separator: "; "))") }
        }

        // Repeated picker choices for the same host and source are candidates for new rules.
        let allPicks = decisions.filter { $0.via == "picker" && $0.target != nil }
        let groups = Dictionary(grouping: allPicks) { "\($0.host) \(source($0))" }
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }
        print("\n## Picker patterns, all time (host + source picked 2+ times)")
        for (key, ds) in groups.prefix(30) {
            let counts = Dictionary(grouping: ds, by: { $0.target! }).mapValues(\.count)
                .sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            print("- \(key): \(counts)")
        }

        let recentCount = decisions.filter { $0.time > since }.count
        let unflagged = decisions.filter { $0.time > since && $0.via != "picker" }.count
        print("\n## Totals since last review")
        print("\(recentCount) decisions: \(picks.count) via picker, \(unflagged) automatic, \(newFeedback.count) feedback entries")
        return 0
    }

    // MARK: - recent

    private static func recent(_ args: [String]) -> Int32 {
        let n = args.first.flatMap(Int.init) ?? 20
        let store = Store.shared
        let feedback = Dictionary(grouping: store.feedback(), by: \.decisionId)
        for d in store.decisions().suffix(n) {
            print("[\(d.id)] \(local(d.time)) \(d.url)")
            print("    \(source(d)) → \(d.target ?? "cancelled") via \(how(d))\(d.reason.map { " “\($0)”" } ?? "")")
            for f in feedback[d.id] ?? [] {
                print("    \(f.verdict)\(f.correctTarget.map { " → \($0)" } ?? "")\(f.comment.map { " “\($0)”" } ?? "")")
            }
        }
        return 0
    }

    // MARK: - helpers

    private static func source(_ d: Decision) -> String {
        if let ws = d.slackWorkspace { return "from Slack · \(ws)" }
        return "from \(d.opener.displayName)"
    }

    private static func how(_ d: Decision) -> String {
        switch d.via {
        case "picker": "picker"
        case "fallback": "fallback"
        default: "rule \(d.rule ?? "?")"
        }
    }

    private static let localFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f
    }()

    private static func local(_ date: Date) -> String { localFormat.string(from: date) }

    /// Tiny flag parser: `--flag value` pairs and bare `--flag`s.
    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        init(_ args: [String]) {
            var i = 0
            let valued: Set<String> = ["--from", "--name", "--title"]
            while i < args.count {
                let a = args[i]
                if valued.contains(a), i + 1 < args.count {
                    values[a] = args[i + 1]
                    i += 2
                } else if a.hasPrefix("--") {
                    flags.insert(a)
                    i += 1
                } else {
                    positional.append(a)
                    i += 1
                }
            }
        }

        mutating func take(_ key: String) -> String? { values[key] }
        func has(_ flag: String) -> Bool { flags.contains(flag) }
    }
}
