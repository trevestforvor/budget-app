import SwiftUI

/// The ask field. Iris sparkle marks it as the AI surface; the send control is the one white button.
public struct DSAskField: View {
    @Binding private var text: String
    private let placeholder: String
    private let isBusy: Bool
    private let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: String = "Ask about your money", isBusy: Bool = false, onSubmit: @escaping () -> Void) {
        _text = text
        self.placeholder = placeholder
        self.isBusy = isBusy
        self.onSubmit = onSubmit
    }

    private var canSubmit: Bool { !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Sends and drops the keyboard, so the answer and any proposal card aren't hidden behind it.
    private func submit() {
        guard canSubmit else { return }
        isFocused = false
        onSubmit()
    }

    public var body: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.ds.iris)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, axis: .vertical)
                .dsFont(.body)
                .foregroundStyle(Color.ds.ink)
                .lineLimit(1...4)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
            Button {
                submit()
            } label: {
                Group {
                    if isBusy {
                        ProgressView().tint(Color.ds.inkInverse)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.ds.inkInverse)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.ds.ink))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit || isBusy ? 1 : 0.35)
            .accessibilityLabel(isBusy ? "Working" : "Send")
        }
        .padding(.leading, DSSpace.md)
        .padding(.trailing, DSSpace.xxs)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(Color.ds.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(isFocused ? Color.ds.iris.opacity(0.6) : Color.ds.hairlineStrong, lineWidth: 1)
        }
    }
}

/// A message from the user — right-aligned, raised surface.
public struct DSUserBubble: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack {
            Spacer(minLength: DSSpace.xxl)
            Text(text)
                .dsFont(.body)
                .foregroundStyle(Color.ds.ink)
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.sm)
                .background {
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(Color.ds.surfaceRaised)
                }
        }
    }
}

/// One figure in an answer: label on the left, ledger-computed amount on the right.
public struct DSFigureRow: View {
    private let label: String
    private let detail: String?
    private let value: Decimal
    private let currencyCode: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(label: String, detail: String? = nil, value: Decimal, currencyCode: String = "USD") {
        self.label = label
        self.detail = detail
        self.value = value
        self.currencyCode = currencyCode
    }

    public var body: some View {
        // Side by side; at accessibility sizes the amount goes under the label (as DSListRow does), so neither the
        // label nor the amount breaks mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xxs))
                                                         : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            DSAmountText(value, currencyCode: currencyCode, sign: .automatic)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Shimmering status line while the agent loop runs a tool.
public struct DSThinkingLine: View {
    private let text: String
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.ds.iris)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(text).dsFont(.mono).foregroundStyle(Color.ds.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
