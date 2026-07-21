import AppKit

/// Claude-only dual-bar menu-bar icon (session top / weekly bottom), matching CodexBar’s
/// monochrome template “crab” geometry without the multi-provider twists.
enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2
    private static let canvasPx = Int(outputSize.width * outputScale)

    private struct PixelGrid {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat {
            CGFloat(px) / self.scale
        }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }
    }

    private static let grid = PixelGrid(scale: outputScale)

    private struct RectPx {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        var midXPx: Int { self.x + self.w / 2 }

        func rect() -> CGRect {
            IconRenderer.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h)
        }
    }

    /// Builds a template icon from remaining percents (0…100).
    static func makeClaudeIcon(
        sessionRemaining: Double?,
        weeklyRemaining: Double?,
        stale: Bool = false) -> NSImage
    {
        self.renderImage {
            let baseFill = NSColor.labelColor
            let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
            let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
            let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1.0)

            let barWidthPx = 30
            let barXPx = (Self.canvasPx - barWidthPx) / 2
            let topRectPx = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
            let bottomRectPx = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)

            let effectiveWeekly: Double? = {
                guard let weeklyRemaining else { return nil }
                return weeklyRemaining <= 0 ? nil : weeklyRemaining
            }()

            self.drawBar(
                rectPx: topRectPx,
                remaining: sessionRemaining,
                baseFill: baseFill,
                fillColor: fillColor,
                trackFillAlpha: trackFillAlpha,
                trackStrokeAlpha: trackStrokeAlpha,
                addNotches: true)

            if let effectiveWeekly {
                self.drawBar(
                    rectPx: bottomRectPx,
                    remaining: effectiveWeekly,
                    baseFill: baseFill,
                    fillColor: fillColor,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    addNotches: false)
            } else {
                self.drawBar(
                    rectPx: bottomRectPx,
                    remaining: nil,
                    alpha: 0.45,
                    baseFill: baseFill,
                    fillColor: fillColor,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    addNotches: false)
            }
        }
    }

    private static func drawBar(
        rectPx: RectPx,
        remaining: Double?,
        alpha: CGFloat = 1.0,
        baseFill: NSColor,
        fillColor: NSColor,
        trackFillAlpha: CGFloat,
        trackStrokeAlpha: CGFloat,
        addNotches: Bool)
    {
        let rect = rectPx.rect()
        let cornerRadiusPx = addNotches ? 0 : rectPx.h / 2
        let radius = Self.grid.pt(cornerRadiusPx)

        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
        trackPath.fill()

        let strokeWidthPx = 2
        let insetPx = strokeWidthPx / 2
        let strokeRect = Self.grid.rect(
            x: rectPx.x + insetPx,
            y: rectPx.y + insetPx,
            w: max(0, rectPx.w - insetPx * 2),
            h: max(0, rectPx.h - insetPx * 2))
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)),
            yRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)))
        strokePath.lineWidth = CGFloat(strokeWidthPx) / Self.outputScale
        baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
        strokePath.stroke()

        if let remaining {
            let clamped = max(0, min(remaining / 100, 1))
            let fillWidthPx = max(0, min(rectPx.w, Int((CGFloat(rectPx.w) * CGFloat(clamped)).rounded())))
            if fillWidthPx > 0 {
                NSGraphicsContext.current?.cgContext.saveGState()
                trackPath.addClip()
                fillColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(
                    rect: Self.grid.rect(
                        x: rectPx.x,
                        y: rectPx.y,
                        w: fillWidthPx,
                        h: rectPx.h)).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }

        guard addNotches else { return }

        let ctx = NSGraphicsContext.current?.cgContext
        fillColor.withAlphaComponent(alpha).setFill()

        let armWidthPx = 3
        let armHeightPx = max(0, rectPx.h - 6)
        let armYPx = rectPx.y + 3
        NSBezierPath(rect: Self.grid.rect(
            x: rectPx.x - armWidthPx,
            y: armYPx,
            w: armWidthPx,
            h: armHeightPx)).fill()
        NSBezierPath(rect: Self.grid.rect(
            x: rectPx.x + rectPx.w,
            y: armYPx,
            w: armWidthPx,
            h: armHeightPx)).fill()

        let legCount = 4
        let legWidthPx = 2
        let legHeightPx = 3
        let legYPx = rectPx.y - legHeightPx
        let stepPx = max(1, rectPx.w / (legCount + 1))
        for idx in 0..<legCount {
            let cx = rectPx.x + stepPx * (idx + 1)
            NSBezierPath(rect: Self.grid.rect(
                x: cx - legWidthPx / 2,
                y: legYPx,
                w: legWidthPx,
                h: legHeightPx)).fill()
        }

        let eyeWidthPx = 2
        let eyeHeightPx = 5
        let eyeOffsetPx = 6
        let eyeYPx = rectPx.y + rectPx.h - eyeHeightPx - 2
        ctx?.saveGState()
        ctx?.setShouldAntialias(false)
        ctx?.clear(Self.grid.rect(
            x: rectPx.midXPx - eyeOffsetPx - eyeWidthPx / 2,
            y: eyeYPx,
            w: eyeWidthPx,
            h: eyeHeightPx))
        ctx?.clear(Self.grid.rect(
            x: rectPx.midXPx + eyeOffsetPx - eyeWidthPx / 2,
            y: eyeYPx,
            w: eyeWidthPx,
            h: eyeHeightPx))
        ctx?.restoreGState()
    }

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: Self.outputSize)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.outputSize.width * Self.outputScale),
            pixelsHigh: Int(Self.outputSize.height * Self.outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = Self.outputSize
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            draw()
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}
