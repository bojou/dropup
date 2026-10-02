import AppKit
import DropUpCore

/// After installing from the DMG, offers to eject the disk image that is still mounted and move the
/// downloaded `.dmg` to the Trash. Asked when DropUp starts from somewhere other than the image, and
/// not again for an image the user chose to keep.
@MainActor
enum InstallerCleanup {
    private static let keptKey = "keptInstallerImages"

    static func offerIfNeeded() async {
        let images = (try? await withTimeout(seconds: 3) { await DiskImages.mounted() }) ?? []
        let kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        guard let installer = InstallerImages.cleanupCandidate(
            in: images,
            runningAppURL: Bundle.main.bundleURL,
            dismissed: kept,
            holdsApp: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DropUp.app").path) }
        ) else { return }

        let dmgStillThere = FileManager.default.fileExists(atPath: installer.imageURL.path)
        let volumeName = installer.mountPoints.first?.lastPathComponent ?? "DropUp"

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "DropUp is installed"
        alert.informativeText = dmgStillThere
            ? "Eject the “\(volumeName)” disk image and move \(installer.imageName) to the Trash?"
            : "Eject the “\(volumeName)” disk image?"
        alert.addButton(withTitle: dmgStillThere ? "Eject and Move to Trash" : "Eject")
        alert.addButton(withTitle: "Keep")

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(Array(kept.union([installer.imageURL.path])), forKey: keptKey)
            return
        }

        for mountPoint in installer.mountPoints {
            if !(await DiskImages.detach(mountPoint: mountPoint)) {
                showFailure("Couldn’t eject “\(volumeName)”. Something may still be using it.")
                return
            }
        }
        if dmgStillThere {
            do {
                try FileManager.default.trashItem(at: installer.imageURL, resultingItemURL: nil)
            } catch {
                showFailure("The disk image was ejected, but \(installer.imageName) couldn’t be moved to the Trash: \(error.localizedDescription)")
            }
        }
    }

    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t finish cleaning up"
        alert.informativeText = message
        alert.runModal()
    }
}
