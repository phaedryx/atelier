// ABOUTME: A row of studio easels as a SwiftUI shape.
// ABOUTME: Drawn on a 1200x260 grid with the studio floor at y=220.

import SwiftUI

struct EaselRow: Shape {
    /// One easel, measured up from the floor: where it stands, how tall its legs
    /// are, and the canvas resting on its tray.
    private struct Easel {
        let centerX: Double
        let legHeight: Double
        let canvasHeight: Double
        let canvasHalfWidth: Double
        /// How far the mast shows above the canvas.
        let mastStub: Double
    }

    private static let floorY: Double = 220
    private static let floorStart: Double = 20
    private static let floorEnd: Double = 1180
    /// How far the tray sticks out past the canvas, each side.
    private static let trayOverhang: Double = 10
    /// Half-span where the front legs meet the tray.
    private static let legTopSpread: Double = 10
    /// Front feet, as a fraction of leg height. The rear leg splays further, so
    /// the tripod reads as three legs rather than a doubled line.
    private static let legSplay: Double = 0.42
    private static let rearLegSplay: Double = 0.85

    private static let easels: [Easel] = [
        Easel(centerX: 135, legHeight: 59, canvasHeight: 40, canvasHalfWidth: 30, mastStub: 9),
        Easel(centerX: 317, legHeight: 64, canvasHeight: 52, canvasHalfWidth: 32, mastStub: 10),
        Easel(centerX: 502, legHeight: 58, canvasHeight: 30, canvasHalfWidth: 33, mastStub: 8),
        Easel(centerX: 692, legHeight: 74, canvasHeight: 48, canvasHalfWidth: 37, mastStub: 10),
        Easel(centerX: 877, legHeight: 50, canvasHeight: 34, canvasHalfWidth: 28, mastStub: 8),
        Easel(centerX: 1059, legHeight: 62, canvasHeight: 44, canvasHalfWidth: 34, mastStub: 9),
    ]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 1200
        let sy = rect.height / 260
        var p = Path()

        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * sx, y: y * sy)
        }

        p.move(to: pt(Self.floorStart, Self.floorY))
        p.addLine(to: pt(Self.floorEnd, Self.floorY))

        for easel in Self.easels {
            let trayY = Self.floorY - easel.legHeight
            let canvasTopY = trayY - easel.canvasHeight

            // Canvas — three sides, because its bottom edge is the tray.
            p.move(to: pt(easel.centerX - easel.canvasHalfWidth, trayY))
            p.addLine(to: pt(easel.centerX - easel.canvasHalfWidth, canvasTopY))
            p.addLine(to: pt(easel.centerX + easel.canvasHalfWidth, canvasTopY))
            p.addLine(to: pt(easel.centerX + easel.canvasHalfWidth, trayY))

            // Mast, showing above the canvas.
            p.move(to: pt(easel.centerX, canvasTopY))
            p.addLine(to: pt(easel.centerX, canvasTopY - easel.mastStub))

            // Tray.
            p.move(to: pt(easel.centerX - easel.canvasHalfWidth - Self.trayOverhang, trayY))
            p.addLine(to: pt(easel.centerX + easel.canvasHalfWidth + Self.trayOverhang, trayY))

            // Front legs.
            p.move(to: pt(easel.centerX - Self.legTopSpread, trayY))
            p.addLine(to: pt(easel.centerX - easel.legHeight * Self.legSplay, Self.floorY))
            p.move(to: pt(easel.centerX + Self.legTopSpread, trayY))
            p.addLine(to: pt(easel.centerX + easel.legHeight * Self.legSplay, Self.floorY))

            // Rear leg.
            p.move(to: pt(easel.centerX, trayY))
            p.addLine(to: pt(easel.centerX + easel.legHeight * Self.rearLegSplay, Self.floorY))
        }

        return p
    }
}

struct EaselRowView: View {
    var body: some View {
        EaselRow()
            .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .aspectRatio(1200 / 260, contentMode: .fit)
    }
}
