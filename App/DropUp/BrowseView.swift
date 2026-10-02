import AppKit
import SwiftUI
import DropUpCore

/// The Browse window: every folder and file on the server, with drag-and-drop uploads into the folder on screen,
/// downloads, and the everyday changes an FTP app offers (new folder, rename, move, delete).
struct BrowseView: View {
    static let idealSize = CGSize(width: 920, height: 620)
    static let minimumSize = CGSize(width: 700, height: 460)

    let model: AppModel
    let browse: BrowseModel
    @State private var selection = Set<RemoteEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\RemoteEntry.name)]
    @State private var isDropTargeted = false
    /// The breadcrumb step a dragged item is hovering over.
    @State private var crumbTarget: String?

    @State private var renaming: RemoteEntry?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var deleting: [RemoteEntry] = []
    @State private var isConfirmingDelete = false
    @State private var moving: [RemoteEntry] = []
    @State private var isChoosingDestination = false

    @AppStorage("browse.showsHiddenFiles") private var showsHidden = false
    @AppStorage("browse.sortKey") private var storedSortKey = RemoteEntry.SortKey.name.rawValue
    @AppStorage("browse.sortAscending") private var storedAscending = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .alert("New Folder", isPresented: $isCreatingFolder) {
                    TextField("Name", text: $newFolderName)
                    Button("Create") { browse.makeFolder(named: newFolderName) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Create a folder inside \(browse.path).")
                }
            Divider()
            content
                .alert("Rename", isPresented: $isRenaming) {
                    TextField("Name", text: $renameText)
                    Button("Rename") { if let target = renaming { browse.rename(target, to: renameText) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Enter a new name for “\(renaming?.name ?? "")”.")
                }
            if !model.downloads.items.isEmpty {
                Divider()
                downloadsPanel
            }
            if let progress = uploadProgress {
                Divider()
                uploadStrip(progress)
            }
            if let operation = browse.operation {
                Divider()
                operationStrip(operation)
            }
            Divider()
            statusBar
                .alert(Text(deleteTitle), isPresented: $isConfirmingDelete) {
                    Button("Delete", role: .destructive) { browse.delete(deleting) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(deleteMessage)
                }
        }
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height, maxHeight: .infinity
        )
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: browse.path) } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { dropHighlight } }
        .background(shortcuts)
        .navigationTitle(browse.path == "/" ? browse.serverName : (browse.path as NSString).lastPathComponent)
        .onAppear {
            restoreSort()
            browse.start()
        }
        .onChange(of: browse.path) { selection = [] }
        .onChange(of: browse.entries) { applySelectionRequest() }
        .onChange(of: sortOrder) { storeSort() }
        .sheet(isPresented: $isChoosingDestination) {
            MoveToSheet(
                browse: browse,
                items: moving,
                choose: { destination in
                    isChoosingDestination = false
                    browse.move(moving, to: destination)
                },
                cancel: { isChoosingDestination = false }
            )
        }
    }

    // MARK: What is shown

    private var visible: [RemoteEntry] {
        let shown = showsHidden ? browse.entries : browse.entries.filter { !$0.isHidden }
        return RemoteEntry.sorted(shown, by: sortKey, ascending: sortAscending)
    }

    private var selectedEntries: [RemoteEntry] {
        visible.filter { selection.contains($0.id) }
    }

    private var sortKey: RemoteEntry.SortKey {
        let path = sortOrder.first?.keyPath
        if path == (\RemoteEntry.sortSize as PartialKeyPath<RemoteEntry>) { return .size }
        if path == (\RemoteEntry.sortDate as PartialKeyPath<RemoteEntry>) { return .modified }
        return .name
    }

    private var sortAscending: Bool { sortOrder.first?.order != .reverse }

    private func restoreSort() {
        let order: SortOrder = storedAscending ? .forward : .reverse
        switch RemoteEntry.SortKey(rawValue: storedSortKey) ?? .name {
        case .name: sortOrder = [KeyPathComparator(\RemoteEntry.name, order: order)]
        case .size: sortOrder = [KeyPathComparator(\RemoteEntry.sortSize, order: order)]
        case .modified: sortOrder = [KeyPathComparator(\RemoteEntry.sortDate, order: order)]
        }
    }

    private func storeSort() {
        storedSortKey = sortKey.rawValue
        storedAscending = sortAscending
    }

    /// Selects what the last change produced (the new folder, the renamed item) once the listing has caught up.
    private func applySelectionRequest() {
        guard let request = browse.selectionRequest else { return }
        browse.selectionRequest = nil
        let present = Set(visible.map(\.id))
        selection = request.intersection(present)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { browse.goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 24)
                }
                .disabled(!browse.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
                .accessibilityLabel("Back")
                Button { browse.goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 24)
                }
                .disabled(!browse.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
                .accessibilityLabel("Forward")
            }

            breadcrumb

            if browse.isLoading { ProgressView().controlSize(.small) }

            Button { browse.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload this folder")
            .accessibilityLabel("Reload")

            Divider().frame(height: 18)

            Button { startNewFolder() } label: {
                Image(systemName: "folder.badge.plus").frame(width: 24, height: 22)
            }
            .disabled(browse.isBusy)
            .help("New folder")
            .accessibilityLabel("New Folder")

            Button { download(selectedEntries, askingWhere: false) } label: {
                Image(systemName: "arrow.down.circle").frame(width: 24, height: 22)
            }
            .disabled(selection.isEmpty)
            .help("Save the selected items to your Downloads folder")
            .accessibilityLabel("Download")

            Button { askToDelete(selectedEntries) } label: {
                Image(systemName: "trash").frame(width: 24, height: 22)
            }
            .disabled(selection.isEmpty || browse.isBusy)
            .help("Delete the selected items")
            .accessibilityLabel("Delete")
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
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(crumbTarget == step.path ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .foregroundStyle(step.path == browse.path ? Color.primary : Color.secondary)
                    .fontWeight(step.path == browse.path ? .semibold : .regular)
                    .help(step.path)
                    // Dropping on a step moves dragged items there, or uploads dragged files there.
                    .dropDestination(for: String.self) { texts, _ in
                        moveDropped(texts, toFolder: step.path)
                        return !texts.isEmpty
                    } isTargeted: { targeted in
                        if targeted { crumbTarget = step.path } else if crumbTarget == step.path { crumbTarget = nil }
                    }
                    .dropDestination(for: URL.self) { urls, _ in drop(urls, into: step.path) }
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
                banner(error, icon: "exclamationmark.triangle.fill", tint: .red) {
                    Button("Try Again") { browse.reload() }.controlSize(.small)
                }
            }
            if let problem = browse.problem {
                banner(problem, icon: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("OK") { browse.dismissProblem() }.controlSize(.small)
                }
            }
            if visible.isEmpty && !browse.isLoading {
                if browse.error == nil { emptyFolder } else { Spacer() }
            } else {
                table
            }
        }
    }

    private func banner<Trailing: View>(
        _ text: String,
        icon: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(0.08))
            Divider()
        }
    }

    private var table: some View {
        Table(of: RemoteEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: Self.icon(for: entry))
                        .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
                }
                .opacity(isCut(entry) ? 0.5 : 1)
            }
            TableColumn("Size", value: \.sortSize) { entry in
                Text(entry.kind == .folder ? "—" : (entry.size.map(Format.bytes) ?? "—"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Modified", value: \.sortDate) { entry in
                Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 230)
        } rows: {
            ForEach(visible) { entry in
                TableRow(entry)
                    .draggable(dragText(for: entry))
                    // Dropping dragged items on a folder moves them into it; dropping files from the Mac uploads them into it.
                    .dropDestination(for: String.self) { texts in
                        guard entry.kind == .folder else { return }
                        moveDropped(texts, toFolder: RemotePath.appending(entry.name, to: browse.path))
                    }
                    .dropDestination(for: URL.self) { urls in
                        _ = drop(urls, into: entry.kind == .folder ? RemotePath.appending(entry.name, to: browse.path) : browse.path)
                    }
            }
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            activate(ids)
        }
        .onKeyPress(.return) {
            guard selection.count == 1, let entry = selectedEntries.first else { return .ignored }
            startRename(entry)
            return .handled
        }
        .onKeyPress(.delete) {
            guard !selection.isEmpty else { return .ignored }
            askToDelete(selectedEntries)
            return .handled
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<RemoteEntry.ID>) -> some View {
        let chosen = visible.filter { ids.contains($0.id) }
        if chosen.isEmpty {
            Button("New Folder") { startNewFolder() }
            if browse.clipboard != nil {
                Button("Paste") { browse.paste() }
            }
        } else {
            if chosen.count == 1, chosen[0].kind != .file {
                Button("Open") { activate(ids) }
            }
            Button(chosen.count == 1 ? "Download" : "Download \(chosen.count) Items") { download(chosen, askingWhere: false) }
            Button("Download To…") { download(chosen, askingWhere: true) }
            Divider()
            if chosen.count == 1 {
                Button("Rename…") { startRename(chosen[0]) }
            }
            Button("Cut") { browse.cut(chosen) }
            if browse.clipboard != nil, chosen.count == 1, chosen[0].kind == .folder {
                Button("Paste Into “\(chosen[0].name)”") { browse.paste(into: chosen[0].name) }
            }
            Button("Move To…") { startMove(chosen) }
            Divider()
            Button("New Folder") { startNewFolder() }
            Button("Delete…", role: .destructive) { askToDelete(chosen) }
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
        .contextMenu {
            Button("New Folder") { startNewFolder() }
            if browse.clipboard != nil {
                Button("Paste") { browse.paste() }
            }
        }
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

    /// Keyboard shortcuts for things the toolbar doesn't show. The buttons are invisible but still answer their keys.
    private var shortcuts: some View {
        Group {
            Button("Enclosing Folder") { browse.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(browse.path == "/")
            Button("Open") { activate(selection) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(selection.isEmpty)
            Button("Cut") { browse.cut(selectedEntries) }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(selection.isEmpty)
            Button("Paste") { browse.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(browse.clipboard == nil)
            Button("Delete") { askToDelete(selectedEntries) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection.isEmpty)
            Button("New Folder") { startNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// A move, rename, new folder or delete that is running.
    private func operationStrip(_ operation: BrowseModel.Operation) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(operation.title).font(.system(size: 12))
            if let count = operation.count, count > 0 {
                Text("\(count) removed").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if operation.canCancel {
                Button("Stop") { browse.cancelOperation() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            if let clipboard = browse.clipboard {
                Label("\(clipboard.entries.count) cut. Open a folder and choose Paste to move.", systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Clear") { browse.cut([]) }.controlSize(.mini).buttonStyle(.link)
            }
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
        let total = "\(plural(folders, "folder")), \(plural(others, "file"))"
        return selection.isEmpty ? total : "\(selection.count) selected · \(total)"
    }

    // MARK: Actions

    /// Double-click or ⌘↓: open a folder (or a link, which is tried as one), or download the files.
    private func activate(_ ids: Set<RemoteEntry.ID>) {
        let chosen = visible.filter { ids.contains($0.id) }
        if let place = chosen.first(where: { $0.kind != .file }) {
            browse.enter(folderNamed: place.name)
        } else {
            download(chosen, askingWhere: false)
        }
    }

    private func isCut(_ entry: RemoteEntry) -> Bool {
        guard let clipboard = browse.clipboard, clipboard.folder == browse.path else { return false }
        return clipboard.entries.contains { $0.name == entry.name }
    }

    private func startNewFolder() {
        guard !browse.isBusy else { return }
        newFolderName = browse.suggestedFolderName
        isCreatingFolder = true
    }

    private func startRename(_ entry: RemoteEntry) {
        guard !browse.isBusy else { return }
        renaming = entry
        renameText = entry.name
        isRenaming = true
    }

    private func startMove(_ entries: [RemoteEntry]) {
        guard !browse.isBusy, !entries.isEmpty else { return }
        moving = entries
        isChoosingDestination = true
    }

    private func askToDelete(_ entries: [RemoteEntry]) {
        guard !browse.isBusy, !entries.isEmpty else { return }
        deleting = entries
        isConfirmingDelete = true
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) items?"
    }

    private var deleteMessage: String {
        let folders = deleting.filter { $0.kind == .folder }.count
        var text = "This can't be undone."
        if folders > 0 {
            text = (folders == 1 ? "The folder and everything inside it will be deleted. " : "The folders and everything inside them will be deleted. ") + text
        }
        return text
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

    /// Files dragged in from the Mac go to `folder` on the server.
    private func drop(_ urls: [URL], into folder: String) -> Bool {
        guard model.config?.credentialKey == browse.credentialKey else {
            browse.report("The server was changed in Settings. Close this window and open Browse again.")
            return false
        }
        model.upload(urls, toDirectory: folder)
        return true
    }

    // MARK: Dragging items inside the window

    private func dragText(for entry: RemoteEntry) -> String {
        EntryDrag(server: browse.credentialKey, folder: browse.path, name: entry.name, isFolder: entry.kind == .folder).text
    }

    /// Moves what was dragged into `destination`. Dragging one of several selected rows takes the whole selection along.
    private func moveDropped(_ texts: [String], toFolder destination: String) {
        guard model.config?.credentialKey == browse.credentialKey else {
            browse.report("The server was changed in Settings. Close this window and open Browse again.")
            return
        }
        var drags = texts.compactMap(EntryDrag.init(text:))
        guard let first = drags.first,
              drags.allSatisfy({ $0.server == browse.credentialKey && $0.folder == first.folder })
        else { return }
        if drags.count == 1, first.folder == browse.path, selection.count > 1, selection.contains(first.name) {
            drags = selectedEntries.map {
                EntryDrag(server: first.server, folder: first.folder, name: $0.name, isFolder: $0.kind == .folder)
            }
        }
        // Dropping items back on the folder they came from changes nothing.
        guard RemotePath.normalizedDirectory(destination) != first.folder else { return }
        // A folder dropped on itself stays where it is.
        drags.removeAll { RemotePath.appending($0.name, to: $0.folder) == RemotePath.normalizedDirectory(destination) }
        guard !drags.isEmpty else { return }
        browse.move(drags.map(\.entry), from: first.folder, to: destination)
    }

    private static func icon(for entry: RemoteEntry) -> String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .file: "doc"
        case .link: "arrow.turn.up.right"
        }
    }
}

private extension RemoteEntry {
    /// Sort keys the table can compare: a missing size or date sorts first.
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
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
