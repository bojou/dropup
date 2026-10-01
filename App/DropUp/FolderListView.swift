import SwiftUI
import DropUpCore

/// A small folder browser: the folders inside `path`, a row to go up, and a way in. Used by onboarding and by Settings' Browse… sheet.
struct FolderListView: View {
    let model: AppModel
    @Binding var path: String
    let draft: ServerDraft
    let folders: FolderBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            Button {
                path = RemotePath.parent(of: path)
                reload()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text(RemotePath.normalizedDirectory(path)).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(RemotePath.normalizedDirectory(path) == "/")
            .accessibilityLabel("Go up one folder")
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if folders.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 14)
                    } else if let error = folders.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else if folders.folders.isEmpty {
                        Text("No folders here")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                    } else {
                        ForEach(folders.folders, id: \.self) { name in
                            Button {
                                path = RemotePath.appending(name, to: path)
                                reload()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear(perform: reload)
    }

    func reload() {
        folders.load(RemotePath.normalizedDirectory(path), draft: draft, using: model.browser)
    }
}
