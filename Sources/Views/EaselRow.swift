// ABOUTME: A row of studio easels, each holding a terminal, as SwiftUI shapes.
// ABOUTME: Drawn on a 1200x260 grid with the studio floor at y=220.

import SwiftUI

/// The shared measurements behind the easel row. Two shapes draw from it —
/// `EaselRow` for the furniture and `EaselScreens` for what is on the canvases —
/// because the screens are stroked finer than the frames and a `Shape` carries
/// one `StrokeStyle`.
enum EaselGeometry {
    /// One easel, measured up from the floor: where it stands, the terminal it
    /// holds, how long its legs are, and how far the mast shows above the frame.
    struct Easel {
        let centerX: Double
        let canvasHalfWidth: Double
        let canvasHeight: Double
        let legHeight: Double
        let mastStub: Double
    }

    /// One easel's derived edges, so both shapes agree on where the canvas is.
    struct Metrics {
        let left: Double
        let top: Double
        let width: Double
        let height: Double
        let trayTopY: Double
        let trayBottomY: Double
        let trayHalf: Double
    }

    static let gridWidth: Double = 1200
    static let gridHeight: Double = 260

    static let floorY: Double = 220
    static let floorStart: Double = 20
    static let floorEnd: Double = 1180
    /// Tray half-span, as a multiple of the canvas half-width. The front feet
    /// land under the tray's edges, so this also sets how wide the base stands.
    static let trayRatio: Double = 1.10
    /// Tray depth, as a fraction of canvas height.
    static let trayThickness: Double = 0.13
    /// Where the front legs meet the tray, as a fraction of the canvas half-width.
    static let legTopSpread: Double = 0.73
    /// Crossbar height, as a fraction of the way down the legs.
    static let crossbarHeight: Double = 0.35
    /// The clamp under the mast: half-width as a fraction of canvas width, and
    /// height as a fraction of the mast stub.
    static let clampSpan: Double = 0.22
    static let clampHeight: Double = 0.30

    static let easels: [Easel] = [
        Easel(centerX: 174, canvasHalfWidth: 52, canvasHeight: 56, legHeight: 87, mastStub: 14),
        Easel(centerX: 391, canvasHalfWidth: 58, canvasHeight: 62, legHeight: 97, mastStub: 16),
        Easel(centerX: 604, canvasHalfWidth: 48, canvasHeight: 52, legHeight: 80, mastStub: 12),
        Easel(centerX: 815, canvasHalfWidth: 56, canvasHeight: 60, legHeight: 92, mastStub: 15),
        Easel(centerX: 1028, canvasHalfWidth: 50, canvasHeight: 54, legHeight: 84, mastStub: 13),
    ]

    static func metrics(for easel: Easel) -> Metrics {
        let trayBottomY = floorY - easel.legHeight
        let trayTopY = trayBottomY - easel.canvasHeight * trayThickness
        return Metrics(
            left: easel.centerX - easel.canvasHalfWidth,
            top: trayTopY - easel.canvasHeight,
            width: easel.canvasHalfWidth * 2,
            height: easel.canvasHeight,
            trayTopY: trayTopY,
            trayBottomY: trayBottomY,
            trayHalf: easel.canvasHalfWidth * trayRatio
        )
    }
}

/// A drawing surface that maps the 1200x260 design grid onto a rect.
private struct Grid {
    let sx: Double
    let sy: Double
    var path = Path()

    init(_ rect: CGRect) {
        sx = rect.width / EaselGeometry.gridWidth
        sy = rect.height / EaselGeometry.gridHeight
    }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * sx, y: y * sy)
    }

    mutating func move(_ x: Double, _ y: Double) {
        path.move(to: point(x, y))
    }

    mutating func line(_ x: Double, _ y: Double) {
        path.addLine(to: point(x, y))
    }

    mutating func quadCurve(control cx: Double, _ cy: Double, to x: Double, _ y: Double) {
        path.addQuadCurve(to: point(x, y), control: point(cx, cy))
    }

    mutating func segment(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        move(x1, y1)
        line(x2, y2)
    }
}

/// The easels themselves: floor, canvas frames, masts, trays, and legs.
struct EaselRow: Shape {
    func path(in rect: CGRect) -> Path {
        var g = Grid(rect)

        g.segment(EaselGeometry.floorStart, EaselGeometry.floorY,
                  EaselGeometry.floorEnd, EaselGeometry.floorY)

        for easel in EaselGeometry.easels {
            let m = EaselGeometry.metrics(for: easel)
            let cx = easel.centerX
            let cw = easel.canvasHalfWidth

            // Canvas, its bottom edge shared with the top of the tray.
            g.move(m.left, m.trayTopY)
            g.line(m.left, m.top)
            g.line(m.left + m.width, m.top)
            g.line(m.left + m.width, m.trayTopY)
            g.path.closeSubpath()

            // Mast, and the clamp it rises from.
            g.segment(cx, m.top, cx, m.top - easel.mastStub)
            let clampY = m.top - easel.mastStub * EaselGeometry.clampHeight
            g.segment(cx - m.width * EaselGeometry.clampSpan, clampY,
                      cx + m.width * EaselGeometry.clampSpan, clampY)

            // Tray.
            g.move(cx - m.trayHalf, m.trayTopY)
            g.line(cx - m.trayHalf, m.trayBottomY)
            g.line(cx + m.trayHalf, m.trayBottomY)
            g.line(cx + m.trayHalf, m.trayTopY)

            // Front legs, splaying out to land under the tray's edges.
            for side in [-1.0, 1.0] {
                g.segment(cx + side * cw * EaselGeometry.legTopSpread, m.trayBottomY,
                          cx + side * m.trayHalf, EaselGeometry.floorY)
            }

            // Crossbar between them.
            let barY = m.trayBottomY
                + (EaselGeometry.floorY - m.trayBottomY) * EaselGeometry.crossbarHeight
            let legTopX = cw * EaselGeometry.legTopSpread
            let barX = legTopX + (m.trayHalf - legTopX) * EaselGeometry.crossbarHeight
            g.segment(cx - barX, barY, cx + barX, barY)

            // Rear leg, vertical in this view.
            g.segment(cx, m.trayBottomY, cx, EaselGeometry.floorY)
        }

        return g.path
    }
}

/// What is on the canvases: five terminals, each at a different shell prompt.
struct EaselScreens: Shape {
    /// A piece of one line. Runs are widths as a fraction of the line's text
    /// width; the rest is the prompt and the cursor sitting after it.
    enum Token {
        case chevron
        case doubleChevron
        case dollar
        case tilde
        case lambda
        /// A run of "text" that wide.
        case run(Double)
        /// The block cursor, waiting at the end of an unfinished line.
        case cursor

        /// Advance width and cap height, as multiples of the base glyph box.
        /// The glyphs are not one size: `$` is narrow and tall, `>>` is two
        /// chevrons wide, `~` sits low.
        var scale: (width: Double, height: Double) {
            switch self {
            case .chevron: (0.95, 1.0)
            case .doubleChevron: (1.75, 1.0)
            case .dollar: (0.72, 1.35)
            case .tilde: (1.0, 0.85)
            case .lambda: (0.9, 1.2)
            case .run, .cursor: (1, 1)
            }
        }
    }

    /// One screen per easel, top line first. Each easel is at a different
    /// prompt: `>`, `$`, `~`, `>>`, `λ`.
    private static let screens: [[[Token]]] = [
        [
            [.chevron, .run(0.52)],
            [.run(0.74)],
            [.run(0.40)],
            [.chevron, .cursor],
        ],
        [
            [.dollar, .run(0.50)],
            [.run(0.86)],
            [.run(0.30), .run(0.34)],
            [.run(0.52)],
            [.dollar, .cursor],
        ],
        [
            [.tilde, .run(0.44)],
            [.run(0.62)],
            [.tilde, .cursor],
        ],
        [
            [.doubleChevron, .run(0.40)],
            [.run(0.78)],
            [.run(0.44)],
            [.doubleChevron, .cursor],
        ],
        [
            [.lambda, .run(0.46)],
            [.run(0.36)],
            [.run(0.66)],
            [.lambda, .cursor],
        ],
    ]

    /// Screen margins and type size, as fractions of the canvas.
    private static let padX: Double = 0.09
    private static let padY: Double = 0.16
    private static let glyphWidth: Double = 0.06
    private static let wordGap: Double = 0.035
    /// Cap height, bounded so the shortest canvas does not get fat glyphs.
    private static let lineHeightRatio: Double = 0.62
    private static let maxGlyphHeight: Double = 0.105

    func path(in rect: CGRect) -> Path {
        var g = Grid(rect)

        for (easel, screen) in zip(EaselGeometry.easels, Self.screens) {
            let m = EaselGeometry.metrics(for: easel)
            let baseWidth = m.width * Self.glyphWidth
            let gap = m.width * Self.wordGap
            let textLeft = m.left + m.width * Self.padX
            let textWidth = m.width * (1 - 2 * Self.padX)

            let firstY = m.top + m.height * Self.padY
            let lastY = m.top + m.height * (1 - Self.padY)
            let pitch = screen.count > 1 ? (lastY - firstY) / Double(screen.count - 1) : 0
            let baseHeight = min(pitch * Self.lineHeightRatio, m.height * Self.maxGlyphHeight)

            for (index, tokens) in screen.enumerated() {
                let y = firstY + pitch * Double(index)
                var x = textLeft

                for token in tokens {
                    switch token {
                    case let .run(width):
                        g.segment(x, y, x + textWidth * width, y)
                        x += textWidth * width
                    case .cursor:
                        g.segment(x, y - baseHeight * 0.62, x, y + baseHeight * 0.62)
                        x += baseWidth * 0.35
                    default:
                        let scale = token.scale
                        Self.draw(token, in: &g, at: x, y,
                                  width: baseWidth * scale.width,
                                  height: baseHeight * scale.height)
                        x += baseWidth * scale.width
                    }
                    x += gap
                }
            }
        }

        return g.path
    }

    /// Draws one prompt glyph in the box (x, y - height/2) ... (x + width, y + height/2).
    private static func draw(_ token: Token, in g: inout Grid,
                             at x: Double, _ y: Double,
                             width w: Double, height h: Double)
    {
        let half = h / 2

        switch token {
        case .chevron:
            g.move(x, y - half)
            g.line(x + w, y)
            g.line(x, y + half)

        case .doubleChevron:
            for offset in [0.0, 0.58] {
                g.move(x + w * offset, y - half)
                g.line(x + w * (offset + 0.42), y)
                g.line(x + w * offset, y + half)
            }

        case .dollar:
            g.segment(x + w * 0.5, y - half, x + w * 0.5, y + half)
            g.move(x + w, y - half * 0.52)
            g.quadCurve(control: x + w * 0.62, y - half * 0.9, to: x + w * 0.18, y - half * 0.62)
            g.quadCurve(control: x - w * 0.12, y - half * 0.2, to: x + w * 0.5, y - half * 0.04)
            g.quadCurve(control: x + w * 1.12, y + half * 0.14, to: x + w * 0.82, y + half * 0.5)
            g.quadCurve(control: x + w * 0.44, y + half * 0.86, to: x, y + half * 0.52)

        case .tilde:
            g.move(x, y)
            g.quadCurve(control: x + w * 0.25, y - half * 1.05, to: x + w * 0.5, y)
            g.quadCurve(control: x + w * 0.75, y + half * 1.05, to: x + w, y)

        case .lambda:
            let apexX = x + w * 0.30
            g.move(apexX, y - half)
            g.line(x + w, y + half)
            // The short leg branches off the main stroke, 45% of the way down.
            g.move(apexX + (x + w - apexX) * 0.45, y - half + h * 0.45)
            g.line(x, y + half)

        case .run, .cursor:
            break
        }
    }
}

struct EaselRowView: View {
    private static let ink = Color.primary.opacity(0.1)

    var body: some View {
        ZStack {
            EaselRow()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            EaselScreens()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(EaselGeometry.gridWidth / EaselGeometry.gridHeight, contentMode: .fit)
    }
}
