import SwiftUI

/// 4pt base unit. The rhythm leans on 16 / 24 / 32 / 48.
public enum DSSpace {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
    public static let xxxl: CGFloat = 64
    /// Horizontal page gutter on phone.
    public static let gutter: CGFloat = 20
}

/// Soft rectangles: rounder than a spreadsheet, never pills. 30 only on chromatic tiles.
public enum DSRadius {
    public static let tag: CGFloat = 6
    /// Row glyphs, swatches, symbol cells.
    public static let glyph: CGFloat = 10
    /// Buttons and chips.
    public static let control: CGFloat = 12
    public static let field: CGFloat = 12
    /// A picker's selection ring around a `glyph`-radius swatch, 3pt out.
    public static let ring: CGFloat = 13
    public static let card: CGFloat = 20
    public static let tile: CGFloat = 30
    /// A filled icon tile's corner: a quarter of its side, so small and large tiles look alike.
    public static func iconTile(side: CGFloat) -> CGFloat { side * 0.26 }
}

/// Heights and hit targets. Visual sizes can be smaller than 44; the hit area never is.
public enum DSSize {
    public static let hitTarget: CGFloat = 44
    public static let listRow: CGFloat = 52
    public static let field: CGFloat = 48
    public static let buttonLarge: CGFloat = 52
    public static let buttonRegular: CGFloat = 44
    /// Drawn 32 tall inside a 44pt hit area.
    public static let buttonCompact: CGFloat = 32
    public static let chip: CGFloat = 36
    public static let segmented: CGFloat = 40
    public static let iconButton: CGFloat = 36
}

/// SF Symbol point sizes for glyphs that sit beside text without a text style of their own.
public enum DSIconSize {
    public static let xs: CGFloat = 12
    public static let sm: CGFloat = 14
    public static let md: CGFloat = 17
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 22
}

public enum DSMotion {
    public static let standard: Animation = .snappy(duration: 0.28)
    public static let gentle: Animation = .smooth(duration: 0.45)
    /// A button or chip going down under a finger.
    public static let press: Animation = .easeOut(duration: 0.12)
    /// A field's ring arriving.
    public static let focus: Animation = .easeOut(duration: 0.16)
    /// The AI edge while the model works. Callers hold it still under Reduce Motion.
    public static let breathe: Animation = .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
    /// Per item, with `gentle`, when a list of cards reveals.
    public static let revealStagger: Double = 0.05
}

/// Shadows belong to floating layers only (toasts, menus, the segmented thumb). Cards never
/// cast one: their depth is shade and the lit edge.
public enum DSShadow: Sendable {
    /// Toasts, menus, popovers: a soft drop plus a tight contact shadow.
    case overlay
    /// The segmented control's thumb.
    case thumb
}

extension View {
    /// The shadow of a floating layer. See `DSShadow`.
    @ViewBuilder
    public func dsShadow(_ shadow: DSShadow) -> some View {
        switch shadow {
        case .overlay:
            self.shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        case .thumb:
            self.shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
    }
}
