import SwiftUI
import DropUpCore

/// What opens when you click the menubar icon: where files go, what is uploading, and recent uploads.
struct PopoverView: View {
    let model: AppModel
    let openSettings: () -> Void
    let openBrowse: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        if model.isChoosingFolder {
            PopoverFolderChooser(model: model)
        } else {
            uploads
        }
    }

    private var uploads: some View {
        let activity = model.activity
        return VStack(spacing: 6) {
            header
            if activity.isBusy {
                dropMoreStrip
            } else if activity.items.isEmpty {
                readyZone
            }
            sectionHeader(activity)
            rows(activity)
            Divider().padding(.horizontal, 4).padding(.vertical, 2)
            footer
        }
        .padding(10)
        .frame(width: 336)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text("DropUp").font(.system(size: 13, weight: .semibold))
                Text(model.serverSummary ?? "Not set up yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .padding(.leading, 4)
        .padding(.bottom, 4)
    }

    private var readyZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text("Drop files to upload").font(.system(size: 13, weight: .medium))
            Text("or drag them onto the menubar icon")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .background(dashedBorder)
    }

    private var dropMoreStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text("Drop more files to add them").font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(dashedBorder)
    }

    private var dashedBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.02)))
    }

    @ViewBuilder
    private func sectionHeader(_ activity: UploadActivity) -> some View {
        if !activity.items.isEmpty {
            HStack {
                Text(activity.isBusy
                     ? ActivityText.uploadingHeader(activity)
                     : (activity.finished.contains { if case .failed = $0.state { true } else { false } } ? "Done" : "Recent"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if activity.isBusy, let speed = activity.speed(now: model.now) {
                    Text("\(Format.bytes(Int64(speed)))/s")
                        .font(.system(size: 11).monospacedDigit())
                        .fontWeight(.regular)
                } else if !activity.isBusy {
                    Text(ActivityText.finishedSummary(activity))
                        .font(.system(size: 11).monospacedDigit())
                        .fontWeight(.regular)
                }
                // These act on the list, so they sit with its heading and leave the footer for the server buttons.
                if activity.isBusy {
                    ListButton(title: "Cancel All") { model.cancelAll() }
                } else {
                    ListButton(title: "Clear", label: "Clear recent uploads") { model.clearFinished() }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func rows(_ activity: UploadActivity) -> some View {
        VStack(spacing: 0) {
            ForEach(activity.items) { item in
                UploadRow(item: item, activity: activity, now: model.now, model: model)
            }
        }
    }

    /// The server buttons on the left and Quit on the right. With Cancel All and Clear in the list heading,
    /// the row has room for them at every state.
    private var footer: some View {
        HStack {
            folderButtons
            Spacer()
            FooterButton(title: "Quit DropUp") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private var folderButtons: some View {
        if model.config != nil {
            FooterButton(title: "Change Folder") { model.isChoosingFolder = true }
            FooterButton(title: "Browse", action: openBrowse)
        }
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small text button in the list heading.
private struct ListButton: View {
    let title: String
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
    }
}

private struct UploadRow: View {
    let item: UploadActivity.Item
    let activity: UploadActivity
    let now: Date
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(item.badge)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .uploading {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(meta)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isFailure ? Color.red.opacity(0.08) : .clear))
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failed = item.state { true } else { false }
    }

    private var meta: String {
        let total = Format.bytes(item.totalBytes)
        switch item.state {
        case .waiting:
            return "\(total) · Waiting"
        case .uploading:
            let progress = "\(Format.bytes(item.bytesSent)) of \(total)"
            if let left = ActivityText.timeLeft(activity.secondsRemaining(now: now)), activity.running.first?.id == item.id {
                return "\(progress) · \(left)"
            }
            return progress
        case .succeeded:
            return "\(total) · \(Format.ago(item.finishedAt, now: now))"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .waiting, .uploading:
            Button { model.cancel(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel upload")
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.green))
                .accessibilityLabel("Uploaded")
        case .failed:
            Button("Retry") { model.retry(item.id) }
                .controlSize(.small)
        case .cancelled:
            EmptyView()
        }
    }
}

/// Number and date formatting for the popover.
enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        if now.timeIntervalSince(date) < 5 { return "Uploaded" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}
