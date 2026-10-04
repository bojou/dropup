import SwiftUI

@main
struct DropUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything is AppKit-owned: the menubar icon and drop panel (SwiftUI's MenuBarExtra can't take
        // files dragged onto the icon) and the Onboarding and Settings windows (see WindowCoordinator).
        // The app still needs one scene, so this one is empty.
        Settings { EmptyView() }
            .commands {
                // The Settings scene adds its own "Settings…" item (⌘,), which would open the empty scene above.
                // Make it open the real window instead.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}
