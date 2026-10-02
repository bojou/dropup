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
                // While a window is open DropUp has a menu bar, and "Settings…" there should open the real window.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}
