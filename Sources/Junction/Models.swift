import Foundation

/// The app that asked macOS to open the URL, as best we can tell.
struct Opener: Codable, Hashable {
    var bundleId: String?
    var name: String?
    var path: String?
    /// Title of the opener's focused window. Needs Accessibility access.
    var windowTitle: String?
    /// Name of the open chat, for chat apps whose window title doesn't say (Signal).
    /// Needs Accessibility access.
    var chat: String?

    var displayName: String { name ?? bundleId ?? "unknown app" }
}

/// Everything a routing rule gets to look at.
struct RouteContext {
    var url: URL
    var opener: Opener

    /// Slack puts the workspace in the window title, e.g.
    /// "Sam (DM) - Acme Corp - 2 new items - Slack".
    var slackWorkspace: String? {
        guard opener.bundleId == "com.tinyspeck.slackmacgap", let title = opener.windowTitle else { return nil }
        return Self.slackWorkspace(fromTitle: title)
    }

    static func slackWorkspace(fromTitle title: String) -> String? {
        var parts = title.components(separatedBy: " - ")
        guard parts.count >= 2, parts.last == "Slack" else { return nil }
        parts.removeLast()
        while let last = parts.last, last.range(of: #"^\d+ new items?$"#, options: .regularExpression) != nil {
            parts.removeLast()
        }
        return parts.last
    }

    /// The Signal chat the link was clicked in, e.g. "AI Safety Berlin".
    var signalChat: String? {
        opener.bundleId == OpenerInfo.signalBundleId ? opener.chat : nil
    }

    /// One-line description of where the link came from, for the UI.
    var sourceDescription: String {
        if let ws = slackWorkspace { return "from Slack · \(ws)" }
        if let chat = signalChat { return "from Signal · \(chat)" }
        return "from \(opener.displayName)"
    }
}

/// One routing decision: a URL arrived and was sent somewhere (or the picker was cancelled).
struct Decision: Codable, Identifiable {
    var id: String
    var time: Date
    var url: String
    var opener: Opener
    var slackWorkspace: String?
    /// "rule" (a rule chose the target), "fallback" (no rule matched, fallback was a target),
    /// or "picker" (the picker was shown and the user chose).
    var via: String
    /// Name of the rule that matched, if any. A rule can also send a URL to the picker.
    var rule: String?
    /// Target id the URL was opened in. nil means the picker was cancelled.
    var target: String?
    /// Reason typed into the picker. Only in older entries: the picker no longer asks.
    var reason: String?
    /// How long the picker was open before a choice was made.
    var pickerMillis: Int?
    /// Errors thrown by rules while evaluating this URL.
    var ruleErrors: [String]?

    var host: String { URL(string: url)?.host ?? url }
}

/// The user's verdict on a decision, given after the fact.
struct Feedback: Codable, Identifiable {
    var id: String
    var decisionId: String
    var time: Date
    /// "right", "wrong" or "note".
    var verdict: String
    /// For "wrong": the target it should have gone to.
    var correctTarget: String?
    var comment: String?
    /// Whether the URL was reopened in correctTarget at the time.
    var reopened: Bool?
}

enum JSON {
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }()
}

/// Append-only JSONL logs in ~/Library/Application Support/Junction.
struct Store {
    let dir: URL

    static let shared = Store(
        dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Junction", isDirectory: true)
    )

    var decisionsFile: URL { dir.appendingPathComponent("decisions.jsonl") }
    var feedbackFile: URL { dir.appendingPathComponent("feedback.jsonl") }
    var lastReviewFile: URL { dir.appendingPathComponent("last-review") }

    func append(_ decision: Decision) { append(decision, to: decisionsFile) }
    func append(_ feedback: Feedback) { append(feedback, to: feedbackFile) }

    func decisions() -> [Decision] { read(decisionsFile) }
    func feedback() -> [Feedback] { read(feedbackFile) }

    var lastReview: Date? {
        guard let s = try? String(contentsOf: lastReviewFile, encoding: .utf8) else { return nil }
        return JSON.dateFormatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func markReviewed(at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (JSON.dateFormatter.string(from: date) + "\n").write(to: lastReviewFile, atomically: true, encoding: .utf8)
    }

    private func append<T: Encodable>(_ value: T, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var line = try JSON.encoder.encode(value)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            NSLog("Junction: failed to write \(file.lastPathComponent): \(error)")
        }
    }

    private func read<T: Decodable>(_ file: URL) -> [T] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSON.decoder.decode(T.self, from: Data(line.utf8))
        }
    }
}

func newId() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

/// Appends a timestamped line to ~/Library/Application Support/Junction/junction.log
/// (the unified system log isn't easy to read from scripts).
func log(_ message: String) {
    NSLog("Junction: %@", message)
    let line = "\(JSON.dateFormatter.string(from: Date())) \(message)\n"
    let file = Store.shared.dir.appendingPathComponent("junction.log")
    try? FileManager.default.createDirectory(at: Store.shared.dir, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: file)
    }
}
