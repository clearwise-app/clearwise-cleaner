import SwiftUI

/// Slowly drifting dark mesh gradient with a vignette — each module has its own tint.
struct ModuleBackground: View {
    let tint: ModuleTint
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        MeshGradient(width: 3, height: 3, points: drift ? Self.pointsB : Self.pointsA, colors: tint.mesh, smoothsColors: true)
            .overlay(Vignette())
            .ignoresSafeArea()
            .onAppear {
                guard !isSnapshot, !reduceMotion else { return }
                // One long, slow round trip; animated by SwiftUI without rebuilding the view tree each frame.
                withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
            }
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
    var body: some View {
        ZStack {
            RadialGradient(colors: [.clear, .black.opacity(0.42)],
                           center: .init(x: 0.55, y: 0.45), startRadius: 200, endRadius: 900)
            LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
