import AppKit
import SwiftUI

/// Hotkey window for giving feedback on a recent routing decision, in three steps:
///
/// 1. Which link? (1–9, or ↑↓ ↵)
/// 2. Where should it have gone? (a browser's letter, or ↑↓ ↵). Choosing where it
///    actually went counts as "right".
/// 3. Notes (optional; ↵ saves). If it was wrong, the URL is then reopened in the
///    right place.
///
/// Esc goes back a step, or closes from step 1.
final class FeedbackModel: ObservableObject {
    struct Row: Identifiable {
        var decision: Decision
        var feedback: [Feedback]
        var id: String { decision.id }
    }

    enum Step { case link, target, notes }

    let rows: [Row]
    let targets: [Target]
    @Published var step = Step.link
    @Published var selection: Int
    @Published var targetSelection = 0
    @Published var chosenTarget: Target?
    @Published var notes = ""

    init(rows: [Row], targets: [Target], selectedId: String?) {
        self.rows = rows
        self.targets = targets
        selection = rows.firstIndex { $0.id == selectedId } ?? 0
    }

    var selected: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    var wasRight: Bool { chosenTarget?.id == selected?.decision.target }
}

struct FeedbackView: View {
    @ObservedObject var model: FeedbackModel
    var labelFor: (String?) -> String
    var chooseLink: (Int) -> Void
    var chooseTarget: (Int) -> Void
    @FocusState private var notesFocused: Bool

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    var body: some View {
        PanelChrome(width: 620) {
            VStack(alignment: .leading, spacing: 10) {
                stepHeader
                Group {
                    switch model.step {
                    case .link: linkStep
                    case .target: targetStep
                    case .notes: notesStep
                    }
                }
                .frame(height: 260, alignment: .top)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.step) { _, step in notesFocused = step == .notes }
    }

    private var stepHeader: some View {
        HStack(spacing: 6) {
            stepLabel("1 Which link?", .link)
            Text("›").foregroundStyle(Color.secondary.opacity(0.5))
            stepLabel("2 Where should it have gone?", .target)
            Text("›").foregroundStyle(Color.secondary.opacity(0.5))
            stepLabel("3 Notes", .notes)
        }
        .font(.headline)
    }

    private func stepLabel(_ text: String, _ step: FeedbackModel.Step) -> some View {
        Text(text).foregroundStyle(model.step == step ? Color.primary : Color.secondary.opacity(0.5))
    }

    private var linkStep: some View {
        Group {
            if model.rows.isEmpty {
                Text("No routing decisions logged yet.").foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                                decisionRow(row, selected: i == model.selection, number: i < 9 ? i + 1 : nil)
                                    .id(row.id)
                                    .onTapGesture { chooseLink(i) }
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(model.selected?.id) }
                    .onChange(of: model.selection) { _, i in
                        if model.rows.indices.contains(i) { proxy.scrollTo(model.rows[i].id) }
                    }
                }
            }
        }
    }

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row = model.selected { decisionRow(row, selected: false) }
            VStack(spacing: 2) {
                ForEach(Array(model.targets.enumerated()), id: \.element.id) { i, target in
                    TargetRow(index: i, target: target, selected: i == model.targetSelection,
                              badge: target.id == model.selected?.decision.target ? "where it went" : nil)
                        .onTapGesture { chooseTarget(i) }
                }
            }
        }
    }

    private var notesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row = model.selected { decisionRow(row, selected: false) }
            Text(model.wasRight
                 ? "✓ It went to the right place (\(model.chosenTarget?.label ?? ""))."
                 : "✗ Should have gone to \(model.chosenTarget?.label ?? ""). It will be reopened there.")
                .font(.subheadline)
            TextField("Notes: why was it right or wrong? (optional)", text: $model.notes, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($notesFocused)
        }
    }

    private var hint: String {
        switch model.step {
        case .link: "1–9 or ↑↓ ↵ to choose · esc close"
        case .target: "letter or ↑↓ ↵ to choose · esc back"
        case .notes: model.wasRight ? "↵ save · esc back" : "↵ save and reopen · esc back"
        }
    }

    private func decisionRow(_ row: FeedbackModel.Row, selected: Bool, number: Int? = nil) -> some View {
        let d = row.decision
        let how = switch d.via {
        case "picker": d.target == nil ? "picker, cancelled" : "you picked"
        case "fallback": "fallback"
        default: "rule: \(d.rule ?? "?")"
        }
        let verdicts = row.feedback.map { f in
            f.verdict == "wrong" ? "✗" : f.verdict == "right" ? "✓" : "✎"
        }.joined()
        return HStack(spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(Self.timeFormat.string(from: d.time)).foregroundStyle(.secondary).font(.caption.monospacedDigit())
                Text(d.url).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verdicts)
            }
            HStack(spacing: 4) {
                Text(RouteContext(url: URL(string: d.url) ?? URL(fileURLWithPath: "/"), opener: d.opener).sourceDescription)
                Text("→ \(labelFor(d.target))").bold()
                Text("(\(how))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

enum FeedbackPanel {
    private static var current: KeyPanel?

    static func show(store: Store, targets: [Target], selectedId: String? = nil, limit: Int = 25) {
        current?.dismiss()
        let feedback = Dictionary(grouping: store.feedback(), by: \.decisionId)
        let rows = store.decisions().suffix(limit).reversed().map {
            FeedbackModel.Row(decision: $0, feedback: feedback[$0.id] ?? [])
        }
        let model = FeedbackModel(rows: Array(rows), targets: targets, selectedId: selectedId)
        var panel: KeyPanel!
        var reopenedSomething = false

        func chooseLink(_ i: Int) {
            guard model.rows.indices.contains(i) else { return }
            model.selection = i
            // Start on where it went, so ↵ alone means "it was right".
            model.targetSelection = targets.firstIndex { $0.id == model.rows[i].decision.target } ?? 0
            model.step = .target
        }

        func chooseTarget(_ i: Int) {
            guard targets.indices.contains(i) else { return }
            model.targetSelection = i
            model.chosenTarget = targets[i]
            model.step = .notes
        }

        func save() {
            guard let row = model.selected, let target = model.chosenTarget else { return }
            let notes = model.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            var reopened = false
            if !model.wasRight, let url = URL(string: row.decision.url) {
                do { try Launcher.open(url, in: target); reopened = true } catch { log("\(error)") }
            }
            reopenedSomething = reopened
            store.append(Feedback(id: newId(), decisionId: row.id, time: Date(),
                                  verdict: model.wasRight ? "right" : "wrong",
                                  correctTarget: model.wasRight ? nil : target.id,
                                  comment: notes.isEmpty ? nil : notes, reopened: reopened))
            panel.dismiss()
        }

        let labelFor = { (id: String?) in
            guard let id else { return "nowhere" }
            return targets.first { $0.id == id }?.label ?? id
        }
        panel = KeyPanel(rootView: FeedbackView(model: model, labelFor: labelFor, chooseLink: chooseLink, chooseTarget: chooseTarget))
        panel.onKey = { event in
            let flags = Keys.flags(event)
            switch model.step {
            case .link:
                switch event.keyCode {
                case Keys.escape: panel.dismiss()
                case Keys.up: model.selection = max(0, model.selection - 1)
                case Keys.down: model.selection = min(model.rows.count - 1, model.selection + 1)
                case Keys.returnKey: chooseLink(model.selection)
                default:
                    guard flags.isEmpty, let i = Keys.digitIndex(event), model.rows.indices.contains(i) else { return false }
                    chooseLink(i)
                }
                return true

            case .target:
                switch event.keyCode {
                case Keys.escape: model.step = .link
                case Keys.up: model.targetSelection = max(0, model.targetSelection - 1)
                case Keys.down: model.targetSelection = min(targets.count - 1, model.targetSelection + 1)
                case Keys.returnKey: chooseTarget(model.targetSelection)
                default:
                    guard flags.isEmpty || flags == .shift, let i = Keys.targetIndex(event, in: targets) else { return false }
                    chooseTarget(i)
                }
                return true

            case .notes:
                switch (event.keyCode, flags) {
                case (Keys.escape, _):
                    model.step = .target
                    panel.makeFirstResponder(nil)
                    return true
                // ⇧↵ is left to the text field for a new line.
                case (Keys.returnKey, let f) where !f.contains(.shift):
                    save()
                    return true
                default:
                    return false
                }
            }
        }
        panel.onClose = {
            if current === panel { current = nil }
            // Hand focus back to whatever was in front, unless a browser is taking it.
            if !reopenedSomething { NSApp.hide(nil) }
        }
        current = panel
        panel.showNearMouse()
    }
}
