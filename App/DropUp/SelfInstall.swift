import AppKit
import DropUpCore
import os

/// What the CI install walkthrough sets so the two install dialogs answer themselves: the first button.
/// A person never sets it.
enum AutoConfirm {
    static let environmentKey = "DROPUP_ASSUME_YES"
    static var isOn: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    /// Runs `alert`, or answers it with its first button when the walkthrough is driving.
    @MainActor
    static func confirms(_ alert: NSAlert) -> Bool {
        isOn || alert.runModal() == .alertFirstButtonReturn
    }
}

/// Opening DropUp from inside the disk image installs it: copy to Applications, open that copy, quit.
/// The copy then runs the usual "eject the disk image" question (see `InstallerCleanup`).
@MainActor
enum SelfInstall {
    private static let log = Logger(subsystem: "app.dropup.DropUp", category: "install")
    private static let appName = "DropUp.app"

    /// Cheap check before anything is started: a disk image's volume is under /Volumes.
    static var mightBeOnDiskImage: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Volumes/")
    }

    /// If this copy is running from a mounted disk image and the person agrees, installs it into
    /// Applications and opens the installed copy. Returns true when this copy is about to quit.
    static func offerIfRunningFromDiskImage() async -> Bool {
        let appURL = Bundle.main.bundleURL
        let images = (try? await withTimeout(seconds: 10) { await DiskImages.mounted() }) ?? []
        guard InstallerImages.image(holding: appURL, in: images) != nil else {
            log.notice("on /Volumes but not a disk image; carrying on")
            return false
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       home.appendingPathComponent("Applications", isDirectory: true)]
        let destination: URL
        do {
            destination = try AppInstaller.destination(appName: appName, in: folders)
        } catch {
            log.error("no folder to install into: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let replacing = FileManager.default.fileExists(atPath: destination.path)

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Install DropUp?"
        alert.informativeText = "DropUp is running from a disk image. Install it in \(destination.deletingLastPathComponent().lastPathComponent) so it stays on your Mac after you eject the disk image."
            + (replacing ? " This replaces the DropUp that is already there." : "")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        guard AutoConfirm.confirms(alert) else {
            log.notice("install declined; running from the disk image")
            return false
        }

        do {
            await quitRunningCopy(at: destination)
            try AppInstaller.install(source: appURL, destination: destination, discardExisting: { existing in
                try FileManager.default.trashItem(at: existing, resultingItemURL: nil)
            })
            log.notice("installed to \(destination.path, privacy: .public)")
            try await open(destination)
        } catch {
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn’t install DropUp"
            failure.informativeText = "\(error.localizedDescription) You can drag DropUp into the Applications folder instead."
            if !AutoConfirm.isOn { failure.runModal() }
            return false
        }

        NSApp.terminate(nil)
        return true
    }

    /// An installed DropUp that is running can't be replaced, so ask it to quit and wait briefly.
    private static func quitRunningCopy(at destination: URL) async {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
        for app in running { app.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Opens the installed copy as its own process, because the one on the disk image has the same identity.
    private static func open(_ appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        if AutoConfirm.isOn { configuration.environment = [AutoConfirm.environmentKey: "1"] }
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
