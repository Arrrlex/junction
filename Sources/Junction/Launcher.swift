import AppKit

enum Launcher {
    /// Where Chromium-based browsers keep their profiles, relative to Application Support.
    private static let chromiumDataDirs: [String: String] = [
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.google.Chrome": "Google/Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    static func open(_ url: URL, in target: Target) throws {
        guard let appURL = appURL(for: target.app) else {
            throw ConfigError(description: "can't find app \"\(target.app)\"")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        var args = target.args
        var profileName: String?
        if let profile = target.profile {
            guard let found = chromiumProfile(appURL: appURL, profile: profile) else {
                throw ConfigError(description: "can't find profile \"\(profile)\" for \(target.app)")
            }
            args.append("--profile-directory=\(found.directory)")
            profileName = found.name
        }

        if args.isEmpty {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            // Arguments are only passed to a fresh process. For Chromium this second
            // process hands the URL to the running browser and exits, which is the
            // only way to pick a profile from outside.
            config.createsNewApplicationInstance = true
            config.arguments = args + [url.absoluteString]
            // Activating the browser brings forward its most recent window, which may be
            // another profile's window on another Space. Raise the profile's window instead.
            config.activates = profileName == nil
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            if let profileName, let bundleId = Bundle(url: appURL)?.bundleIdentifier {
                WindowRaiser.raise(bundleId: bundleId, profileName: profileName)
            }
        }
    }

    /// Accepts an app name ("Brave Browser") or a bundle id ("com.brave.Browser").
    static func appURL(for app: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/Applications", "\(home)/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications"]
            .map { URL(fileURLWithPath: "\($0)/\(app).app") }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func icon(for target: Target) -> NSImage {
        guard let url = appURL(for: target.app) else { return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Finds a profile by display name ("Work") or directory ("Profile 1"),
    /// returning both.
    static func chromiumProfile(appURL: URL, profile: String) -> (directory: String, name: String)? {
        guard let bundleId = Bundle(url: appURL)?.bundleIdentifier, let dataDir = chromiumDataDirs[bundleId] else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDir)
        guard
            let data = try? Data(contentsOf: support.appendingPathComponent("Local State")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return nil }
        if let name = cache[profile]?["name"] as? String { return (profile, name) }
        return cache.first { ($0.value["name"] as? String) == profile }.map { ($0.key, profile) }
    }
}

/// Brings a specific Chromium profile's window to the front, switching Space if needed.
///
/// Chromium window titles end in " - <profile name>" when several profiles are in use;
/// that's how the window is found. Needs Accessibility access.
enum WindowRaiser {
    static func raise(bundleId: String, profileName: String) {
        guard OpenerInfo.hasAccessibility else {
            log("no Accessibility access, so can't raise the \(profileName) window")
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
            return
        }
        attempt(bundleId: bundleId, profileName: profileName, tick: 1)
    }

    private static let interval = 0.25
    /// How long to look for the profile's window (a new one takes a moment to appear).
    private static let maxTicks = 12
    /// After raising, how long to watch for the browser bringing another of its own windows forward.
    private static let watchTicks = 4

    private static func attempt(bundleId: String, profileName: String, tick: Int, raisedAt: Int? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            // The helper process shares the bundle id; the real browser is the oldest one.
            let browser = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { !$0.isTerminated }
                .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
            guard let browser else { return }
            let app = AXUIElementCreateApplication(browser.processIdentifier)
            let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            let titles = windows.map { (attribute($0, kAXTitleAttribute) as? String) ?? "" }

            let match = zip(windows, titles).first { _, title in
                title.components(separatedBy: " - ").last == profileName
            }?.0
            guard let match else {
                if tick < maxTicks {
                    attempt(bundleId: bundleId, profileName: profileName, tick: tick + 1, raisedAt: raisedAt)
                } else {
                    log("no \(profileName) window found; titles: \(titles)")
                    browser.activate()
                }
                return
            }

            guard let raisedAt else {
                bringToFront(match, of: app)
                attempt(bundleId: bundleId, profileName: profileName, tick: tick + 1, raisedAt: tick)
                return
            }
            // The browser may activate its own most recent window a moment after receiving
            // the URL; undo that. But if another app is now in front (e.g. the user switched
            // Space), leave it alone rather than pulling them back.
            let focused = attribute(app, kAXFocusedWindowAttribute)
            if browser.isActive, focused.map({ !CFEqual($0, match) }) ?? true {
                bringToFront(match, of: app)
            }
            if tick - raisedAt < watchTicks {
                attempt(bundleId: bundleId, profileName: profileName, tick: tick + 1, raisedAt: raisedAt)
            }
        }
    }

    private static func bringToFront(_ window: AXUIElement, of app: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
