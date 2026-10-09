import SwiftUI

// One light source: it sits above and in front of the screen, like the glow in the icon. Panels
// are lit along their top edge and are a touch brighter at the top; depth comes from shade and
// light, never from drop shadows on cards. Every recipe here is static; the only motion is the
// AI edge breathing while the model works, and it holds still under Reduce Motion.

/// How bright a panel's lit top edge is (G1).
public enum DSLitEdge: Sendable {
    /// Cards, toasts, list sections, the ask field.
    case standard
    /// Small raised keys: the segmented thumb, secondary and icon buttons.
    case strong

    var stops: [Gradient.Stop] {
        switch self {
        case .standard:
            [.init(color: .white.opacity(0.12), location: 0), .init(color: .white.opacity(0.05), location: 0.5),
             .init(color: .white.opacity(0.04), location: 1)]
        case .strong:
            [.init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0.06), location: 0.5),
             .init(color: .white.opacity(0.04), location: 1)]
        }
    }

    var gradient: LinearGradient { LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom) }
}

/// The panel fills (G2): each surface is drawn as a gradient from its lit top stop.
public enum DSFill {
    /// `surface`, from `carbonLit` at the top.
    public static var surface: LinearGradient {
        LinearGradient(colors: [Palette.carbonLit.color, Palette.carbon.color], startPoint: .top, endPoint: .bottom)
    }

    /// `surfaceRaised`, from `graphiteLit` at the top.
    public static var raised: LinearGradient {
        LinearGradient(colors: [Palette.graphiteLit.color, Palette.graphite.color], startPoint: .top, endPoint: .bottom)
    }

    /// The primary button (G6): white settling to pearl. Pressed is flat `pearlPressed`.
    public static var pearl: LinearGradient {
        LinearGradient(colors: [Palette.pure.color, Palette.pearl.color], startPoint: .top, endPoint: .bottom)
    }
}

/// How high a panel sits. Flat and raised take the lit fills; the overlay is a flat, brighter layer
/// for things that float (and cast `DSShadow.overlay`).
public enum DSElevation: Sendable {
    case flat, raised, overlay
}

/// Coloured light on a panel, under its content. Text on any of these stays `inkSecondary` or brighter.
public enum DSCardWash: Sendable, Equatable {
    /// A tone's bloom from the top-leading corner (G3, 18%), like light on a gallery wall.
    case tone(DSTone)
    /// The same bloom in any colour, at a chosen strength (notices use 14%, toasts 12%).
    case tint(Color, intensity: Double)
    /// Caution washing down from the top edge (G4). Always pair it with `DSTag.over()` or words.
    case caution
    /// Iris rising from the bottom-trailing corner, as in the icon (G8): a proposal from the assistant.
    case ai
}

/// A panel's fill and wash, clipped to its shape. `.dsPanel(_:wash:)` adds the lit edge; use this
/// directly only when a component draws its own edge (the AI edge).
public struct DSPanelBackground: View {
    private let elevation: DSElevation
    private let wash: DSCardWash?
    private let radius: CGFloat

    public init(_ elevation: DSElevation = .flat, wash: DSCardWash? = nil, radius: CGFloat = DSRadius.card) {
        self.elevation = elevation
        self.wash = wash
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            switch elevation {
            case .flat: shape.fill(DSFill.surface)
            case .raised: shape.fill(DSFill.raised)
            case .overlay: shape.fill(Color.ds.surfaceOverlay)
            }
            washLayer
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var washLayer: some View {
        switch wash {
        case let .tone(tone):
            Self.bloom(tone.fill, intensity: DSWash.bloom.opacity)
        case let .tint(color, intensity):
            Self.bloom(color, intensity: intensity)
        case .caution:
            LinearGradient(stops: [.init(color: Color.ds.caution.opacity(0.18), location: 0), .init(color: .clear, location: 0.55)],
                           startPoint: .top, endPoint: .bottom)
        case .ai:
            RadialGradient(colors: [Color.ds.iris.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 280)
        case nil:
            EmptyView()
        }
    }

    static func bloom(_ color: Color, intensity: Double) -> RadialGradient {
        RadialGradient(colors: [color.opacity(intensity), color.opacity(0)], center: UnitPoint(x: 0.12, y: 0), startRadius: 0, endRadius: 260)
    }
}

/// A screen's one bloom of colour behind its top edge (G5): cyan where the screen is about data,
/// iris on Ask. One per screen.
public enum DSScreenBloom: Sendable {
    case data, ai

    public var color: Color { self == .data ? Color.ds.accent : Color.ds.iris }
    public var intensity: Double { self == .data ? 0.10 : 0.14 }
}

private struct DSScreenBloomLayer: View {
    let bloom: DSScreenBloom

    var body: some View {
        RadialGradient(colors: [bloom.color.opacity(bloom.intensity), .clear], center: UnitPoint(x: 0.5, y: -0.1),
                       startRadius: 0, endRadius: 360)
            .frame(maxWidth: .infinity)
            .frame(height: 480)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The lit top edge (G1): a 1pt border that is brightest along the top.
    public func dsLitEdge(radius: CGFloat, strength: DSLitEdge = .standard) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(strength.gradient, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// A panel behind this view: the lit fill for `elevation`, an optional wash, and the lit edge.
    public func dsPanel(_ elevation: DSElevation = .flat, wash: DSCardWash? = nil, radius: CGFloat = DSRadius.card) -> some View {
        background { DSPanelBackground(elevation, wash: wash, radius: radius) }
            .dsLitEdge(radius: radius)
    }

    /// Full-bleed canvas with a screen bloom over its top (G5).
    public func dsScreenBackground(bloom: DSScreenBloom) -> some View {
        background {
            ZStack(alignment: .top) {
                Color.ds.canvas.ignoresSafeArea()
                DSScreenBloomLayer(bloom: bloom)
            }
        }
    }

    /// Only the bloom, for a screen whose canvas is drawn by something else (a grouped list).
    /// Apply it outside that background so it lands on top of the canvas.
    public func dsScreenBloom(_ bloom: DSScreenBloom) -> some View {
        overlay(alignment: .top) { DSScreenBloomLayer(bloom: bloom) }
    }

    /// The assistant's edge (G7): iris to violet to lilac, never cyan. Static; while `isWorking`
    /// it breathes between 55% and full, and holds at full under Reduce Motion.
    public func dsAIEdge<S: InsettableShape>(_ shape: S, isWorking: Bool = false, lineWidth: CGFloat = 1) -> some View {
        modifier(DSAIEdge(shape: shape, isWorking: isWorking, lineWidth: lineWidth))
    }

    /// `dsAIEdge` on a rounded rectangle.
    public func dsAIEdge(radius: CGFloat, isWorking: Bool = false) -> some View {
        dsAIEdge(RoundedRectangle(cornerRadius: radius, style: .continuous), isWorking: isWorking)
    }
}

/// The AI edge's gradient: the violet family only, so it never reads as cyan data.
enum DSAIGradient {
    static var edge: LinearGradient {
        LinearGradient(stops: [.init(color: Color.ds.iris.opacity(0.9), location: 0),
                               .init(color: Color.ds.violet.opacity(0.35), location: 0.5),
                               .init(color: Color.ds.lilac.opacity(0.7), location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct DSAIEdge<S: InsettableShape>: ViewModifier {
    let shape: S
    let isWorking: Bool
    let lineWidth: CGFloat
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(DSAIGradient.edge, lineWidth: lineWidth)
                    .opacity(dimmed ? 0.55 : 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: isWorking && !reduceMotion, initial: true) { _, breathes in
                if breathes {
                    withAnimation(DSMotion.breathe) { dimmed = true }
                } else {
                    withAnimation(DSMotion.standard) { dimmed = false }
                }
            }
    }
}

/// A chromatic tile's fill with its gloss (G9): the tone, brightened toward the top by white and
/// a fading inner stroke. The gloss only ever brightens, so the tile's ink only gains contrast
/// (irisDeep, which carries white ink, caps at 10%; see `DSTone.gloss`).
public struct DSTileFill: View {
    private let tone: DSTone
    private let radius: CGFloat

    public init(tone: DSTone, radius: CGFloat = DSRadius.tile) {
        self.tone = tone
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = 0.22 * tone.gloss / 0.14
        ZStack {
            shape.fill(tone.fill)
            LinearGradient(colors: [.white.opacity(tone.gloss), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(edge), location: 0), .init(color: .white.opacity(0), location: 0.3)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
