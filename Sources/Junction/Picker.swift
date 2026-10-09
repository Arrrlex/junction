import AppKit
import SwiftUI

/// The Bumpr-style chooser shown when no rule decides where a URL goes.
///
/// Each browser's letter (or 1–9) opens it straight away. Feedback on why is
/// given afterwards, in the feedback window.
final class PickerModel: ObservableObject {
    let context: RouteContext
    let targets: [Target]
    let rule: String?
    let notice: String?
    @Published var selection = 0

    init(context: RouteContext, targets: [Target], rule: String?, notice: String?) {
        self.context = context
        self.targets = targets
        self.rule = rule
        self.notice = notice
    }
}

enum PickerOutcome {
    case open(Target)
    case copied
    case cancelled
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    var choose: (Int) -> Void

    var body: some View {
        PanelChrome(width: 420) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.context.url.host ?? model.context.url.absoluteString)
                        .font(.headline)
                    Text(model.context.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(model.context.sourceDescription + (model.rule.map { " · rule: \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                }
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(model.targets.enumerated()), id: \.element.id) { i, target in
                        TargetRow(index: i, target: target, selected: i == model.selection)
                            .onTapGesture { choose(i) }
                    }
                }
                Text("letter to open · ↑↓ ↵ open selected · ⌘C copy URL · esc cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Picker {
    private static var current: KeyPanel?

    static var isShowing: Bool { current != nil }

    static func show(context: RouteContext, targets: [Target], rule: String?, notice: String?,
                     completion: @escaping (PickerOutcome) -> Void) {
        let model = PickerModel(context: context, targets: targets, rule: rule, notice: notice)
        var outcome: PickerOutcome?
        var panel: KeyPanel!

        func finish(_ result: PickerOutcome) {
            guard outcome == nil else { return }
            outcome = result
            panel.dismiss()
        }
        func choose(_ i: Int) {
            guard targets.indices.contains(i) else { return }
            finish(.open(targets[i]))
        }

        panel = KeyPanel(rootView: PickerView(model: model, choose: choose))
        panel.onKey = { event in
            let flags = Keys.flags(event)
            if flags == .command, event.charactersIgnoringModifiers == "c" {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(context.url.absoluteString, forType: .string)
                finish(.copied); return true
            }
            switch event.keyCode {
            case Keys.escape: finish(.cancelled); return true
            case Keys.returnKey: choose(model.selection); return true
            case Keys.up: model.selection = max(0, model.selection - 1); return true
            case Keys.down: model.selection = min(targets.count - 1, model.selection + 1); return true
            default: break
            }
            if flags.isEmpty || flags == .shift, let i = Keys.targetIndex(event, in: targets) {
                choose(i); return true
            }
            return false
        }
        panel.onClose = {
            current = nil
            completion(outcome ?? .cancelled)
        }
        current = panel
        panel.showNearMouse()
    }
}
