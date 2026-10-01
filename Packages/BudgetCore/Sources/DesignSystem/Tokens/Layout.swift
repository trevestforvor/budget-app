import SwiftUI

/// 4pt base unit. Origin's rhythm leans on 16 / 24 / 32 / 48.
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

/// Rectangular discipline: small radii on controls, 16 on cards, 30 only on chromatic tiles.
public enum DSRadius {
    public static let tag: CGFloat = 4
    public static let control: CGFloat = 8
    public static let card: CGFloat = 16
    public static let tile: CGFloat = 30
}

public enum DSMotion {
    public static let standard: Animation = .snappy(duration: 0.28)
    public static let gentle: Animation = .smooth(duration: 0.45)
}
