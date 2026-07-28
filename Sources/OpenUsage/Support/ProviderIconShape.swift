import SwiftUI

/// A provider's copied vector mark, keyed by provider id.
struct IconSource: Hashable {
    let providerID: String

    /// Named constructor retained at call sites so the stored string's meaning stays explicit.
    static func providerMark(_ providerID: String) -> IconSource {
        IconSource(providerID: providerID)
    }
}

/// Renders an `IconSource` in monochrome (`Theme.iconGray`): on the glass popover, icon color
/// reads as noise (WWDC25 — monochrome reduces it), and provider identity comes from the name
/// beside the mark.
struct ProviderIcon: View {
    let source: IconSource
    /// Margin kept around a vector provider mark, forwarded to `ProviderIconShape`. Defaults to the
    /// breathing-room value used in list contexts (e.g. Settings); callers that want the mark to
    /// fill its box — like the section header matching the menu-bar strip glyph — pass a smaller value.
    var inset: CGFloat = 0.14

    var body: some View {
        if let mark = ProviderMarks.mark(for: source.providerID) {
            ProviderIconShape(mark: mark, inset: inset)
                .fill(Theme.iconGray)
        } else {
            Image(systemName: ProviderMarks.symbolFallback(for: source.providerID))
                .foregroundStyle(Theme.iconGray)
        }
    }
}

/// A SwiftUI `Shape` built from an SVG path `d` string, scaled to fit the frame and centered.
///
/// It normalizes by the artwork's **true bounding box** (not the declared `viewBox`): some source SVGs
/// bake whitespace into their viewBox (Claude/Codex/Cursor sit ~10% inside a 100×100 box) while others
/// run edge-to-edge (Devin, Grok). Fitting the real path bounds gives every provider mark the same
/// optical weight, then a single shared `inset` adds consistent breathing room so none touch the edge.
struct ProviderIconShape: Shape {
    let mark: ProviderMark
    /// Fraction of the frame kept as margin on every side, so normalized marks have uniform padding.
    var inset: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        guard mark.bounds.width > 0, mark.bounds.height > 0 else { return mark.path }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(target.width / mark.bounds.width, target.height / mark.bounds.height)
        let dx = target.midX - mark.bounds.midX * scale
        let dy = target.midY - mark.bounds.midY * scale
        return mark.path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// A provider vector mark parsed once when its resource is loaded. `ProviderIconShape` only applies
/// the inexpensive frame transform on subsequent renders.
struct ProviderMark: Hashable {
    let pathData: String
    let path: Path
    let bounds: CGRect

    init(pathData: String) {
        self.pathData = pathData
        let path = SVGPath.parse(pathData)
        self.path = path
        bounds = path.cgPath.boundingBoxOfPath
    }

    static func == (lhs: ProviderMark, rhs: ProviderMark) -> Bool {
        lhs.pathData == rhs.pathData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pathData)
    }
}

/// Loads copied provider SVGs from the bundle and extracts their path data (cached).
@MainActor
enum ProviderMarks {
    private static var cache: [String: ProviderMark] = [:]
    private static var missing: Set<String> = []

    static func mark(for id: String) -> ProviderMark? {
        if let cached = cache[id] { return cached }
        if missing.contains(id) { return nil }
        guard
            let url = Bundle.openUsageResources.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            let d = extractD(text)
        else {
            missing.insert(id)
            return nil
        }
        let mark = ProviderMark(pathData: d)
        cache[id] = mark
        return mark
    }

    static func symbolFallback(for id: String) -> String {
        switch id {
        case "antigravity": return "paperplane"
        case "claude": return "sparkle"
        case "codex": return "circle.hexagongrid"
        case "cursor": return "cube"
        case "grok": return "bolt.fill"
        case "kimi": return "moon.stars"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "openrouter": return "point.3.connected.trianglepath.dotted"
        case "sakana": return "fish.fill"
        case "zai": return "z.signal"
        default: return "app.dashed"
        }
    }

    private static func extractD(_ svg: String) -> String? {
        var values: [String] = []
        var searchStart = svg.startIndex
        while let start = svg[searchStart...].range(of: "d=\"") {
            let rest = svg[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            values.append(String(rest[..<end]))
            searchStart = end
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
}

/// Minimal SVG path parser supporting M/L/H/V/C/S/Q/T/A/Z (absolute + relative, implicit repeats).
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var prevWasCubic = false
        var prevWasQuad = false

        func skipSeparators() {
            while i < n {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < n {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." && !sawDot {
                    sawDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        func reflected() -> CGPoint {
            guard let lc = lastControl else { return current }
            return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
        }

        /// SVG endpoint-parameterized elliptical arc converted to cubic Bézier segments. Splitting
        /// at quarter turns keeps the approximation visually exact at provider-icon scale.
        func addArc(
            to end: CGPoint,
            radiusX rawRadiusX: CGFloat,
            radiusY rawRadiusY: CGFloat,
            rotationDegrees: CGFloat,
            largeArc: Bool,
            sweep: Bool
        ) {
            var radiusX = abs(rawRadiusX)
            var radiusY = abs(rawRadiusY)
            guard current != end else { return }
            guard radiusX > 0, radiusY > 0 else {
                path.addLine(to: end)
                return
            }

            let rotation = rotationDegrees * .pi / 180
            let cosRotation = cos(rotation)
            let sinRotation = sin(rotation)
            let halfDX = (current.x - end.x) / 2
            let halfDY = (current.y - end.y) / 2
            let transformedX = cosRotation * halfDX + sinRotation * halfDY
            let transformedY = -sinRotation * halfDX + cosRotation * halfDY

            let radiiScale = transformedX * transformedX / (radiusX * radiusX)
                + transformedY * transformedY / (radiusY * radiusY)
            if radiiScale > 1 {
                let factor = sqrt(radiiScale)
                radiusX *= factor
                radiusY *= factor
            }

            let radiusXSquared = radiusX * radiusX
            let radiusYSquared = radiusY * radiusY
            let transformedXSquared = transformedX * transformedX
            let transformedYSquared = transformedY * transformedY
            let numerator = max(
                0,
                radiusXSquared * radiusYSquared
                    - radiusXSquared * transformedYSquared
                    - radiusYSquared * transformedXSquared
            )
            let denominator = radiusXSquared * transformedYSquared
                + radiusYSquared * transformedXSquared
            let sign: CGFloat = largeArc == sweep ? -1 : 1
            let factor = denominator > 0 ? sign * sqrt(numerator / denominator) : 0
            let centerTransformedX = factor * radiusX * transformedY / radiusY
            let centerTransformedY = factor * -radiusY * transformedX / radiusX
            let center = CGPoint(
                x: cosRotation * centerTransformedX - sinRotation * centerTransformedY
                    + (current.x + end.x) / 2,
                y: sinRotation * centerTransformedX + cosRotation * centerTransformedY
                    + (current.y + end.y) / 2
            )

            let startVector = CGPoint(
                x: (transformedX - centerTransformedX) / radiusX,
                y: (transformedY - centerTransformedY) / radiusY
            )
            let endVector = CGPoint(
                x: (-transformedX - centerTransformedX) / radiusX,
                y: (-transformedY - centerTransformedY) / radiusY
            )
            var startAngle = atan2(startVector.y, startVector.x)
            var deltaAngle = atan2(
                startVector.x * endVector.y - startVector.y * endVector.x,
                startVector.x * endVector.x + startVector.y * endVector.y
            )
            if !sweep, deltaAngle > 0 { deltaAngle -= 2 * .pi }
            if sweep, deltaAngle < 0 { deltaAngle += 2 * .pi }

            let segmentCount = max(1, Int(ceil(abs(deltaAngle) / (.pi / 2))))
            let segmentAngle = deltaAngle / CGFloat(segmentCount)
            for _ in 0..<segmentCount {
                let endAngle = startAngle + segmentAngle
                let alpha = 4 / 3 * tan(segmentAngle / 4)

                func point(at angle: CGFloat) -> CGPoint {
                    CGPoint(
                        x: center.x + cosRotation * radiusX * cos(angle)
                            - sinRotation * radiusY * sin(angle),
                        y: center.y + sinRotation * radiusX * cos(angle)
                            + cosRotation * radiusY * sin(angle)
                    )
                }
                func derivative(at angle: CGFloat) -> CGPoint {
                    CGPoint(
                        x: -cosRotation * radiusX * sin(angle)
                            - sinRotation * radiusY * cos(angle),
                        y: -sinRotation * radiusX * sin(angle)
                            + cosRotation * radiusY * cos(angle)
                    )
                }

                let start = point(at: startAngle)
                let segmentEnd = point(at: endAngle)
                let startDerivative = derivative(at: startAngle)
                let endDerivative = derivative(at: endAngle)
                path.addCurve(
                    to: segmentEnd,
                    control1: CGPoint(
                        x: start.x + alpha * startDerivative.x,
                        y: start.y + alpha * startDerivative.y
                    ),
                    control2: CGPoint(
                        x: segmentEnd.x - alpha * endDerivative.x,
                        y: segmentEnd.y - alpha * endDerivative.y
                    )
                )
                startAngle = endAngle
            }
        }

        while i < n {
            skipSeparators()
            if i >= n { break }

            if chars[i].isLetter {
                lastCommand = chars[i]
                i += 1
            }

            let cmd = lastCommand
            var failed = false
            var isCubic = false
            var isQuad = false

            switch cmd {
            case "M", "m":
                if let p = readPoint(relative: cmd == "m") {
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    lastCommand = (cmd == "m") ? "l" : "L"
                } else { failed = true }

            case "L", "l":
                if let p = readPoint(relative: cmd == "l") {
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "H", "h":
                if let x = readNumber() {
                    let nx = (cmd == "h") ? current.x + x : x
                    let p = CGPoint(x: nx, y: current.y)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "V", "v":
                if let y = readNumber() {
                    let ny = (cmd == "v") ? current.y + y : y
                    let p = CGPoint(x: current.x, y: ny)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "C", "c":
                if let c1 = readPoint(relative: cmd == "c"),
                   let c2 = readPoint(relative: cmd == "c"),
                   let end = readPoint(relative: cmd == "c") {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "S", "s":
                if let c2 = readPoint(relative: cmd == "s"),
                   let end = readPoint(relative: cmd == "s") {
                    let c1 = prevWasCubic ? reflected() : current
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "Q", "q":
                if let c = readPoint(relative: cmd == "q"),
                   let end = readPoint(relative: cmd == "q") {
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "T", "t":
                if let end = readPoint(relative: cmd == "t") {
                    let c = prevWasQuad ? reflected() : current
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "A", "a":
                if let radiusX = readNumber(),
                   let radiusY = readNumber(),
                   let rotation = readNumber(),
                   let largeArcFlag = readNumber(),
                   let sweepFlag = readNumber(),
                   let end = readPoint(relative: cmd == "a"),
                   (largeArcFlag == 0 || largeArcFlag == 1),
                   (sweepFlag == 0 || sweepFlag == 1) {
                    addArc(
                        to: end,
                        radiusX: radiusX,
                        radiusY: radiusY,
                        rotationDegrees: rotation,
                        largeArc: largeArcFlag == 1,
                        sweep: sweepFlag == 1
                    )
                    current = end
                } else { failed = true }

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                failed = true
            }

            if failed { break }
            prevWasCubic = isCubic
            prevWasQuad = isQuad
        }

        return path
    }
}
