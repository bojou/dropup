import AppKit
import DropUpCore

/// Draws the menubar icon: a tray with an up arrow, a progress ring while uploading, a check when done and a cross
/// when something failed.
/// All images are templates, so macOS tints them for light, dark and tinted menubars.
/// Coordinates follow the 16 × 16 artwork in the design mockup, scaled up to the 18 pt menubar size.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: MenubarState) -> NSImage {
        switch state {
        case .idle:
            return trayImage()
        case .uploading(let fraction):
            return ringImage(fraction: fraction, symbol: .arrow)
        case .succeeded:
            return ringImage(fraction: 1, symbol: .check)
        case .failed:
            return ringImage(fraction: 1, symbol: .cross)
        }
    }

    private enum Symbol { case arrow, check, cross }

    private static func trayImage() -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = rect.width / 16
            let transform = AffineTransform(scaleByX: scale, byY: scale)
            let path = NSBezierPath()
            // Arrow shaft and head.
            path.move(to: NSPoint(x: 8, y: 10)); path.line(to: NSPoint(x: 8, y: 2.5))
            path.move(to: NSPoint(x: 4.75, y: 5.75)); path.line(to: NSPoint(x: 8, y: 2.5)); path.line(to: NSPoint(x: 11.25, y: 5.75))
            // Tray.
            path.move(to: NSPoint(x: 2.25, y: 10))
            path.line(to: NSPoint(x: 2.25, y: 12.25))
            path.curve(to: NSPoint(x: 3.75, y: 13.75), controlPoint1: NSPoint(x: 2.25, y: 13.08), controlPoint2: NSPoint(x: 2.92, y: 13.75))
            path.line(to: NSPoint(x: 12.25, y: 13.75))
            path.curve(to: NSPoint(x: 13.75, y: 12.25), controlPoint1: NSPoint(x: 13.08, y: 13.75), controlPoint2: NSPoint(x: 13.75, y: 13.08))
            path.line(to: NSPoint(x: 13.75, y: 10))
            path.transform(using: transform)
            style(path, width: 1.5 * scale)
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ringImage(fraction: Double, symbol: Symbol) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.25

            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            style(track, width: 1.6)
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()

            let clamped = min(max(fraction, 0.02), 1)
            let arc = NSBezierPath()
            // The view is flipped, so angles run clockwise; start at 12 o'clock.
            arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + 360 * clamped, clockwise: false)
            style(arc, width: 1.6)
            NSColor.black.setStroke()
            arc.stroke()

            let glyph = NSBezierPath()
            switch symbol {
            case .arrow:
                glyph.move(to: NSPoint(x: 9, y: 12)); glyph.line(to: NSPoint(x: 9, y: 6.5))
                glyph.move(to: NSPoint(x: 6.9, y: 8.6)); glyph.line(to: NSPoint(x: 9, y: 6.5)); glyph.line(to: NSPoint(x: 11.1, y: 8.6))
            case .check:
                glyph.move(to: NSPoint(x: 5.9, y: 9.2)); glyph.line(to: NSPoint(x: 8, y: 11.3)); glyph.line(to: NSPoint(x: 12.2, y: 6.8))
            case .cross:
                glyph.move(to: NSPoint(x: 6.4, y: 6.4)); glyph.line(to: NSPoint(x: 11.6, y: 11.6))
                glyph.move(to: NSPoint(x: 11.6, y: 6.4)); glyph.line(to: NSPoint(x: 6.4, y: 11.6))
            }
            style(glyph, width: 1.4)
            NSColor.black.setStroke()
            glyph.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func style(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
}
