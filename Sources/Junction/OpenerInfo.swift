import AppKit
import ApplicationServices

enum OpenerInfo {
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
            windowTitle: focusedWindowTitle(pid: pid)
        )
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
