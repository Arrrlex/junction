import AppKit
import SwiftUI

/// A borderless floating panel that can take keyboard focus, hosting a SwiftUI view.
/// Key presses go to `onKey` first; returning true swallows the event.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?
    private var monitor: Any?
    private var closing = false

    init<V: View>(rootView: V) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        // Junction usually isn't the active app when a link arrives (macOS may refuse to
        // activate it), and panels hide when their app is inactive by default.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: rootView)
        // Without .intrinsicContentSize the hosting view reports a fitting size of 0×0,
        // and the panel is shown with no area at all.
        host.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel near the mouse pointer, kept on screen.
    func showNearMouse() {
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 400, height: 300)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
        log("showing panel at \(frame) on screen \(screen.localizedName)")

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.onKey?(event) == true ? nil : event
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Clicking elsewhere dismisses the panel.
    override func resignKey() {
        super.resignKey()
        log("panel resigned key; app active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow)) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        dismiss()
    }

    func dismiss() {
        guard !closing else { return }
        closing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        orderOut(nil)
        onClose?()
    }
}

enum Keys {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let up: UInt16 = 126
    static let down: UInt16 = 125

    /// 0-based index for the digit keys 1–9.
    static func digitIndex(_ event: NSEvent) -> Int? {
        guard let c = event.charactersIgnoringModifiers, c.count == 1, let n = Int(c), (1...9).contains(n) else { return nil }
        return n - 1
    }

    /// Index of the target chosen by this key press: its letter, or its position via 1–9.
    static func targetIndex(_ event: NSEvent, in targets: [Target]) -> Int? {
        if let i = digitIndex(event), targets.indices.contains(i) { return i }
        guard let c = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return targets.firstIndex { $0.key == c }
    }

    static func flags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }
}

/// One selectable browser row, shared by the picker and the feedback panel.
struct TargetRow: View {
    var index: Int
    var target: Target
    var selected: Bool
    var badge: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(target.key?.uppercased() ?? "\(index + 1)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Image(nsImage: Launcher.icon(for: target))
                .resizable()
                .frame(width: 22, height: 22)
            Text(target.label)
            Spacer()
            if let badge {
                Text(badge).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct PanelChrome<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(width: width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
