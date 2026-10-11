import AppKit
import ApplicationServices

enum OpenerInfo {
    static let signalBundleId = "org.whispersystems.signal-desktop"
    /// CSS classes around the conversation name in Signal's header
    /// (ts/components/conversation/ConversationHeader). Usually the header is a button
    /// titled with the chat name, and the inner title element doesn't show up separately.
    private static let signalChatClasses: Set = [
        "module-ConversationHeader__header--clickable",
        "module-ConversationHeader__header__info__title",
    ]

    /// Works out which app sent an "open URL" Apple event, and the title of its focused window.
    static func from(event: NSAppleEventDescriptor) -> Opener {
        // 'spid' = keySenderPIDAttr
        let pidDescriptor = event.attributeDescriptor(forKeyword: AEKeyword(0x7370_6964))
        guard
            let pid = pidDescriptor?.int32Value, pid > 0,
            let app = NSRunningApplication(processIdentifier: pid)
        else { return Opener() }
        return Opener(
            bundleId: app.bundleIdentifier,
            name: app.localizedName,
            path: app.bundleURL?.path,
            windowTitle: focusedWindowTitle(pid: pid),
            chat: app.bundleIdentifier == signalBundleId ? signalChat(pid: pid) : nil
        )
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted(), let window = focusedWindow(pid: pid) else { return nil }
        return attribute(window, kAXTitleAttribute) as? String
    }

    /// Signal's window title is always "Signal", so the chat name is read from the
    /// conversation header inside the window instead.
    static func signalChat(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        enableElectronAccessibility(pid: pid)
        // If Signal's accessibility tree wasn't switched on yet, it takes a moment to appear.
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            guard let window = focusedWindow(pid: pid),
                  let header = firstElement(in: window, withClassIn: signalChatClasses) else { continue }
            let title = attribute(header, kAXTitleAttribute) as? String ?? ""
            let text = title.isEmpty ? staticTexts(in: header).joined() : title
            // Signal wraps names in Unicode direction isolates (U+2068 … U+2069).
            let name = text.filter { $0 != "\u{2068}" && $0 != "\u{2069}" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        log("couldn't find the open chat's name in Signal's window")
        return nil
    }

    /// Electron apps only expose their window contents to Accessibility once asked to.
    /// Done at launch too, so the tree is ready by the time a link is clicked.
    static func enableElectronAccessibility(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func watchChatApps() {
        guard AXIsProcessTrusted() else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: signalBundleId) {
            enableElectronAccessibility(pid: app.processIdentifier)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == signalBundleId else { return }
            enableElectronAccessibility(pid: app.processIdentifier)
        }
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard let window = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Breadth-first, because the header sits much higher in the tree than the messages.
    /// Chromium exposes each element's CSS classes as AXDOMClassList.
    private static func firstElement(in root: AXUIElement, withClassIn classes: Set<String>, limit: Int = 5000) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < limit {
            let element = queue[index]
            index += 1
            if let list = attribute(element, "AXDOMClassList") as? [String], !classes.isDisjoint(with: list) { return element }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func staticTexts(in element: AXUIElement) -> [String] {
        if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole as String {
            return [attribute(element, kAXValueAttribute) as? String ?? ""]
        }
        return children(element).flatMap(staticTexts)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
