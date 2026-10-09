import DesignSystem
import SwiftUI

/// A question written out as a link — "Which of these could I cancel?" — that opens Ask with it on a fresh
/// conversation. The sparkle and iris mark it as the assistant, like `DSAskButton` in card headers.
struct AskLink: View {
    let title: String
    let question: String
    @Environment(AppModel.self) private var app

    init(_ title: String, question: String? = nil) {
        self.title = title
        self.question = question ?? title
    }

    var body: some View {
        Button { app.ask(question) } label: {
            Label(title, systemImage: "sparkle")
                .dsFont(.callout)
                .foregroundStyle(Color.ds.iris)
                .multilineTextAlignment(.leading)
                .frame(minHeight: DSSize.hitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Asks the assistant")
    }
}
