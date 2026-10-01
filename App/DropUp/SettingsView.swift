import SwiftUI
import DropUpCore

struct SettingsView: View {
    let model: AppModel
    @State private var draft = ServerDraft()
    @State private var saved = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServerFormView(draft: $draft)
            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
        .onChange(of: draft) { saved = false }
    }

    private func load() {
        guard let config = model.config else { return }
        draft = ServerDraft(config: config, password: model.password(for: config))
    }

    private func save() {
        draft.showProblems = true
        guard draft.config.isValid else { return }
        do {
            try model.save(draft.config, password: draft.password)
            saveError = nil
            saved = true
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
