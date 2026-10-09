import AppKit
import SwiftUI

/// `junction snapshot <dir>` renders the picker and feedback panels to PNGs,
/// so their layout can be checked without clicking through the real thing.
enum Snapshot {
    @MainActor
    static func run(dir: String) throws -> Int32 {
        let config = try Config()
        let context = RouteContext(
            url: URL(string: "https://example.com/events/meetup?utm_source=slack")!,
            opener: Opener(bundleId: "com.tinyspeck.slackmacgap", name: "Slack",
                           windowTitle: "events (Channel) - Acme Corp - Slack")
        )
        let picker = PickerModel(context: context, targets: config.targets, rule: nil, notice: nil)
        try render(PickerView(model: picker, choose: { _ in }), to: "\(dir)/picker.png")

        let rows = Store.shared.decisions().suffix(8).reversed().map { FeedbackModel.Row(decision: $0, feedback: []) }
        let label = { (id: String?) in config.target(id)?.label ?? id ?? "nowhere" }
        for step in [FeedbackModel.Step.link, .target, .notes] {
            let feedback = FeedbackModel(rows: Array(rows), targets: config.targets, selectedId: nil)
            feedback.step = step
            feedback.chosenTarget = config.targets.first
            try render(FeedbackView(model: feedback, labelFor: label, chooseLink: { _ in }, chooseTarget: { _ in }),
                       to: "\(dir)/feedback-\(step).png")
        }
        print("wrote picker.png and feedback-*.png to \(dir)")
        let panel = KeyPanel(rootView: PickerView(model: picker, choose: { _ in }))
        panel.layoutIfNeeded()
        print("picker panel fittingSize before showing: \(panel.contentView?.fittingSize ?? .zero)")
        return 0
    }

    @MainActor
    private static func render<V: View>(_ view: V, to path: String) throws {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw ConfigError(description: "render failed") }
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: path))
    }
}
