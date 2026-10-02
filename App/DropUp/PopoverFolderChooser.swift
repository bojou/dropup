import SwiftUI
import DropUpCore

/// The popover's second page: pick another folder on the server for future uploads, without opening Settings.
struct PopoverFolderChooser: View {
    let model: AppModel
    // Set on appear, because the password comes from the Keychain and the folder list needs it.
    @State private var draft: ServerDraft?
    @State private var path = "/"
    @State private var folders = FolderBrowserModel()
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Upload folder").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 4)

            Group {
                if let draft {
                    FolderListView(model: model, path: $path, draft: draft, folders: folders)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 220)

            Text(RemotePath.normalizedDirectory(path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.isChoosingFolder = false }
                Button("Use This Folder", action: choose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil)
            }
        }
        .padding(10)
        .frame(width: 336)
        .onAppear(perform: begin)
        .onDisappear { folders.cancel() }
    }

    private func begin() {
        guard draft == nil else { return }
        guard let config = model.config else {
            model.isChoosingFolder = false
            return
        }
        path = RemotePath.normalizedDirectory(config.remoteDirectory)
        draft = ServerDraft(config: config, password: model.password(for: config))
    }

    private func choose() {
        do {
            try model.changeRemoteDirectory(to: path)
            model.isChoosingFolder = false
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}
