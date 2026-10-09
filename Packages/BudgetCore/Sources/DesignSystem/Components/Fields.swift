import SwiftUI

/// A text field with its label above, its helper or error below, and the design system's well:
/// an engraved `canvasDeep` box with an opaque border (3:1 or better on every layer a field sits on),
/// a cyan ring and halo when focused, a caution ring when there's an error.
///
/// The label stays above the box rather than floating inside it, so it scales with Dynamic Type
/// and VoiceOver hears it in order. Pass any input — a `TextField`, a `SecureField` with a
/// `PasteButton`, a formatted amount field — and keep its own modifiers (keyboard, identifier)
/// on it; the field supplies the font, ink, caret tint and chrome.
///
/// Focus: by default the field tracks its own. When the screen already drives focus with its own
/// `.focused(_:equals:)` on the input, pass `isFocused:` instead, so the two never compete.
public struct DSField<Input: View>: View {
    public enum Style: Sendable {
        /// A standalone form field: the well and its border.
        case boxed
        /// A row of a `DSListSection`: no well, the row is the field. Focus is a cyan leading bar.
        case inline
        /// Boxed, with a leading magnifying glass. On a whole screen prefer the system `.searchable`.
        case search
    }

    private let label: String?
    private let style: Style
    private let isCode: Bool
    private let helper: String?
    private let error: String?
    private let counter: String?
    private let prefix: String?
    private let suffix: String?
    private let isEmpty: Bool
    private let isReadOnly: Bool
    private let externalFocus: Bool?
    private let onClear: (() -> Void)?
    private let input: Input
    @FocusState private var ownFocus: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var boxHeight: CGFloat = DSSize.field

    /// - Parameters:
    ///   - label: shown above the box (or above the value, inline); nil for none.
    ///   - isCode: the `code` voice — monospace, no autocapitalization or autocorrection — for tokens, URLs and keys.
    ///   - helper: one line under the field; replaced by `error` when there is one.
    ///   - counter: trailing the label, e.g. "12 / 40".
    ///   - prefix, suffix: "$", "%", "/mo" — quieter while the field is empty (`isEmpty`).
    ///   - isReadOnly: shown, not edited: no well, a lock glyph.
    ///   - isFocused: the screen's own focus for this field, when it manages focus itself.
    ///   - onClear: shows a clear button while focused and not empty.
    public init(_ label: String?, style: Style = .boxed, isCode: Bool = false, helper: String? = nil, error: String? = nil,
                counter: String? = nil, prefix: String? = nil, suffix: String? = nil, isEmpty: Bool = false, isReadOnly: Bool = false,
                isFocused: Bool? = nil, onClear: (() -> Void)? = nil, @ViewBuilder input: () -> Input) {
        self.label = label
        self.style = style
        self.isCode = isCode
        self.helper = helper
        self.error = error
        self.counter = counter
        self.prefix = prefix
        self.suffix = suffix
        self.isEmpty = isEmpty
        self.isReadOnly = isReadOnly
        self.externalFocus = isFocused
        self.onClear = onClear
        self.input = input()
    }

    private var isFocused: Bool { externalFocus ?? ownFocus }
    private var hasError: Bool { error != nil }
    private var isBoxed: Bool { style != .inline }

    public var body: some View {
        VStack(alignment: .leading, spacing: isBoxed ? DSSpace.xs : 2) {
            if label != nil || counter != nil { labelRow }
            if isBoxed { box } else { content }
            message
        }
        .padding(.vertical, isBoxed ? 0 : DSSpace.xs)
        .frame(minHeight: isBoxed ? nil : DSSize.listRow, alignment: .leading)
        .overlay(alignment: .leading) {
            // Inline focus and error: a bar out in the row's 16pt leading inset. It sits mid-inset and
            // clear of the top and bottom, so a rounded row's corners (a one-row Form section is
            // nearly a capsule) can't clip it to a sliver.
            if !isBoxed, isFocused || hasError {
                Capsule()
                    .fill(hasError ? Color.ds.caution : Color.ds.accent)
                    .frame(width: DSState.selectionBarWidth)
                    .padding(.vertical, DSSpace.sm)
                    .offset(x: -DSSpace.md / 2 - 1)
                    .accessibilityHidden(true)
            }
        }
        .animation(DSMotion.focus, value: isFocused)
        .animation(DSMotion.focus, value: hasError)
    }

    private var labelRow: some View {
        HStack(alignment: .firstTextBaseline) {
            if let label {
                Text(label)
                    .dsFont(.label)
                    // Brightens with focus, and stays bright on an error, so colour is never the only signal.
                    .foregroundStyle(!isEnabled ? Color.ds.inkDisabled : (isFocused || hasError) ? Color.ds.ink : Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The input says its own name; the visible label would make VoiceOver say it twice.
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DSSpace.xs)
            if let counter {
                Text(counter).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary).monospacedDigit()
            }
        }
    }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.field, style: .continuous)
        return content
            .padding(.horizontal, 14)
            .frame(minHeight: boxHeight)
            .background {
                if isEnabled && !isReadOnly {
                    // The well, engraved: a dark fill with a soft shadow along its inner top edge.
                    shape.fill(Color.ds.canvasDeep.shadow(.inner(color: .black.opacity(0.45), radius: 1, y: 1)))
                }
            }
            .overlay { shape.strokeBorder(borderColor, lineWidth: isFocused || hasError ? DSState.focusRingWidth : 1) }
            .overlay {
                if isFocused && !hasError && isEnabled {
                    RoundedRectangle(cornerRadius: DSRadius.field + DSState.focusHaloWidth, style: .continuous)
                        .strokeBorder(DSState.focusHalo, lineWidth: DSState.focusHaloWidth)
                        .padding(-DSState.focusHaloWidth)
                        .allowsHitTesting(false)
                }
            }
    }

    private var borderColor: Color {
        if !isEnabled { return Color.ds.hairline }
        if isReadOnly { return Color.ds.divider }
        if hasError { return Color.ds.caution }
        return isFocused ? Color.ds.accent : Color.ds.fieldBorder
    }

    private var valueInk: Color {
        if !isEnabled { return Color.ds.inkDisabled }
        return isReadOnly ? Color.ds.inkSecondary : Color.ds.ink
    }

    private var content: some View {
        HStack(spacing: 6) {
            if style == .search {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ds.inkTertiary)
                    .accessibilityHidden(true)
            }
            if let prefix { affix(prefix) }
            focusable
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsFont(isCode ? .code : .body)
                .foregroundStyle(valueInk)
                .tint(Color.ds.accent)
                .modifier(CodeInput(isOn: isCode))
                .accessibilityHint(error.map { "Error: \($0)" } ?? "")
            if let suffix { affix(suffix) }
            if let onClear, isFocused, !isEmpty, isEnabled, !isReadOnly {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.ds.inkTertiary)
                        .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -14)
                .accessibilityLabel("Clear")
            }
            if hasError {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ds.caution)
                    .accessibilityHidden(true)
            } else if isReadOnly {
                Image(systemName: "lock")
                    .font(.system(size: DSIconSize.sm, weight: .medium))
                    .foregroundStyle(Color.ds.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var focusable: some View {
        if externalFocus == nil {
            input.focused($ownFocus)
        } else {
            input
        }
    }

    private func affix(_ text: String) -> some View {
        Text(text)
            .dsFont(.body)
            .foregroundStyle(!isEnabled ? Color.ds.inkDisabled : isEmpty ? Color.ds.inkTertiary : Color.ds.inkSecondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var message: some View {
        if let error {
            Text(error)
                .dsFont(.caption)
                .foregroundStyle(Color.ds.caution)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isBoxed ? -2 : 0)
        } else if let helper {
            Text(helper)
                .dsFont(.caption)
                .foregroundStyle(Color.ds.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isBoxed ? -2 : 0)
        }
    }
}

extension DSField where Input == TextField<Text> {
    /// A plain text field: `DSField("Name", text: $name, prompt: "Pets, Gifts, Kids…")`. Clears with
    /// the trailing button while focused.
    /// With no label (a search field), VoiceOver names the field by its prompt.
    public init(_ label: String?, text: Binding<String>, prompt: String? = nil, style: Style = .boxed, isCode: Bool = false,
                helper: String? = nil, error: String? = nil, prefix: String? = nil, suffix: String? = nil) {
        self.init(label, style: style, isCode: isCode, helper: helper, error: error, prefix: prefix, suffix: suffix,
                  isEmpty: text.wrappedValue.isEmpty, onClear: { text.wrappedValue = "" }) {
            TextField(label ?? prompt ?? "", text: text, prompt: prompt.map { Text($0) })
        }
    }
}

/// The `code` voice's input behaviour: no capitals, no autocorrection.
private struct CodeInput: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            content
        }
    }
}

/// A big amount entry: no box, the amount in the serif, with a superior "$" and an underline
/// that turns cyan while focused and caution on an error. Pass the `TextField` (with its keyboard
/// and identifier); this supplies the voice. Centred for a lone price; leading under a sheet title.
public struct DSAmountField<Input: View>: View {
    private let currencySymbol: String?
    private let style: DSTextStyle
    private let alignment: HorizontalAlignment
    private let isEmpty: Bool
    private let externalFocus: Bool?
    private let error: String?
    private let input: Input
    @FocusState private var ownFocus: Bool
    @ScaledMetric private var size: CGFloat

    /// - Parameters:
    ///   - currencySymbol: drawn superior before the amount; nil when the input formats its own currency.
    ///   - style: `amountXL` for a hero entry, `amount` inside a card.
    ///   - isFocused: the screen's own focus, when it applies `.focused` to the input itself.
    public init(currencySymbol: String? = "$", style: DSTextStyle = .amountXL, alignment: HorizontalAlignment = .center,
                isEmpty: Bool = false, isFocused: Bool? = nil, error: String? = nil, @ViewBuilder input: () -> Input) {
        self.currencySymbol = currencySymbol
        self.style = style
        self.alignment = alignment
        self.isEmpty = isEmpty
        self.externalFocus = isFocused
        self.error = error
        self.input = input()
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTextStyle)
    }

    private var isFocused: Bool { externalFocus ?? ownFocus }

    private var symbolInk: Color {
        if error != nil { return Color.ds.caution }
        return isEmpty ? Color.ds.inkTertiary : Color.ds.inkSecondary
    }

    private var underline: Color {
        if error != nil { return Color.ds.caution }
        return isFocused ? Color.ds.accent : Color.white.opacity(0.24)
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: DSSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let currencySymbol {
                    // Superior: a smaller "$" lifted toward the cap height, as a price is set in print.
                    Text(currencySymbol)
                        .font(.system(size: size * 0.6, weight: .light, design: .serif))
                        .baselineOffset(size * 0.3)
                        .foregroundStyle(symbolInk)
                        .accessibilityHidden(true)
                }
                focusable
                    .dsFont(style)
                    .foregroundStyle(Color.ds.ink)
                    .tint(Color.ds.accent)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    // Centred, the field hugs its digits so the "$" stays beside them.
                    .fixedSize(horizontal: alignment == .center, vertical: false)
                    .accessibilityHint(error.map { "Error: \($0)" } ?? "")
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            Rectangle()
                .fill(underline)
                .frame(height: isFocused || error != nil ? DSState.focusRingWidth : 1)
                .accessibilityHidden(true)
            if let error {
                Text(error).dsFont(.caption).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(DSMotion.focus, value: isFocused)
    }

    @ViewBuilder
    private var focusable: some View {
        if externalFocus == nil {
            input.focused($ownFocus)
        } else {
            input
        }
    }
}

/// A segmented choice: a recessed track with a lit charcoal key that slides to the selection
/// (never a white thumb — white means "the one primary action"). At accessibility text sizes it
/// becomes a menu, where segment labels would otherwise have to shrink.
public struct DSSegmented<Value: Hashable>: View {
    private let label: String
    @Binding private var selection: Value
    private let options: [(value: Value, title: String)]
    @Namespace private var thumb
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter label: what VoiceOver calls the control, and the menu's title at accessibility sizes.
    public init(_ label: String, selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    /// One segment per value, titled by `title`: `DSSegmented("Paid", selection: $type, options: PayType.allCases) { $0.label }`.
    public init(_ label: String, selection: Binding<Value>, options: [Value], title: (Value) -> String) {
        self.init(label, selection: selection, options: options.map { (value: $0, title: title($0)) })
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
            }
            .pickerStyle(.menu)
            .tint(Color.ds.ink)
        } else {
            segments
        }
    }

    private var segments: some View {
        let track = RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
        return HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(.horizontal, 3)
        .background {
            // The track is 40 tall inside the 44pt row, so every segment's hit area is the full row.
            track.fill(Color.ds.canvasDeep)
                .overlay { track.strokeBorder(Color.white.opacity(0.06), lineWidth: 1) }
                .padding(.vertical, (DSSize.hitTarget - DSSize.segmented) / 2)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ option: (value: Value, title: String)) -> some View {
        let isSelected = option.value == selection
        let key = RoundedRectangle(cornerRadius: DSRadius.control - 3, style: .continuous)
        return Button {
            withAnimation(DSMotion.standard) { selection = option.value }
        } label: {
            Text(option.title)
                .dsFont(.label)
                .foregroundStyle(!isEnabled ? Color.ds.inkDisabled : isSelected ? Color.ds.ink : Color.ds.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DSSpace.xs)
                .frame(maxWidth: .infinity, minHeight: DSSize.hitTarget)
                .background {
                    if isSelected {
                        key.fill(Color.ds.surfaceOverlay)
                            .dsLitEdge(radius: DSRadius.control - 3, strength: .strong)
                            .dsShadow(.thumb)
                            .padding(.vertical, (DSSize.hitTarget - DSSize.segmented) / 2 + 3)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
