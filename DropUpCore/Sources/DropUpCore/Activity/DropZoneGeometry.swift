import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the large drop panel appears and when it should. Pure geometry in AppKit screen coordinates
/// (origin bottom-left), so it can be tested without a display.
public enum DropZoneGeometry {
    /// Size of the panel in points. **The one place to tune it**: the design review thought 236 × 196 may be a bit big.
    public static let panelSize = CGSize(width: 236, height: 196)

    /// How close, in points, a dragged file must get to the menubar icon before the panel opens.
    public static let proximityRadius: CGFloat = 150

    /// Transparent border around the card inside the panel's window, where its shadow is drawn.
    public static let shadowMargin: CGFloat = 16

    /// Gap between the menubar and the panel.
    public static let gapBelowMenubar: CGFloat = 6

    /// Extra margin around the panel in which a drag still counts as "on it", so a hand that drifts
    /// off the edge doesn't make it flicker shut.
    public static let panelSlack: CGFloat = 24

    /// The window needs room for the shadow around the card.
    public static func windowFrame(forCard card: CGRect) -> CGRect {
        card.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    /// Whether `point` is within the proximity zone of the icon (a circle around its center).
    public static func isNearIcon(_ point: CGPoint, iconFrame: CGRect, radius: CGFloat = proximityRadius) -> Bool {
        let dx = point.x - iconFrame.midX
        let dy = point.y - iconFrame.midY
        return dx * dx + dy * dy <= radius * radius
    }

    /// Panel frame: hangs below the icon, right edges aligned when possible, and never leaves the screen.
    public static func panelFrame(iconFrame: CGRect, visibleScreenFrame: CGRect, size: CGSize = panelSize) -> CGRect {
        var x = iconFrame.maxX - size.width + 10
        x = min(x, visibleScreenFrame.maxX - size.width - 8)
        x = max(x, visibleScreenFrame.minX + 8)
        let y = min(iconFrame.minY, visibleScreenFrame.maxY) - gapBelowMenubar - size.height
        return CGRect(x: x, y: max(y, visibleScreenFrame.minY), width: size.width, height: size.height)
    }

    /// Whether to keep the panel open while a file is dragged: near the icon, or still over/around the panel.
    public static func shouldStayOpen(_ point: CGPoint, iconFrame: CGRect, panelFrame: CGRect) -> Bool {
        isNearIcon(point, iconFrame: iconFrame)
            || panelFrame.insetBy(dx: -panelSlack, dy: -panelSlack).contains(point)
    }
}
