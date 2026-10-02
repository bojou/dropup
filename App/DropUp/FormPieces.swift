import SwiftUI

/// A small label above a rounded text field, as used in onboarding and Settings.
struct FormField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false

    init(_ label: String, text: Binding<String>, prompt: String = "", secure: Bool = false) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.secure = secure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if secure {
                SecureField("", text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
            }
        }
    }
}
