import Foundation
import JavaScriptCore

/// A browser (optionally a specific profile) that URLs can be opened in.
struct Target: Identifiable, Hashable {
    var id: String
    var app: String
    var profile: String?
    var args: [String]
    var label: String
    /// Single-letter shortcut in the picker and feedback window.
    var key: String?
}

struct RouteResult {
    /// Name of the matching rule, nil if none matched.
    var rule: String?
    /// Target id, or "picker".
    var target: String
    var errors: [String]
}

struct ConfigError: Error, CustomStringConvertible {
    var description: String
}

/// The user's config.js, evaluated with JavaScriptCore.
///
/// The config is plain JS so rules can be arbitrary functions, and so it can be
/// changed without rebuilding the app.
final class Config {
    let path: URL
    let targets: [Target]
    let hotkey: String
    let menuBarIcon: Bool
    private let context: JSContext

    static let defaultPath: URL = {
        if let p = ProcessInfo.processInfo.environment["JUNCTION_CONFIG"] {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/junction/config.js")
    }()

    /// Helpers available to config.js. Kept as plain functions so the config
    /// reads like ordinary JS.
    private static let prelude = """
    var __errors = [];
    function __escape(s) { return s.replace(/[.+?^${}()|[\\]\\\\]/g, "\\\\$&"); }
    /// Match host+path against Finicky-style globs, e.g. "*.linear.app/*".
    function glob(...patterns) {
      const res = patterns.map(p => new RegExp("^" + p.split("*").map(__escape).join(".*") + "$", "i"));
      return ({ url }) => res.some(r => r.test(url.host + url.pathname));
    }
    /// Match a domain or any of its subdomains.
    function domain(...names) {
      return ({ url }) => names.some(n => url.hostname === n || url.hostname.endsWith("." + n));
    }
    /// Match the bundle id of the app the link was clicked in.
    function from(...bundleIds) {
      return ({ opener }) => bundleIds.includes(opener.bundleId);
    }
    /// Match the Slack workspace the link was clicked in.
    function slack(...workspaces) {
      return ({ slackWorkspace }) => workspaces.includes(slackWorkspace);
    }
    function any(...fs) { return ctx => fs.some(f => __toFn(f)(ctx)); }
    function all(...fs) { return ctx => fs.every(f => __toFn(f)(ctx)); }
    function not(f) { return ctx => !__toFn(f)(ctx); }
    function __toFn(m) {
      if (typeof m === "function") return m;
      if (typeof m === "string") return glob(m);
      if (Array.isArray(m)) return glob(...m);
      throw new Error("match must be a function, glob string or array of globs");
    }
    function __prepare() {
      __config.rules = (__config.rules || []).map((r, i) => ({
        ...r, name: r.name || ("rule " + (i + 1)), __fn: __toFn(r.match)
      }));
    }
    function __route(ctx) {
      __errors = [];
      for (const r of __config.rules) {
        try {
          if (r.__fn(ctx)) return { rule: r.name, target: r.target, errors: __errors };
        } catch (e) {
          __errors.push(r.name + ": " + e);
        }
      }
      return { rule: null, target: __config.fallback || "picker", errors: __errors };
    }
    """

    init(path: URL = Config.defaultPath) throws {
        self.path = path
        let source = try String(contentsOf: path, encoding: .utf8)
        let context = JSContext()!
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }

        context.evaluateScript(Self.prelude)
        // JavaScriptCore doesn't do ES modules; turn `export default {...}` into an assignment.
        let script = source.replacingOccurrences(of: "export default", with: "globalThis.__config =")
        context.evaluateScript(script, withSourceURL: path)
        if let exception { throw ConfigError(description: "config.js: \(exception)") }
        guard let config = context.objectForKeyedSubscript("__config"), config.isObject else {
            throw ConfigError(description: "config.js must `export default { ... }`")
        }
        context.evaluateScript("__prepare()")
        if let exception { throw ConfigError(description: "config.js rules: \(exception)") }

        // Targets keep the order they're written in, which is the picker order.
        let targetIds = context.evaluateScript("Object.keys(__config.targets || {})").toArray() as? [String] ?? []
        guard !targetIds.isEmpty else { throw ConfigError(description: "config.js has no targets") }
        var parsed = try targetIds.map { id in
            let t = config.forProperty("targets").forProperty(id)!
            guard let app = t.forProperty("app").toOptionalString() else {
                throw ConfigError(description: "target \(id) needs an `app`")
            }
            let profile = t.forProperty("profile").toOptionalString()
            return Target(
                id: id,
                app: app,
                profile: profile,
                args: t.forProperty("args").toArray() as? [String] ?? [],
                label: t.forProperty("label").toOptionalString() ?? [app, profile].compactMap { $0 }.joined(separator: " · "),
                key: t.forProperty("key").toOptionalString()?.lowercased()
            )
        }
        // Targets without an explicit key get the first letter of their label, if it's free.
        for i in parsed.indices where parsed[i].key == nil {
            let letter = parsed[i].label.prefix(1).lowercased()
            if !letter.isEmpty, !parsed.contains(where: { $0.key == letter }) { parsed[i].key = letter }
        }
        let keys = parsed.compactMap(\.key)
        if let dup = keys.first(where: { k in keys.filter { $0 == k }.count > 1 }) {
            throw ConfigError(description: "two targets share the key \"\(dup)\"")
        }
        targets = parsed

        let validTargets = Set(targetIds + ["picker"])
        let ruleTargets = context.evaluateScript("__config.rules.map(r => [r.name, String(r.target)])").toArray() as? [[String]] ?? []
        for pair in ruleTargets where !validTargets.contains(pair[1]) {
            throw ConfigError(description: "rule \"\(pair[0])\" has unknown target \"\(pair[1])\"")
        }
        let fallback = config.forProperty("fallback").toOptionalString() ?? "picker"
        guard validTargets.contains(fallback) else { throw ConfigError(description: "unknown fallback \"\(fallback)\"") }

        hotkey = config.forProperty("hotkey").toOptionalString() ?? "ctrl+alt+cmd+b"
        let icon = config.forProperty("menuBarIcon")
        menuBarIcon = icon?.isUndefined ?? true ? true : icon!.toBool()
        context.exceptionHandler = nil
        self.context = context
    }

    func target(_ id: String?) -> Target? {
        targets.first { $0.id == id }
    }

    func route(_ rc: RouteContext) -> RouteResult {
        var url: [String: Any] = [
            "href": rc.url.absoluteString,
            "protocol": (rc.url.scheme ?? "") + ":",
            "host": rc.url.host.map { h in rc.url.port.map { "\(h):\($0)" } ?? h }?.lowercased() ?? "",
            "hostname": rc.url.host?.lowercased() ?? "",
            "pathname": rc.url.path.isEmpty ? "/" : rc.url.path,
            "search": rc.url.query.map { "?" + $0 } ?? "",
            "hash": rc.url.fragment.map { "#" + $0 } ?? "",
        ]
        if rc.url.isFileURL { url["host"] = ""; url["hostname"] = "" }
        var opener: [String: Any] = [:]
        if let v = rc.opener.bundleId { opener["bundleId"] = v }
        if let v = rc.opener.name { opener["name"] = v }
        if let v = rc.opener.path { opener["path"] = v }
        if let v = rc.opener.windowTitle { opener["windowTitle"] = v }
        var ctx: [String: Any] = ["url": url, "opener": opener]
        if let ws = rc.slackWorkspace { ctx["slackWorkspace"] = ws }

        let route = context.objectForKeyedSubscript("__route")!
        guard let result = route.call(withArguments: [ctx]), result.isObject else {
            return RouteResult(rule: nil, target: "picker", errors: ["__route failed"])
        }
        return RouteResult(
            rule: result.forProperty("rule").toOptionalString(),
            target: result.forProperty("target").toOptionalString() ?? "picker",
            errors: result.forProperty("errors").toArray() as? [String] ?? []
        )
    }
}

/// Holds the current config and reloads it when the file changes.
final class ConfigStore {
    private(set) var config: Config?
    private(set) var error: String?
    private var loadedAt: Date?
    let path: URL

    init(path: URL = Config.defaultPath) {
        self.path = path
    }

    /// Returns the current config, reloading first if the file has changed.
    /// A broken config keeps the last good one in place and records the error.
    @discardableResult
    func current() -> Config? {
        let modified = (try? path.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if config == nil || modified != loadedAt {
            reload()
            loadedAt = modified
        }
        return config
    }

    func reload() {
        do {
            config = try Config(path: path)
            error = nil
        } catch {
            self.error = String(describing: error)
            log("\(self.error!)")
        }
    }
}

extension JSValue {
    func toOptionalString() -> String? {
        isUndefined || isNull ? nil : toString()
    }
}
