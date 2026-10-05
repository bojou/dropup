import SwiftUI
import DropUpCore

/// The large drop target (see DropPanelController). Sized by `DropZoneGeometry.panelSize(for:)`, from the drop zone
/// size in Settings, and everything in it scales with it.
struct DropPanelView: View {
    let model: AppModel

    var body: some View {
        let hot = model.panelState == .hot
        let visible = model.panelState != .hidden
        let zone = model.preferences.dropZoneSize
        let size = DropZoneGeometry.panelSize(for: zone)

        VStack(spacing: zone.scaled(8)) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: zone.scaled(hot ? 30 : 26), weight: .medium))
                .foregroundStyle(hot ? Color.white : Color.accentColor)
                .frame(width: zone.scaled(hot ? 60 : 52), height: zone.scaled(hot ? 60 : 52))
                .background(Circle().fill(hot ? Color.accentColor : Color.primary.opacity(0.07)))
            Text(hot ? "Release to upload" : "Drop to upload")
                .font(.system(size: zone.scaled(14, minimum: 11), weight: .semibold))
            if let destination = model.destinationSummary {
                Text(destination)
                    .font(.system(size: zone.scaled(11, minimum: 10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, zone.scaled(18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: zone.scaled(12), style: .continuous)
                .fill(hot ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: zone.scaled(12), style: .continuous)
                .strokeBorder(
                    hot ? Color.accentColor : Color.primary.opacity(0.25),
                    style: StrokeStyle(lineWidth: hot ? 2 : 1.5, dash: hot ? [] : [zone.scaled(6), zone.scaled(4)])
                )
        )
        .padding(zone.scaled(10))
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: zone.scaled(18), style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        )
        .scaleEffect(visible ? 1 : 0.88, anchor: .top)
        .opacity(visible ? 1 : 0)
        .padding(DropZoneGeometry.shadowMargin) // the window is larger than the card so the shadow isn't clipped
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop files here to upload")
    }
}
