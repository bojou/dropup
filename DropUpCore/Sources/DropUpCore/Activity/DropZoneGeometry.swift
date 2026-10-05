import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How big the drop zone is: the panel that opens under the menubar icon and the drop area in the popover.
/// `standard` is the size DropUp always had, and the Settings label for it is "Default".
public enum DropZoneSize: String, Codable, CaseIterable, Sendable {
    case small
    case standard
    case large

    /// Everything about the drop zone, its size and what is drawn in it, is the standard size times this.
    public var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .standard: 1
        case .large: 1.25
        }
    }

    /// A length or font size from the standard layout, scaled to this size and whole points. Text does not go below
    /// `minimum`, so it stays readable at the small size.
    public func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max((value * scale).rounded(), minimum)
    }
}

/// Where the large drop panel appears and when it should. Pure geometry in AppKit screen coordinates
/// (origin bottom-left), so it can be tested without a display.
public enum DropZoneGeometry {
    /// Size of the panel in points at the standard size; the other sizes are this times `DropZoneSize.scale`.
    public static let panelSize = CGSize(width: 236, height: 196)

    /// The drop area in the popover when nothing is uploading, at the standard size. Its width is the popover's.
    public static let popoverDropAreaHeight: CGFloat = 148

    /// The panel's size at `size`.
    public static func panelSize(for size: DropZoneSize) -> CGSize {
        CGSize(width: size.scaled(panelSize.width), height: size.scaled(panelSize.height))
    }

    /// The height of the popover's drop area at `size`.
    public static func popoverDropAreaHeight(for size: DropZoneSize) -> CGFloat {
        size.scaled(popoverDropAreaHeight)
    }

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

    /// Panel frame: hangs directly below the icon, centered on it, and shifts sideways only as far as
    /// needed to stay on the screen.
    public static func panelFrame(iconFrame: CGRect, visibleScreenFrame: CGRect, size: CGSize = panelSize) -> CGRect {
        var x = iconFrame.midX - size.width / 2
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
