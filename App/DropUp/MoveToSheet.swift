import SwiftUI
import DropUpCore

/// A small folder chooser for "Move To…": pick any folder on the server and move the chosen items into it.
struct MoveToSheet: View {
    let browse: BrowseModel
    let items: [RemoteEntry]
    /// The folder the items are in now.
    let source: String
    let choose: (String) -> Void
    let cancel: () -> Void

    @State private var path: String
    @State private var folders: [RemoteEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var generation = 0

    init(browse: BrowseModel, items: [RemoteEntry], choose: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.browse = browse
        self.items = items
        self.source = browse.path
        self.choose = choose
        self.cancel = cancel
        _path = State(initialValue: browse.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(items.count == 1 ? "Move “\(items[0].name)” to…" : "Move \(items.count) items to…")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Open a folder, then choose Move Here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            pathBar
            Divider()
            list
            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Move Here") { choose(path) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMoveHere)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
        .onAppear { load(path) }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                load(RemotePath.parent(of: path))
            } label: {
                Image(systemName: "chevron.left").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(path == "/")
            .accessibilityLabel("Go up one folder")
            Text(path).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    @ViewBuilder
    private var list: some View {
        if let error {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
        } else if folders.isEmpty && !isLoading {
            Text("No folders here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(folders) { folder in
                        let blocked = isBeingMoved(folder)
                        Button {
                            load(RemotePath.appending(folder.name, to: path))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").foregroundStyle(blocked ? Color.secondary : Color.accentColor)
                                Text(folder.name).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(blocked)
                        .foregroundStyle(blocked ? Color.secondary : Color.primary)
                    }
                }
            }
        }
    }

    /// A folder that is itself being moved can't be opened as a destination.
    private func isBeingMoved(_ folder: RemoteEntry) -> Bool {
        path == source && items.contains { $0.kind == .folder && $0.name == folder.name }
    }

    private var canMoveHere: Bool {
        guard !isLoading, error == nil, path != source else { return false }
        for item in items where item.kind == .folder {
            let moved = RemotePath.appending(item.name, to: source)
            if path == moved || path.hasPrefix(moved + "/") { return false }
        }
        return true
    }

    private func load(_ target: String) {
        generation += 1
        let ticket = generation
        isLoading = true
        error = nil
        Task {
            do {
                let listing = try await browse.folders(in: target)
                guard ticket == generation else { return }
                path = RemotePath.normalizedDirectory(target)
                folders = listing
                isLoading = false
            } catch {
                guard ticket == generation else { return }
                isLoading = false
                self.error = ServerBrowser.message(for: error)
            }
        }
    }
}
