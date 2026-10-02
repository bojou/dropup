import Foundation
import Testing
@testable import DropUpCore

struct InstallerImagesTests {
    // Trimmed from `hdiutil info -plist` on macOS.
    static let sample = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>framework</key><string>654.40.2</string>
      <key>images</key>
      <array>
        <dict>
          <key>image-path</key><string>/Users/me/Downloads/DropUp-0.1.1.dmg</string>
          <key>image-type</key><string>disk image</string>
          <key>system-entities</key>
          <array>
            <dict>
              <key>content-hint</key><string>GUID_partition_scheme</string>
              <key>dev-entry</key><string>/dev/disk4</string>
            </dict>
            <dict>
              <key>content-hint</key><string>Apple_HFS</string>
              <key>dev-entry</key><string>/dev/disk4s1</string>
              <key>mount-point</key><string>/Volumes/DropUp</string>
            </dict>
          </array>
        </dict>
        <dict>
          <key>image-path</key><string>/Users/me/Downloads/Other.dmg</string>
          <key>system-entities</key>
          <array>
            <dict>
              <key>dev-entry</key><string>/dev/disk5</string>
              <key>mount-point</key><string>/Volumes/Other</string>
            </dict>
          </array>
        </dict>
        <dict>
          <key>image-path</key><string>/Users/me/Downloads/Unmounted.dmg</string>
          <key>system-entities</key>
          <array><dict><key>dev-entry</key><string>/dev/disk6</string></dict></array>
        </dict>
      </array>
    </dict>
    </plist>
    """.utf8)

    let installed = URL(fileURLWithPath: "/Applications/DropUp.app")
    let dropUpImage = MountedImage(
        imageURL: URL(fileURLWithPath: "/Users/me/Downloads/DropUp-0.1.1.dmg"),
        mountPoints: [URL(fileURLWithPath: "/Volumes/DropUp", isDirectory: true)]
    )

    private func candidate(
        _ images: [MountedImage],
        running: URL? = nil,
        dismissed: Set<String> = [],
        holdsApp: Bool = true
    ) -> MountedImage? {
        InstallerImages.cleanupCandidate(in: images, runningAppURL: running ?? installed, dismissed: dismissed) { _ in holdsApp }
    }

    @Test func parsesMountedImagesAndSkipsUnmountedOnes() {
        let images = InstallerImages.parse(Self.sample)
        #expect(images.count == 2)
        #expect(images[0] == dropUpImage)
        #expect(images[1].imageName == "Other.dmg")
    }

    @Test func garbageParsesToNothing() {
        #expect(InstallerImages.parse(Data("not a plist".utf8)).isEmpty)
        #expect(InstallerImages.parse(Data()).isEmpty)
    }

    @Test func offersTheMountedDropUpInstaller() {
        let images = InstallerImages.parse(Self.sample)
        #expect(candidate(images) == dropUpImage)
    }

    @Test func ignoresImagesNotNamedLikeDropUp() {
        let other = MountedImage(imageURL: URL(fileURLWithPath: "/Users/me/Backup.dmg"),
                                 mountPoints: [URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)])
        #expect(candidate([other]) == nil)
    }

    @Test func ignoresVolumesWithoutTheApp() {
        #expect(candidate([dropUpImage], holdsApp: false) == nil)
    }

    @Test func staysQuietWhenRunningFromTheImage() {
        let fromImage = URL(fileURLWithPath: "/Volumes/DropUp/DropUp.app")
        #expect(candidate([dropUpImage], running: fromImage) == nil)
    }

    @Test func staysQuietAfterKeep() {
        let dismissed: Set<String> = [dropUpImage.imageURL.path]
        #expect(candidate([dropUpImage], dismissed: dismissed) == nil)
        // A newer download has a different file name, so it is offered again.
        let newer = MountedImage(imageURL: URL(fileURLWithPath: "/Users/me/Downloads/DropUp-0.2.0.dmg"), mountPoints: dropUpImage.mountPoints)
        #expect(candidate([newer], dismissed: dismissed) == newer)
    }
}
