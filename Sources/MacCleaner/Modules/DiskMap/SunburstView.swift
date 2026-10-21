import SwiftUI
import CleanerKit

/// DaisyDisk-style sunburst: rings = depth, hue = top-level branch, hover to inspect, click to zoom.
struct SunburstView: View {
    let model: DiskMapModel
    let segments: [SunSegment]

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let g = SunburstLayout.Geometry(center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                                            radius: side / 2 - 8, rings: SunburstLayout.rings)
            ZStack {
                // Soft glow behind the chart
                Circle()
                    .fill(RadialGradient(colors: [ModuleTint.diskMap.accent.opacity(0.28), .clear],
                                         center: .center, startRadius: g.hole, endRadius: g.radius * 1.15))
                    .frame(width: g.radius * 2.3, height: g.radius * 2.3)
                    .position(g.center)

                SunburstCanvas(segments: segments, geometry: g, hoveredID: model.hoveredID,
                               origin: model.zoomOrigin, progress: isSnapshot ? 1 : model.zoomProgress)

                CenterLabel(model: model, hovered: segments.first { $0.id == model.hoveredID })
                    .frame(width: g.hole * 2 - 18, height: g.hole * 2 - 18)
                    .position(g.center)
                    .allowsHitTesting(false)

                if model.zoomLoading {
                    ProgressView().controlSize(.small).position(x: g.center.x, y: g.center.y + g.hole * 0.62)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let id = segment(at: p, g)?.id
                    if id != model.hoveredID { model.hoveredID = id }
                case .ended:
                    model.hoveredID = nil
                }
            }
            .onTapGesture { p in
                if g.isInHole(p) {
                    model.zoomOut(to: model.stack.count - 2)
                } else if let seg = segment(at: p, g), let node = seg.node, node.isDirectory {
                    model.zoom(into: node, from: seg)
                }
            }
        }
    }

    private func segment(at p: CGPoint, _ g: SunburstLayout.Geometry) -> SunSegment? {
        guard let h = g.hit(p) else { return nil }
        return segments.first { $0.depth == h.ring && h.angle >= $0.start && h.angle < $0.end }
    }
}

private struct SunburstCanvas: View, Animatable {
    let segments: [SunSegment]
    let geometry: SunburstLayout.Geometry
    let hoveredID: UUID?
    let origin: ZoomOrigin?
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, _ in
            let g = geometry
            // Faint ring tracks
            for ring in 1...g.rings {
                let path = SunburstLayout.sector(center: g.center, inner: g.inner(Double(ring)), outer: g.outer(Double(ring)) - 2,
                                                 start: 0, end: 0.99999)
                ctx.fill(path, with: .color(.white.opacity(0.025)))
            }

            let hovered = segments.first { $0.id == hoveredID }
            let p = min(1, max(0, progress))

            for seg in segments {
                var start = seg.start, end = seg.end
                var ring = Double(seg.depth)
                if p < 1 {
                    if let o = origin {
                        let span = o.end - o.start
                        start = lerp(o.start + seg.start * span, seg.start, p)
                        end = lerp(o.start + seg.end * span, seg.end, p)
                        ring = Double(seg.depth) + Double(o.depth) * (1 - p)
                    } else {
                        start *= p
                        end *= p
                    }
                }
                let inner = g.inner(ring)
                let outer = g.outer(ring) - 2
                guard inner < g.radius + 1, end - start > 0.0005 else { continue }
                let path = SunburstLayout.sector(center: g.center, inner: inner, outer: min(outer, g.radius), start: start, end: end)

                var opacity = 1.0
                if let h = hovered {
                    let related = seg.id == h.id || (seg.depth > h.depth && seg.start >= h.start - 1e-9 && seg.end <= h.end + 1e-9)
                    opacity = related ? 1 : 0.5
                }
                ctx.fill(path, with: .color(seg.color))
                if opacity < 1 { ctx.fill(path, with: .color(Color(hex: 0x1A0A22).opacity(0.55))) }
                ctx.fill(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.14), .clear]),
                                                     startPoint: CGPoint(x: g.center.x, y: g.center.y - outer),
                                                     endPoint: CGPoint(x: g.center.x, y: g.center.y + outer)))
                ctx.stroke(path, with: .color(Color(hex: 0x14061A).opacity(0.55)), lineWidth: 1)
                if seg.id == hoveredID {
                    ctx.stroke(path, with: .color(.white.opacity(0.95)), lineWidth: 2)
                }
            }

            // Center disc
            let hole = Path(ellipseIn: CGRect(x: g.center.x - g.hole + 4, y: g.center.y - g.hole + 4,
                                              width: (g.hole - 4) * 2, height: (g.hole - 4) * 2))
            ctx.fill(hole, with: .radialGradient(Gradient(colors: [Color(hex: 0x2A1233), Color(hex: 0x16081C)]),
                                                 center: CGPoint(x: g.center.x, y: g.center.y - g.hole * 0.4),
                                                 startRadius: 0, endRadius: g.hole * 1.3))
            ctx.stroke(hole, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

private struct CenterLabel: View {
    let model: DiskMapModel
    let hovered: SunSegment?

    var body: some View {
        VStack(spacing: 3) {
            if let h = hovered {
                Image(systemName: h.isAggregate ? "square.grid.3x3.fill" : (h.node?.isDirectory == true ? "folder.fill" : "doc.fill"))
                    .font(.system(size: 14))
                    .foregroundStyle(h.color)
                Text(h.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                BigSize(bytes: h.size, size: 24, weight: .light)
                if let focus = model.focus {
                    Text("\(percent(h.size, of: model.size(of: focus))) от «\(model.stack.count == 1 ? model.location.title : focus.name)»")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            } else if let focus = model.focus {
                Text(model.stack.count == 1 ? model.location.title : focus.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                BigSize(bytes: model.size(of: focus), size: 28, weight: .light)
                if model.stack.count > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                        Text("Назад")
                    }
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                }
            }
        }
        .minimumScaleFactor(0.7)
    }

    private func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0 %" }
        let v = Double(part) / Double(total) * 100
        return v < 1 ? "<1 %" : "\(Int(v.rounded())) %"
    }
}
