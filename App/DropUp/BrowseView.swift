import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DropUpCore

/// The Browse window: every folder and file on the server, with drag-and-drop uploads into the folder on screen,
/// downloads, and the everyday changes an FTP app offers (new folder, rename, move, copy, delete), with Undo and Redo.
///
/// The same view picks the upload folder (Change Folder in the popover): with a browse model in the choose-folder
/// purpose it navigates the same way but offers nothing that changes or transfers anything, and ends in a
/// "Use This Folder" button.
struct BrowseView: View {
    static let idealSize = CGSize(width: 920, height: 620)
    static let minimumSize = CGSize(width: 700, height: 460)
    /// Choosing a folder needs less room than working in one.
    static let chooserSize = CGSize(width: 820, height: 560)

    let model: AppModel
    let browse: BrowseModel
    /// Closes the window once a folder has been chosen (or the choice was cancelled). Only used when choosing a folder.
    var finishChoosing: (() -> Void)?
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
    /// Columns view: the folders above the one on screen are shown beside it, as in Finder's column view.
    @AppStorage("browse.showsParentColumns") private var showsColumns = false

    private static let columnWidth: CGFloat = 170
    private static let widestStrip: CGFloat = 345
    /// How faint files look when the window only picks a folder.
    private static let contextOpacity = 0.45

    /// False when this window only picks the upload folder: nothing is renamed, moved, deleted, uploaded or downloaded.
    private var canEdit: Bool { browse.canChange }

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
            if canEdit, !model.downloads.items.isEmpty {
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
            if !canEdit {
                Divider()
                chooserBar
            }
        }
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height, maxHeight: .infinity
        )
        .when(canEdit) { content in
            content.dropDestination(for: URL.self) { urls, _ in drop(urls, into: browse.path) } isTargeted: { isDropTargeted = $0 }
        }
        .overlay { if isDropTargeted { dropHighlight } }
        .background(shortcuts)
        .navigationTitle(title)
        .onAppear {
            restoreSort()
            browse.setShowsParents(showsColumns)
            browse.start()
        }
        .onChange(of: showsColumns) { browse.setShowsParents(showsColumns) }
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

    private var title: String {
        if !canEdit { return "Choose Upload Folder" }
        return browse.path == "/" ? browse.serverName : (browse.path as NSString).lastPathComponent
    }

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

            if canEdit {
                Divider().frame(height: 18)

                Button { browse.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 22)
                }
                .disabled(!browse.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help(browse.undoTitle.map { "Undo \($0)" } ?? "Nothing to undo")
                .accessibilityLabel("Undo")

                Button { browse.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 24, height: 22)
                }
                .disabled(!browse.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help(browse.redoTitle.map { "Redo \($0)" } ?? "Nothing to redo")
                .accessibilityLabel("Redo")

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

            Divider().frame(height: 18)

            Picker("View", selection: $showsColumns) {
                Image(systemName: "list.bullet").tag(false).help("As list (⌘2)")
                Image(systemName: "rectangle.split.3x1").tag(true).help("With the folders above shown as columns (⌘3)")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 64)
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
                    .when(canEdit) { crumb in
                        crumb
                            .dropDestination(for: String.self) { texts, _ in
                                moveDropped(texts, toFolder: step.path)
                                return !texts.isEmpty
                            } isTargeted: { targeted in
                                if targeted { crumbTarget = step.path } else if crumbTarget == step.path { crumbTarget = nil }
                            }
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, into: step.path) }
                    }
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
            HStack(spacing: 0) {
                if showsColumns, !browse.parentColumns.isEmpty {
                    parentColumns
                    Divider()
                }
                if visible.isEmpty && !browse.isLoading {
                    if browse.error == nil { emptyFolder } else { Spacer() }
                } else {
                    table
                }
            }
        }
    }

    // MARK: Columns view

    /// The folders above the one on screen, outermost on the left, each with the folder that leads down highlighted.
    /// Clicking a folder opens it, and dragging items onto one moves them there.
    private var parentColumns: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(browse.parentColumns) { column in
                    parentColumn(column)
                    Divider()
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .frame(width: min(CGFloat(browse.parentColumns.count) * (Self.columnWidth + 1), Self.widestStrip))
    }

    private func parentColumn(_ column: BrowseModel.ParentColumn) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let entries = column.entries {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(RemoteEntry.sorted(showsHidden ? entries : entries.filter { !$0.isHidden })) { entry in
                            parentRow(entry, in: column)
                                .id(entry.name)
                        }
                    }
                    .padding(4)
                } else if let error = column.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small).padding(14).frame(maxWidth: .infinity)
                }
            }
            .onAppear { proxy.scrollTo(column.childName, anchor: .center) }
            .onChange(of: column.childName) { proxy.scrollTo(column.childName, anchor: .center) }
            .onChange(of: column.entries) { proxy.scrollTo(column.childName, anchor: .center) }
        }
        .frame(width: Self.columnWidth)
    }

    private func parentRow(_ entry: RemoteEntry, in column: BrowseModel.ParentColumn) -> some View {
        let folderPath = RemotePath.appending(entry.name, to: column.path)
        let leadsDown = entry.name == column.childName
        return HStack(spacing: 6) {
            Image(systemName: Self.icon(for: entry))
                .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if entry.kind != .file {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(leadsDown ? Color.accentColor.opacity(0.22) : (crumbTarget == folderPath ? Color.accentColor.opacity(0.12) : Color.clear))
        )
        .contentShape(Rectangle())
        // When choosing a folder, files are only there for context.
        .opacity(canEdit || entry.kind != .file ? 1 : Self.contextOpacity)
        .onTapGesture { if entry.kind != .file { browse.go(to: folderPath) } }
        .help(folderPath)
        .when(canEdit) { row in
            row
                .dropDestination(for: String.self) { texts, _ in
                    guard entry.kind == .folder else { return false }
                    moveDropped(texts, toFolder: folderPath)
                    return !texts.isEmpty
                } isTargeted: { targeted in
                    if targeted { crumbTarget = folderPath } else if crumbTarget == folderPath { crumbTarget = nil }
                }
                .dropDestination(for: URL.self) { urls, _ in drop(urls, into: entry.kind == .folder ? folderPath : column.path) }
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

    @ViewBuilder
    private var table: some View {
        if canEdit { editableTable } else { chooserTable }
    }

    private var editableTable: some View {
        Table(of: RemoteEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in nameCell(entry) }
            TableColumn("Size", value: \.sortSize) { entry in sizeCell(entry) }
                .width(min: 70, ideal: 90, max: 130)
            TableColumn("Modified", value: \.sortDate) { entry in modifiedCell(entry) }
                .width(min: 120, ideal: 170, max: 230)
        } rows: {
            ForEach(visible) { entry in
                TableRow(entry)
                    // Inside the window a drag carries text that names the item. Dropped on the Mac, it is fetched then.
                    .itemProvider { dragProvider(for: entry) }
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

    /// The same listing with nothing to drag, drop, rename or delete: only folders can be opened.
    private var chooserTable: some View {
        Table(of: RemoteEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in nameCell(entry) }
            TableColumn("Size", value: \.sortSize) { entry in sizeCell(entry) }
                .width(min: 70, ideal: 90, max: 130)
            TableColumn("Modified", value: \.sortDate) { entry in modifiedCell(entry) }
                .width(min: 120, ideal: 170, max: 230)
        } rows: {
            ForEach(visible) { entry in
                TableRow(entry)
            }
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            activate(ids)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            activate(selection)
            return .handled
        }
    }

    private func nameCell(_ entry: RemoteEntry) -> some View {
        Label {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: Self.icon(for: entry))
                .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
        }
        .opacity(isCut(entry) ? 0.5 : (canEdit || entry.kind != .file ? 1 : Self.contextOpacity))
    }

    private func sizeCell(_ entry: RemoteEntry) -> some View {
        Text(entry.kind == .folder ? "—" : (entry.size.map(Format.bytes) ?? "—"))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(canEdit || entry.kind != .file ? 1 : Self.contextOpacity)
    }

    private func modifiedCell(_ entry: RemoteEntry) -> some View {
        Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
            .foregroundStyle(.secondary)
            .opacity(canEdit || entry.kind != .file ? 1 : Self.contextOpacity)
    }

    @ViewBuilder
    private func menu(for ids: Set<RemoteEntry.ID>) -> some View {
        let chosen = visible.filter { ids.contains($0.id) }
        if !canEdit {
            if chosen.count == 1, chosen[0].kind != .file {
                Button("Open") { activate(ids) }
            }
        } else if chosen.isEmpty {
            Button("New Folder") { startNewFolder() }
            Button("Paste") { browse.paste() }
                .disabled(browse.clipboard == nil)
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
            Button("Copy") { browse.copyToClipboard(chosen) }
            Button(chosen.count == 1 ? "Duplicate" : "Duplicate \(chosen.count) Items") { browse.duplicate(chosen) }
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
            if canEdit {
                Text("Drop files here to upload them to \(browse.path)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .when(canEdit) { empty in
            empty.contextMenu {
                Button("New Folder") { startNewFolder() }
                Button("Paste") { browse.paste() }
                    .disabled(browse.clipboard == nil)
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
            if canEdit {
                Button("Cut") { browse.cut(selectedEntries) }
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("Copy") { browse.copyToClipboard(selectedEntries) }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("Duplicate") { browse.duplicate(selectedEntries) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(selection.isEmpty || browse.isBusy)
                Button("Paste") { browse.paste() }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(browse.clipboard == nil)
                Button("Delete") { askToDelete(selectedEntries) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("New Folder") { startNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            Button("As List") { showsColumns = false }
                .keyboardShortcut("2", modifiers: .command)
            Button("As Columns") { showsColumns = true }
                .keyboardShortcut("3", modifiers: .command)
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
        guard canEdit, case .uploading(let fraction) = model.activity.menubarState(now: model.now) else { return nil }
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

    /// A move, copy, rename, new folder or delete that is running.
    private func operationStrip(_ operation: BrowseModel.Operation) -> some View {
        HStack(spacing: 10) {
            if let fraction = operation.fraction {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(operation.title).font(.system(size: 12))
            if let detail = operation.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            if canEdit, let clipboard = browse.clipboard {
                Label(
                    clipboard.mode == .cut
                        ? "\(clipboard.entries.count) cut. Open a folder and choose Paste to move."
                        : "\(clipboard.entries.count) copied. Open a folder and choose Paste to copy.",
                    systemImage: clipboard.mode == .cut ? "scissors" : "doc.on.doc"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Button("Clear") { browse.clearClipboard() }.controlSize(.mini).buttonStyle(.link)
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

    /// The end of choosing a folder: where uploads will go, and the button that makes it so.
    private var chooserBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uploads will go to").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(browse.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Cancel") { finishChoosing?() }
                .keyboardShortcut(.cancelAction)
            Button("Use This Folder") { useThisFolder() }
                .buttonStyle(.borderedProminent)
                .help("Send the next uploads to \(browse.path)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Saves the folder on screen as the upload folder. It applies from the next upload; uploads already dropped, running or waiting, finish where they were going.
    private func useThisFolder() {
        guard model.config?.credentialKey == browse.credentialKey else {
            browse.report("The server was changed in Settings. Close this window and open Change Folder again.")
            return
        }
        do {
            try model.changeRemoteDirectory(to: browse.path)
        } catch {
            browse.report("Couldn’t save: \(error.localizedDescription)")
            return
        }
        finishChoosing?()
    }

    // MARK: Actions

    /// Double-click or ⌘↓: open a folder (or a link, which is tried as one), or download the files.
    /// When choosing a folder, files just stay where they are.
    private func activate(_ ids: Set<RemoteEntry.ID>) {
        let chosen = visible.filter { ids.contains($0.id) }
        if let place = chosen.first(where: { $0.kind != .file }) {
            browse.enter(folderNamed: place.name)
        } else if canEdit {
            download(chosen, askingWhere: false)
        }
    }

    private func isCut(_ entry: RemoteEntry) -> Bool {
        guard let clipboard = browse.clipboard, clipboard.mode == .cut, clipboard.folder == browse.path else { return false }
        return clipboard.entries.contains { $0.name == entry.name }
    }

    private func startNewFolder() {
        guard canEdit, !browse.isBusy else { return }
        newFolderName = browse.suggestedFolderName
        isCreatingFolder = true
    }

    private func startRename(_ entry: RemoteEntry) {
        guard canEdit, !browse.isBusy else { return }
        renaming = entry
        renameText = entry.name
        isRenaming = true
    }

    private func startMove(_ entries: [RemoteEntry]) {
        guard canEdit, !browse.isBusy, !entries.isEmpty else { return }
        moving = entries
        isChoosingDestination = true
    }

    private func askToDelete(_ entries: [RemoteEntry]) {
        guard canEdit, !browse.isBusy, !entries.isEmpty else { return }
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
        guard canEdit, !files.isEmpty else { return }
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
        guard canEdit else { return false }
        guard model.config?.credentialKey == browse.credentialKey else {
            browse.report("The server was changed in Settings. Close this window and open Browse again.")
            return false
        }
        model.upload(urls, toDirectory: folder)
        return true
    }

    // MARK: Dragging items

    private func dragText(for entry: RemoteEntry) -> String {
        EntryDrag(server: browse.credentialKey, folder: browse.path, name: entry.name, isFolder: entry.kind == .folder).text
    }

    /// What a dragged row carries. Inside this window it is text naming the item, for moves. For the Finder and other
    /// apps it is a promise of the file or folder: nothing is downloaded until something is dropped and asks for it.
    private func dragProvider(for entry: RemoteEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        provider.registerObject(dragText(for: entry) as NSString, visibility: .ownProcess)
        // A link can't be fetched safely (it may lead anywhere), so it only moves within the window.
        guard entry.kind != .link else { return provider }

        let isFolder = entry.kind == .folder
        let item = RemoteDownload(remotePath: RemotePath.appending(entry.name, to: browse.path), size: entry.size, isFolder: isFolder)
        let config = browse.config
        let password = browse.password
        let export = model.dragExport
        let fileType = (UTType(filenameExtension: (entry.name as NSString).pathExtension)).flatMap { $0.isDynamic ? nil : $0 } ?? .data
        provider.registerFileRepresentation(
            forTypeIdentifier: (isFolder ? UTType.folder : fileType).identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 100)
            let task = Task {
                do {
                    let url = try await export.fetch(item, from: config, password: password) { update in
                        progress.completedUnitCount = Int64(update.fraction * 100)
                    }
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    /// Moves what was dragged into `destination`. Dragging one of several selected rows takes the whole selection along.
    private func moveDropped(_ texts: [String], toFolder destination: String) {
        guard canEdit else { return }
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

private extension View {
    /// Applies `transform` only when `condition` holds. The condition must stay the same while the view is on screen.
    @ViewBuilder
    func when<Transformed: View>(_ condition: Bool, _ transform: (Self) -> Transformed) -> some View {
        if condition { transform(self) } else { self }
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
