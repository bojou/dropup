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
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { _ in
            EmptyView()
        } primaryAction: { names in
            openFirst(of: names)
        }
        .onKeyPress(.return) {
            openFirst(of: selection)
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

    /// Opens the first selected folder, or a link, which is tried as a folder.
    private func openFirst(of names: Set<RemoteEntry.ID>) {
        guard let entry = visible.first(where: { names.contains($0.id) }), entry.kind != .file else { return }
        browse.enter(folderNamed: entry.name)
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
