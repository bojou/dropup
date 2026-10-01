import SwiftUI
import DropUpCore

struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var draft = ServerDraft()
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should your files go?")
                .font(.title2.weight(.semibold))
            Text("Drop any file on the DropUp icon in the menubar and it uploads straight to this server. You can change this later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ServerFormView(draft: $draft)

            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Done", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        draft.showProblems = true
        guard draft.config.isValid else { return }
        do {
            try model.save(draft.config, password: draft.password)
            onFinish()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
