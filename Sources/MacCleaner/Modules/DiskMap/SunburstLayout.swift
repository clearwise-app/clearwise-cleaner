import SwiftUI
import CleanerKit
import SpaceEngine

struct ZoomOrigin: Equatable {
    var start: Double
    var end: Double
    var depth: Int
}

/// One annular sector. Angles are fractions of a full turn, clockwise from 12 o'clock.
struct SunSegment: Identifiable {
    let id: UUID
    let node: DirectoryNode?
    let name: String
    let size: Int64
    let depth: Int
    let start: Double
    let end: Double
    let color: Color
    let isAggregate: Bool
    var mid: Double { (start + end) / 2 }
}

enum SunburstLayout {
    static let rings = 4
    /// Segments thinner than this (fraction of a turn) are folded into "мелкие объекты".
    static let minSpan = 0.0045
    static let holeRatio = 0.3

    static func segments(focus: DirectoryNode, maxDepth: Int,
                         size: (DirectoryNode) -> Int64, isRemoved: (URL) -> Bool) -> [SunSegment] {
        var out: [SunSegment] = []
        let total = max(1, size(focus))

        func visit(_ node: DirectoryNode, depth: Int, start: Double, span: Double, branchHue: Double?) {
            guard depth <= maxDepth else { return }
            let nodeSize = max(1, size(node))
            let kids = node.children.filter { !isRemoved($0.url) }.map { ($0, size($0)) }.filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            var cursor = start
            var smallSize: Int64 = 0
            var rank = 0
            for (child, s) in kids {
                let childSpan = span * Double(s) / Double(nodeSize)
                // The engine's synthetic "Прочее" bucket carries the parent's URL: show it, never act on it.
                if childSpan < minSpan || SpaceMapper.isOtherBucket(child, in: node) {
                    smallSize += s
                    continue
                }
                // Top level: distinct hue per branch by rank. Deeper: same family, slight shift per sibling.
                let hue = branchHue.map { ($0 + Double(rank % 3 - 1) * 0.022 + 1).truncatingRemainder(dividingBy: 1) }
                    ?? palette[rank % palette.count]
                rank += 1
                out.append(SunSegment(id: child.id, node: child, name: child.name, size: s, depth: depth,
                                      start: cursor, end: cursor + childSpan,
                                      color: color(hue: hue, depth: depth, isDirectory: child.isDirectory),
                                      isAggregate: false))
                if child.isDirectory {
                    visit(child, depth: depth + 1, start: cursor, span: childSpan, branchHue: hue)
                }
                cursor += childSpan
            }
            let smallSpan = span * Double(smallSize) / Double(nodeSize)
            if smallSpan >= minSpan * 0.6 {
                out.append(SunSegment(id: aggregateID(parent: node.id, depth: depth), node: nil, name: SpaceMapper.otherName, size: smallSize, depth: depth,
                                      start: cursor, end: cursor + smallSpan,
                                      color: Color.white.opacity(0.16 - Double(depth) * 0.02), isAggregate: true))
            }
        }

        visit(focus, depth: 1, start: 0, span: Double(size(focus)) / Double(total), branchHue: nil)
        return out
    }

    /// Stable id of the «мелкие объекты» segment under `parent` at `depth`: the same layout pass after pass
    /// gives the same id, so hover and identity survive a re-run of the body.
    static func aggregateID(parent: UUID, depth: Int) -> UUID {
        var bytes = parent.uuid
        // Mix in the depth and a fixed salt so the id never equals the parent's own or a sibling's.
        bytes.0 ^= 0xA7
        bytes.15 ^= UInt8(truncatingIfNeeded: depth &* 31 &+ 0x5C)
        bytes.14 ^= UInt8(truncatingIfNeeded: depth)
        return UUID(uuid: bytes)
    }

    /// Branch hues, biggest branch first: pink, violet, blue, teal, green, amber, coral, indigo.
    static let palette: [Double] = [0.92, 0.77, 0.6, 0.5, 0.36, 0.11, 0.02, 0.68]

    static func color(hue: Double, depth: Int, isDirectory: Bool) -> Color {
        let d = Double(depth - 1)
        let sat = max(0.22, 0.72 - d * 0.13) * (isDirectory ? 1 : 0.8)
        let bri = min(1, 0.9 + d * 0.035)
        return Color(hue: hue, saturation: sat, brightness: bri)
    }

    // MARK: Geometry

    struct Geometry {
        let center: CGPoint
        let radius: CGFloat
        let rings: Int

        var hole: CGFloat { radius * holeRatio }
        var ringWidth: CGFloat { (radius - hole) / CGFloat(rings) }

        func inner(_ ring: Double) -> CGFloat { hole + CGFloat(ring - 1) * ringWidth }
        func outer(_ ring: Double) -> CGFloat { hole + CGFloat(ring) * ringWidth }

        /// Ring index (1-based, may be fractional during zoom) and angle fraction for a point.
        func hit(_ p: CGPoint) -> (ring: Int, angle: Double)? {
            let dx = p.x - center.x, dy = p.y - center.y
            let r = sqrt(dx * dx + dy * dy)
            guard r >= hole, r <= radius else { return nil }
            let ring = Int((r - hole) / ringWidth) + 1
            var a = atan2(dx, -dy) / (2 * .pi)
            if a < 0 { a += 1 }
            return (ring, a)
        }

        func isInHole(_ p: CGPoint) -> Bool {
            let dx = p.x - center.x, dy = p.y - center.y
            return sqrt(dx * dx + dy * dy) < hole
        }
    }

    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        var p = Path()
        let a0 = Angle(radians: start * 2 * .pi - .pi / 2)
        let a1 = Angle(radians: end * 2 * .pi - .pi / 2)
        p.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}
