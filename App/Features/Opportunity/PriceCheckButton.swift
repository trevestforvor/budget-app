import DesignSystem
import SwiftUI
import TipKit

/// Opportunity cost's way in: a glass circle stacked above Ask's at the trailing end of the tab bar, on every tab but
/// Ask, so a price check is one tap from anywhere. A tip says what it's for the first time it shows.
struct PriceCheckButton: View {
    @Environment(AppModel.self) private var app
    private let tip = PriceCheckTip()

    static let size: CGFloat = 54

    var body: some View {
        Button {
            tip.invalidate(reason: .actionPerformed)
            app.openOpportunity()
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.ds.ink)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .popoverTip(tip, arrowEdge: .bottom)
        .accessibilityLabel("Check a price")
        .accessibilityHint("What a price costs in hours of work")
        .accessibilityIdentifier("priceCheck")
    }
}

struct PriceCheckTip: Tip {
    var title: Text { Text("Check a price") }
    var message: Text? { Text("Scan or type a price to see it in hours of work, before and after tax, and what it'd grow to invested instead.") }
    var image: Image? { Image(systemName: "tag") }
}

extension View {
    /// The price-check button over a tab's content, just above Ask in the tab bar. Inside the tab its safe area already
    /// ends at the bar; Ask's circle is centered about 52pt in from the trailing edge. Scrolling content gets room at
    /// its end, so the last row can come up clear of the button, and the button steps aside while a toast or a
    /// selection bar is using the bottom edge (`DSBottomEdge`), so their buttons stay reachable.
    func priceCheckButton() -> some View { modifier(PriceCheckButtonPlacement()) }
}

private struct PriceCheckButtonPlacement: ViewModifier {
    @State private var bottomEdge = DSBottomEdge()

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, PriceCheckButton.size + DSSpace.sm, for: .scrollContent)
            .environment(\.dsBottomEdge, bottomEdge)
            .overlay(alignment: .bottomTrailing) {
                if !bottomEdge.isBusy {
                    PriceCheckButton()
                        .padding(.trailing, 52 - PriceCheckButton.size / 2)
                        .padding(.bottom, DSSpace.sm)
                        .ignoresSafeArea(.keyboard)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(DSMotion.standard, value: bottomEdge.isBusy)
    }
}
