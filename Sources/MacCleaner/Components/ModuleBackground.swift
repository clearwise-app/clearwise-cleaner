import SwiftUI

/// Slowly drifting dark mesh gradient with a vignette — each module has its own tint.
///
/// The drift is computed from time inside a 20 fps `TimelineView` instead of a `repeatForever`
/// animation, so it costs a few cheap redraws per second and stops completely when
/// `animationsPaused` (window inactive, cleaning overlay up), in snapshots and under Reduce Motion.
/// Reduce Transparency darkens it a little more, matching the opaque glass cards.
struct ModuleBackground: View {
    let tint: ModuleTint
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.animationsPaused) private var animationsPaused

    /// One full A → B → A round trip.
    private static let period: TimeInterval = 32

    var body: some View {
        let still = isSnapshot || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still || animationsPaused)) { context in
            MeshGradient(width: 3, height: 3,
                         points: Self.points(at: still ? 0 : Self.phase(context.date)),
                         colors: tint.mesh, smoothsColors: true)
        }
        .overlay(Vignette(strong: reduceTransparency))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// 0 → 1 → 0 over `period`, eased at both ends like the old easeInOut round trip.
    private static func phase(_ date: Date) -> Float {
        let x = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return Float((1 - cos(x * 2 * .pi)) / 2)
    }

    private static func points(at t: Float) -> [SIMD2<Float>] {
        zip(pointsA, pointsB).map { a, b in a + (b - a) * t }
    }

    private static let pointsA: [SIMD2<Float>] = [
        [0, 0], [0.42, 0], [1, 0],
        [0, 0.58], [0.45, 0.38], [1, 0.42],
        [0, 1], [0.6, 1], [1, 1],
    ]
    private static let pointsB: [SIMD2<Float>] = [
        [0, 0], [0.62, 0], [1, 0],
        [0, 0.4], [0.66, 0.56], [1, 0.62],
        [0, 1], [0.38, 1], [1, 1],
    ]
}

private struct Vignette: View {
    var strong = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [.clear, .black.opacity(0.42)],
                           center: .init(x: 0.55, y: 0.45), startRadius: 200, endRadius: 900)
            LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
            if strong { Color.black.opacity(0.25) }
        }
        .allowsHitTesting(false)
    }
}
