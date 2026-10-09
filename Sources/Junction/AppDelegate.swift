import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let configs = ConfigStore()
    private let store = Store.shared
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var hotKeySpec: String?
    /// URLs that arrived while the picker was already open.
    private var queue: [RouteContext] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered here, not in didFinishLaunching, so the URL that launched us isn't missed.
        let events = NSAppleEventManager.shared()
        events.setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                               forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        events.setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:reply:)),
                               forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launched; accessibility=\(OpenerInfo.hasAccessibility)")
        applySettings()
    }

    // MARK: - Incoming URLs

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        route(RouteContext(url: url, opener: OpenerInfo.from(event: event)))
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let opener = OpenerInfo.from(event: event)
        let count = list.numberOfItems
        let items = count == 0 ? [list] : (1...count).compactMap { list.atIndex($0) }
        for item in items {
            if let url = item.fileURLValue { route(RouteContext(url: url, opener: opener)) }
        }
    }

    private func route(_ context: RouteContext) {
        log("received \(context.url.absoluteString) \(context.sourceDescription); accessibility=\(OpenerInfo.hasAccessibility)")
        if Picker.isShowing {
            queue.append(context)
            return
        }
        applySettings()
        guard let config = configs.current() else {
            log("no usable config, opening \(context.url) in Safari")
            NSWorkspace.shared.open([context.url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let result = config.route(context)
        var decision = Decision(
            id: newId(), time: Date(), url: context.url.absoluteString, opener: context.opener,
            slackWorkspace: context.slackWorkspace, via: result.rule == nil ? "fallback" : "rule",
            rule: result.rule, target: nil, ruleErrors: result.errors.isEmpty ? nil : result.errors
        )

        if let target = config.target(result.target) {
            do {
                try Launcher.open(context.url, in: target)
                decision.target = target.id
                store.append(decision)
                return
            } catch {
                // Fall through to the picker so the URL isn't lost.
                decision.ruleErrors = (decision.ruleErrors ?? []) + ["open \(target.id): \(error)"]
            }
        }

        let notice = [configs.error.map { "Config error: \($0)" }, decision.ruleErrors?.joined(separator: "; ")]
            .compactMap { $0 }.joined(separator: "\n")
        let shownAt = Date()
        Picker.show(context: context, targets: config.targets, rule: result.rule,
                    notice: notice.isEmpty ? nil : notice) { [self] outcome in
            decision.via = "picker"
            decision.pickerMillis = Int(Date().timeIntervalSince(shownAt) * 1000)
            switch outcome {
            case let .open(target):
                do {
                    try Launcher.open(context.url, in: target)
                    decision.target = target.id
                } catch {
                    decision.ruleErrors = (decision.ruleErrors ?? []) + ["open \(target.id): \(error)"]
                    NSApp.hide(nil)
                }
            case .copied, .cancelled:
                NSApp.hide(nil)
            }
            store.append(decision)
            if !queue.isEmpty {
                let next = queue.removeFirst()
                DispatchQueue.main.async { self.route(next) }
            }
        }
    }

    // MARK: - Settings, menu bar and hotkey

    /// Applies hotkey and menu bar settings from the config, if they've changed.
    private func applySettings() {
        let config = configs.current()
        let spec = config?.hotkey ?? "ctrl+alt+cmd+b"
        if spec != hotKeySpec {
            hotKey = HotKey(spec) { [weak self] in self?.showFeedback() }
            hotKeySpec = spec
            if hotKey == nil { log("couldn't register hotkey \(spec)") }
        }
        let wantIcon = config?.menuBarIcon ?? true
        if wantIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .heavy)
            item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Junction")?
                .withSymbolConfiguration(symbol)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !wantIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func showFeedback(selecting id: String? = nil) {
        guard !Picker.isShowing else { return }
        let targets = configs.current()?.targets ?? []
        FeedbackPanel.show(store: store, targets: targets, selectedId: id)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = configs.current()
        let feedbackItem = item("Give feedback on routing…") { [weak self] in self?.showFeedback() }
        if let spec = hotKeySpec, let equivalent = HotKey.menuEquivalent(spec) {
            feedbackItem.keyEquivalent = equivalent.key
            feedbackItem.keyEquivalentModifierMask = equivalent.modifiers
        }
        menu.addItem(feedbackItem)

        let recent = store.decisions().suffix(6).reversed()
        if !recent.isEmpty {
            menu.addItem(.separator())
            for d in recent {
                let label = config?.target(d.target)?.label ?? d.target ?? "cancelled"
                menu.addItem(item("\(d.host) → \(label)") { [weak self] in self?.showFeedback(selecting: d.id) })
            }
        }

        menu.addItem(.separator())
        if let error = configs.error {
            let errorItem = NSMenuItem(title: "⚠︎ Config error (using last good config)", action: nil, keyEquivalent: "")
            errorItem.toolTip = error
            menu.addItem(errorItem)
        }
        if !OpenerInfo.hasAccessibility {
            menu.addItem(item("Grant Accessibility access (for Slack workspaces)…") { OpenerInfo.requestAccessibility() })
        }
        menu.addItem(item("Edit config") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.configs.path.resolvingSymlinksInPath())
        })
        menu.addItem(item("Show data folder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.decisionsFile])
        })
        let login = item("Launch at login") {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled { try service.unregister() } else { try service.register() }
            } catch {
                log("launch at login: \(error)")
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Junction") { NSApp.terminate(nil) })
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
