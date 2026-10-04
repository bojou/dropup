import SwiftUI
import DropUpCore

/// Sizes of the popover, so its width and spacing are set in one place.
enum PopoverLayout {
    static let width: CGFloat = 380
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 8
    /// The upload list shows this many rows and scrolls beyond that, instead of stretching the popover down the screen.
    static let visibleRows = 6
    /// About one row of the list; the cap is `visibleRows` of these. Rows with a progress bar are a little taller.
    static let rowHeight: CGFloat = 52
}

/// What opens when you click the menubar icon: where files go, what is uploading, and recent uploads.
struct PopoverView: View {
    let model: AppModel
    let openSettings: () -> Void
    let openBrowse: () -> Void
    let openChooseFolder: () -> Void
    let openUpdate: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let activity = model.activity
        return VStack(spacing: PopoverLayout.spacing) {
            header
            updateNotice
            if activity.isBusy || activity.hasPaused {
                dropMoreStrip
            } else if activity.items.isEmpty {
                readyZone
            }
            sectionHeader(activity)
            rows(activity)
            Divider().padding(.horizontal, 4).padding(.vertical, 2)
            footer
        }
        .padding(PopoverLayout.padding)
        .frame(width: PopoverLayout.width)
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
                .frame(width: 34, height: 34)
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

    /// A new version is waiting. Sparkle's window, with the notes and the choice to install, opens from the button.
    @ViewBuilder
    private var updateNotice: some View {
        if let version = model.updates.availableVersion {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 12, weight: .semibold))
                    Text("DropUp \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Update…", action: openUpdate)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        }
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
        .frame(height: 148)
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
                } else if activity.canClear {
                    // Interrupted uploads stay until they are resumed or removed, so with only those there is nothing to clear.
                    ListButton(title: "Clear", label: "Clear recent uploads") { model.clearFinished() }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
    }

    /// Up to `PopoverLayout.visibleRows` rows take the room they need. A longer list gets a fixed height of that many
    /// rows and scrolls, so the popover never grows past a known size.
    @ViewBuilder
    private func rows(_ activity: UploadActivity) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(activity.items) { item in
                UploadRow(item: item, activity: activity, now: model.now, model: model)
            }
        }
        if activity.items.count > PopoverLayout.visibleRows {
            ScrollView {
                list
            }
            .frame(height: CGFloat(PopoverLayout.visibleRows) * PopoverLayout.rowHeight)
        } else {
            list
        }
    }

    /// Change Folder, Browse and Quit as three equal tiles, icon above the label. With Cancel All and Clear in the
    /// list heading, the footer is only these.
    private var footer: some View {
        HStack(spacing: PopoverLayout.spacing) {
            // Without a server there is nothing to change or browse: the tiles stay, greyed out.
            FooterTile(title: "Change Folder", symbol: "folder", action: openChooseFolder)
                .disabled(model.config == nil)
            FooterTile(title: "Browse", symbol: "server.rack", action: openBrowse)
                .disabled(model.config == nil)
            FooterTile(title: "Quit DropUp", symbol: "power", isQuit: true) { NSApp.terminate(nil) }
        }
    }
}

/// One of the footer's tiles. It tints blue under the pointer, and Quit tints red. Disabled, it is dimmed and doesn't react.
private struct FooterTile: View {
    let title: String
    let symbol: String
    var isQuit = false
    let action: () -> Void
    @State private var pointerIsOver = false
    @Environment(\.isEnabled) private var isEnabled

    private var isHovering: Bool { pointerIsOver && isEnabled }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isQuit && isHovering ? Color.red : Color.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 11)
            .padding(.bottom, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { pointerIsOver = $0 }
    }

    private var iconColor: Color {
        if !isQuit { return Color.accentColor }
        return isHovering ? Color.red : Color.secondary
    }

    private var fill: Color {
        if isHovering { return isQuit ? Color.red.opacity(0.14) : Color.accentColor.opacity(0.15) }
        return Color.primary.opacity(0.06)
    }
}

/// Presses in slightly, like the tiles in Control Center.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
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
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                } else if hidesNames {
                    // The extension says too much about a file whose name is hidden.
                    Image(systemName: "doc")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.badge)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityText.displayName(of: item, hidingNames: hidesNames))
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
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isFailure ? Color.red.opacity(0.08) : .clear))
        .onHover { isHovering = $0 }
        .contextMenu {
            if item.state == .waiting || item.state == .uploading {
                Button("Pause") { model.pause(item.id) }
                    .disabled(!model.canPause)
            }
            if isFailure || item.state == .interrupted || item.state == .paused, model.canRetry(item.id) {
                Button(model.retryTitle(item.id)) { model.retry(item.id) }
            }
            if canDismiss, !isRemoving {
                Button("Remove from List") { model.dismiss(item.id) }
            }
            if removalProblem != nil, canDismiss, !isRemoving {
                // The server can't be reached to take the half-sent file away: the user can still let go of the row.
                Button("Remove from List Anyway") { model.dismiss(item.id, force: true) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var canDismiss: Bool { activity.canDismiss(item) }

    private var isRemoving: Bool { model.removing.contains(item.id) }

    /// Why the half-sent file of this upload could not be taken off the server, while its row is still here.
    private var removalProblem: String? {
        item.state.isFinished ? model.removalProblems[item.id] : nil
    }

    /// The same round cross as Cancel, for taking one finished upload out of the list. For an upload that stopped
    /// with part of its file on the server it is a cancel: the half-sent file is removed too.
    private var dismissButton: some View {
        let label = item.isResumable ? "Cancel and remove the partly sent file" : "Remove from list"
        return Button { model.dismiss(item.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isRemoving)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The round buttons Pause and Resume share one size and one place at the end of the row: pausing turns the pause
    /// icon into the play icon where it stands.
    private func roundButton(_ symbol: String, label: String, help: String, nudge: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .offset(x: nudge)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(label)
    }

    private var pauseButton: some View {
        roundButton("pause.fill", label: "Pause upload", help: model.canPause ? "Pause" : "Pausing needs Keep recent uploads to be on") {
            model.pause(item.id)
        }
        .disabled(!model.canPause)
    }

    private var playButton: some View {
        // The triangle's weight sits to its left, so it is nudged to look centred in the circle.
        roundButton("play.fill", label: "Resume upload", help: "Resume", nudge: 0.5) {
            model.retry(item.id)
        }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return removalProblem != nil
    }

    private var hidesNames: Bool { model.preferences.hideRecentNames }

    private var meta: String {
        if isRemoving { return "Removing the partly sent file…" }
        if let problem = removalProblem {
            let reason = ActivityText.failureMessage(problem, for: item, hidingNames: hidesNames, hiddenPaths: model.hiddenPaths)
            return "The partly sent file is still on the server. \(reason)"
        }
        let total = Format.bytes(item.totalBytes)
        // A folder's size is not known until it has been read, which takes a while for a big one.
        let sizeKnown = !item.isFolder || item.totalBytes > 0
        switch item.state {
        case .waiting:
            return sizeKnown ? "\(total) · Waiting" : "Waiting"
        case .uploading:
            guard sizeKnown else { return "Reading the folder…" }
            var parts: [String] = []
            if item.isReconnecting {
                parts.append("Waiting for connection…")
            } else if let notice = item.notice {
                parts.append(notice)
            }
            parts.append("\(Format.bytes(item.bytesSent)) of \(total)")
            if !item.isReconnecting, let left = ActivityText.timeLeft(activity.secondsRemaining(now: now)), activity.running.first?.id == item.id {
                parts.append(left)
            }
            return parts.joined(separator: " · ")
        case .succeeded:
            return "\(total) · \(Format.ago(item.finishedAt, now: now))"
        case .failed(let message):
            return ActivityText.failureMessage(message, for: item, hidingNames: hidesNames, hiddenPaths: model.hiddenPaths)
        case .interrupted:
            return sizeKnown ? "Interrupted · \(total)" : "Interrupted"
        case .paused:
            guard sizeKnown else { return "Paused" }
            return item.bytesSent > 0 ? "Paused · \(Format.bytes(item.bytesSent)) of \(total)" : "Paused · \(total)"
        case .cancelled:
            return "Cancelled"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .waiting, .uploading:
            HStack(spacing: 6) {
                pauseButton
                Button { model.cancel(item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel upload")
            }
        case .succeeded:
            // The check turns into a cross under the pointer, which removes the upload from the list.
            if isHovering, canDismiss {
                dismissButton
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.green))
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Uploaded")
            }
        case .failed, .interrupted, .paused:
            // Same spacing as the pause and cancel pair, so Pause turns into Resume where it stands.
            HStack(spacing: 6) {
                if model.canRetry(item.id) {
                    if model.resumes(item.id) {
                        playButton
                    } else {
                        Button(model.retryTitle(item.id)) { model.retry(item.id) }
                            .controlSize(.small)
                    }
                }
                if canDismiss { dismissButton }
            }
        case .cancelled:
            if canDismiss { dismissButton }
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
