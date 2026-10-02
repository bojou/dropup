import AppKit
import SwiftUI
import DropUpCore

/// The Browse window: every folder and file on the server, with drag-and-drop uploads into the folder on screen.
struct BrowseView: View {
    static let idealSize = CGSize(width: 920, height: 620)
    static let minimumSize = CGSize(width: 700, height: 460)

    let model: AppModel
    let browse: BrowseModel
    @State private var selection = Set<RemoteEntry.ID>()
    @State private var isDropTargeted = false
    @AppStorage("browse.showsHiddenFiles") private var showsHidden = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            if !model.downloads.items.isEmpty {
                Divider()
                downloadsPanel
            }
            if let progress = uploadProgress {
                Divider()
                uploadStrip(progress)
            }
            Divider()
            statusBar
        }
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height, maxHeight: .infinity
        )
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { dropHighlight } }
        .onAppear { browse.start() }
        .onChange(of: browse.path) { selection = [] }
    }

    private var visible: [RemoteEntry] {
        showsHidden ? browse.entries : browse.entries.filter { !$0.isHidden }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { browse.goUp() } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 22)
            }
            .disabled(browse.path == "/")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Enclosing folder")
            .accessibilityLabel("Go up one folder")

            breadcrumb

            if browse.isLoading { ProgressView().controlSize(.small) }

            Button { browse.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload this folder")
            .accessibilityLabel("Reload")

            Divider().frame(height: 18)

            Button { download(selectedFiles, askingWhere: false) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(selectedFiles.isEmpty)
            .help("Save the selected files to your Downloads folder")
            Button { download(selectedFiles, askingWhere: true) } label: {
                Text("Download To…")
            }
            .disabled(selectedFiles.isEmpty)
            .help("Choose where to save the selected files")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(RemotePath.trail(to: browse.path).enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Button { browse.go(to: step.path) } label: {
                        if index == 0 {
                            Label(browse.serverName, systemImage: "externaldrive.connected.to.line.below")
                        } else {
                            Text(step.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .foregroundStyle(step.path == browse.path ? Color.primary : Color.secondary)
                    .fontWeight(step.path == browse.path ? .semibold : .regular)
                    .help(step.path)
                }
            }
            .font(.system(size: 12))
        }
        .defaultScrollAnchor(.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Listing

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = browse.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { browse.reload() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }
            if visible.isEmpty && !browse.isLoading {
                if browse.error == nil { emptyFolder } else { Spacer() }
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: Self.icon(for: entry))
                        .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
                }
            }
            TableColumn("Size") { entry in
                Text(entry.kind == .folder ? "—" : (entry.size.map(Format.bytes) ?? "—"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Modified") { entry in
                Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 230)
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            let files = visible.filter { ids.contains($0.id) && $0.kind != .folder }
            if !files.isEmpty {
                Button(files.count == 1 ? "Download" : "Download \(files.count) Files") { download(files, askingWhere: false) }
                Button("Download To…") { download(files, askingWhere: true) }
            }
        } primaryAction: { ids in
            activate(ids)
        }
        .onKeyPress(.return) {
            activate(selection)
            return .handled
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(browse.entries.isEmpty ? "This folder is empty" : "Only hidden items here")
                .font(.system(size: 13, weight: .medium))
            Text("Drop files here to upload them to \(browse.path)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.08))
            .overlay {
                Label("Drop to upload to \(browse.path)", systemImage: "arrow.up.to.line")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: Downloads

    private var downloadsPanel: some View {
        let downloads = model.downloads
        return VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 11, weight: .semibold))
                Spacer()
                if downloads.isBusy {
                    Button("Cancel All") { downloads.cancelAll() }.controlSize(.small)
                } else {
                    Button("Clear") { downloads.clearFinished() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item, cancel: { downloads.cancel(item.id) })
                    }
                }
            }
            .frame(maxHeight: 132)
        }
    }

    // MARK: Bottom bars

    /// Progress of uploads in flight, with the same Cancel All as the popover.
    private var uploadProgress: Double? {
        guard case .uploading(let fraction) = model.activity.menubarState(now: model.now) else { return nil }
        return fraction
    }

    private func uploadStrip(_ fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text(ActivityText.uploadingHeader(model.activity)).font(.system(size: 12))
            ProgressView(value: fraction).frame(maxWidth: 220)
            if let speed = model.activity.speed(now: model.now) {
                Text("\(Format.bytes(Int64(speed)))/s").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel All") { model.cancelAll() }.controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var statusBar: some View {
        HStack {
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Toggle("Show hidden files", isOn: $showsHidden)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var summary: String {
        let folders = visible.filter { $0.kind == .folder }.count
        let others = visible.count - folders
        func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        return "\(plural(folders, "folder")), \(plural(others, "file"))"
    }

    // MARK: Actions

    /// Double-click or Return: open a folder (or a link, which is tried as one), or download the files.
    private func activate(_ ids: Set<RemoteEntry.ID>) {
        let chosen = visible.filter { ids.contains($0.id) }
        if let place = chosen.first(where: { $0.kind != .file }) {
            browse.enter(folderNamed: place.name)
        } else {
            download(chosen, askingWhere: false)
        }
    }

    /// The selected items that can be downloaded: files, and links, which usually point at files.
    private var selectedFiles: [RemoteEntry] {
        visible.filter { selection.contains($0.id) && $0.kind != .folder }
    }

    private func download(_ files: [RemoteEntry], askingWhere: Bool) {
        guard !files.isEmpty else { return }
        let directory: URL
        if askingWhere {
            guard let chosen = Self.chooseDownloadFolder() else { return }
            directory = chosen
        } else {
            directory = Self.downloadsFolder
        }
        model.downloads.download(files, in: browse.path, from: browse, to: directory)
    }

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static let lastFolderKey = "browse.lastDownloadFolder"

    /// Asks where to save, starting from the folder used last time.
    private static func chooseDownloadFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = "Choose where to save the files"
        let last = UserDefaults.standard.string(forKey: lastFolderKey).map { URL(fileURLWithPath: $0) }
        panel.directoryURL = last ?? downloadsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: lastFolderKey)
        return url
    }

    private func drop(_ urls: [URL]) -> Bool {
        guard model.config?.credentialKey == browse.credentialKey else {
            browse.report("The server was changed in Settings. Close this window and open Browse again.")
            return false
        }
        model.upload(urls, toDirectory: browse.path)
        return true
    }

    private static func icon(for entry: RemoteEntry) -> String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .file: "doc"
        case .link: "arrow.turn.up.right"
        }
    }
}

/// One download in the Browse window's list.
private struct DownloadRow: View {
    let item: DownloadModel.Item
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if item.state == .downloading, item.totalBytes > 0 {
                    ProgressView(value: item.fraction).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failed = item.state { true } else { false }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .waiting, .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch item.state {
        case .waiting:
            return item.totalBytes > 0 ? "\(Format.bytes(item.totalBytes)) · Waiting" : "Waiting"
        case .downloading:
            if item.totalBytes > 0 { return "\(Format.bytes(item.receivedBytes)) of \(Format.bytes(item.totalBytes))" }
            return Format.bytes(item.receivedBytes)
        case .done(let url):
            return "Saved in \(url.deletingLastPathComponent().lastPathComponent)"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .waiting, .downloading:
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel download")
        case .done(let url):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        case .failed, .cancelled:
            EmptyView()
        }
    }
}
