import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import DropUpCore

struct UploadActivityTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func queue(_ activity: inout UploadActivity, _ name: String, bytes: Int64, at now: Date) -> UUID {
        let id = UUID()
        activity.apply(.queued(id: id, fileName: name, totalBytes: bytes), now: now)
        return id
    }

    @Test func followsAFileThroughItsLife() {
        var activity = UploadActivity()
        let id = queue(&activity, "photo.png", bytes: 100, at: t0)
        #expect(activity.items.first?.state == .waiting)
        #expect(activity.menubarState(now: t0) == .uploading(fraction: 0))

        activity.apply(.started(id: id), now: t0)
        activity.apply(.progress(id: id, UploadProgress(bytesSent: 25, totalBytes: 100)), now: t0)
        #expect(activity.items.first?.state == .uploading)
        #expect(activity.menubarState(now: t0) == .uploading(fraction: 0.25))

        activity.apply(.succeeded(id: id, remotePath: "/drops/photo.png"), now: t0.addingTimeInterval(1))
        #expect(activity.items.first?.state == .succeeded(remotePath: "/drops/photo.png"))
        #expect(activity.menubarState(now: t0.addingTimeInterval(1.5)) == .succeeded)
        #expect(activity.menubarState(now: t0.addingTimeInterval(4)) == .idle)
    }

    @Test func ringNeverGoesBackwardsWhenAFileFinishes() {
        var activity = UploadActivity()
        let a = queue(&activity, "a", bytes: 100, at: t0)
        let b = queue(&activity, "b", bytes: 300, at: t0)
        activity.apply(.started(id: a), now: t0)
        activity.apply(.progress(id: a, UploadProgress(bytesSent: 100, totalBytes: 100)), now: t0)
        let before = activity.overallFraction
        activity.apply(.succeeded(id: a, remotePath: "/a"), now: t0)
        activity.apply(.started(id: b), now: t0)
        #expect(activity.overallFraction == before)
        #expect(before == 0.25)
        activity.apply(.progress(id: b, UploadProgress(bytesSent: 150, totalBytes: 300)), now: t0)
        #expect(activity.overallFraction == 0.625)
    }

    @Test func activeItemsKeepDropOrderAndFinishedGoBelowNewestFirst() {
        var activity = UploadActivity()
        let a = queue(&activity, "a", bytes: 1, at: t0)
        let b = queue(&activity, "b", bytes: 1, at: t0)
        let c = queue(&activity, "c", bytes: 1, at: t0)
        activity.apply(.succeeded(id: a, remotePath: "/a"), now: t0)
        activity.apply(.succeeded(id: b, remotePath: "/b"), now: t0.addingTimeInterval(1))
        #expect(activity.items.map(\.fileName) == ["c", "b", "a"])
        let d = queue(&activity, "d", bytes: 1, at: t0.addingTimeInterval(2))
        #expect(activity.items.map(\.fileName) == ["c", "d", "b", "a"])
        _ = (c, d)
    }

    @Test func failureLightsTheIconUntilSeen() {
        var activity = UploadActivity()
        let id = queue(&activity, "a", bytes: 1, at: t0)
        activity.apply(.failed(id: id, .transfer("Connection lost")), now: t0)
        #expect(activity.items.first?.state == .failed(message: "Connection lost"))
        #expect(activity.menubarState(now: t0.addingTimeInterval(60)) == .failed)
        activity.markFailuresSeen()
        #expect(activity.menubarState(now: t0.addingTimeInterval(60)) == .idle)
        #expect(activity.items.count == 1)
    }

    @Test func aNewBatchRestartsTheRing() {
        var activity = UploadActivity()
        let a = queue(&activity, "a", bytes: 100, at: t0)
        activity.apply(.succeeded(id: a, remotePath: "/a"), now: t0)
        let b = queue(&activity, "b", bytes: 100, at: t0.addingTimeInterval(10))
        activity.apply(.progress(id: b, UploadProgress(bytesSent: 50, totalBytes: 100)), now: t0.addingTimeInterval(10))
        #expect(activity.overallFraction == 0.5)
    }

    @Test func cancelledFilesCountAsFinishedAndDontLightTheIcon() {
        var activity = UploadActivity()
        let id = queue(&activity, "a", bytes: 10, at: t0)
        activity.apply(.cancelled(id: id), now: t0)
        #expect(activity.items.first?.state == .cancelled)
        #expect(!activity.isBusy)
        #expect(activity.menubarState(now: t0) == .idle)
    }

    @Test func clearAndTrim() {
        var activity = UploadActivity()
        var ids: [UUID] = []
        for index in 0..<5 {
            let id = queue(&activity, "f\(index)", bytes: 1, at: t0)
            ids.append(id)
            activity.apply(.succeeded(id: id, remotePath: "/f"), now: t0.addingTimeInterval(Double(index)))
        }
        let failing = queue(&activity, "bad", bytes: 1, at: t0)
        activity.apply(.failed(id: failing, .unsupportedItem), now: t0.addingTimeInterval(9))
        activity.trim(toRecent: 3)
        #expect(activity.items.map(\.fileName) == ["bad", "f4", "f3"])
        activity.clearFinished(failuresToo: false)
        #expect(activity.items.map(\.fileName) == ["bad"])
        activity.clearFinished()
        #expect(activity.items.isEmpty)
        #expect(!activity.hasUnseenFailure)
    }

    @Test func uploadsAfterAFailureAreNotMarkedFailed() {
        var activity = UploadActivity()
        let bad = queue(&activity, "bad.zip", bytes: 10, at: t0)
        activity.apply(.failed(id: bad, .unsupportedItem), now: t0)
        #expect(activity.menubarState(now: t0.addingTimeInterval(5)) == .failed)

        // The popover stays closed and the list isn't cleared; the next upload goes through.
        let good = queue(&activity, "good.png", bytes: 10, at: t0.addingTimeInterval(10))
        #expect(activity.menubarState(now: t0.addingTimeInterval(10)) == .uploading(fraction: 0))
        activity.apply(.succeeded(id: good, remotePath: "/good.png"), now: t0.addingTimeInterval(11))
        #expect(activity.menubarState(now: t0.addingTimeInterval(11.5)) == .succeeded)
        #expect(activity.menubarState(now: t0.addingTimeInterval(14)) == .idle)
        // The earlier failure is still in the list for whoever looks.
        #expect(activity.items.map(\.fileName) == ["good.png", "bad.zip"])
    }

    @Test func aFailureInTheBatchWinsOverItsSuccessesInEitherOrder() {
        for failsFirst in [true, false] {
            var activity = UploadActivity()
            let first = queue(&activity, "first", bytes: 1, at: t0)
            let second = queue(&activity, "second", bytes: 1, at: t0)
            let (failing, passing) = failsFirst ? (first, second) : (second, first)
            activity.apply(.failed(id: failing, .unsupportedItem), now: t0.addingTimeInterval(1))
            activity.apply(.succeeded(id: passing, remotePath: "/x"), now: t0.addingTimeInterval(2))
            #expect(activity.menubarState(now: t0.addingTimeInterval(2.5)) == .failed)
            activity.markFailuresSeen()
            #expect(activity.menubarState(now: t0.addingTimeInterval(2.5)) == .succeeded)
        }
    }

    @Test func measuresSpeedOverASlidingWindow() {
        var activity = UploadActivity()
        let id = queue(&activity, "big", bytes: 10_000, at: t0)
        activity.apply(.started(id: id), now: t0)
        #expect(activity.speed(now: t0) == nil)
        activity.apply(.progress(id: id, UploadProgress(bytesSent: 1_000, totalBytes: 10_000)), now: t0.addingTimeInterval(1))
        activity.apply(.progress(id: id, UploadProgress(bytesSent: 3_000, totalBytes: 10_000)), now: t0.addingTimeInterval(2))
        let now = t0.addingTimeInterval(2)
        #expect(activity.speed(now: now) == 2_000)
        #expect(activity.secondsRemaining(now: now) == 3.5)
    }

    @Test func badgeIsTheShortUppercaseExtension() {
        #expect(UploadActivity.Item(id: UUID(), fileName: "a.png", totalBytes: 1).badge == "PNG")
        #expect(UploadActivity.Item(id: UUID(), fileName: "movie.webarchive", totalBytes: 1).badge == "WEBA")
        #expect(UploadActivity.Item(id: UUID(), fileName: "README", totalBytes: 1).badge == "")
    }

    @Test func aFolderHasNoBadge() {
        let folder = UploadActivity.Item(id: UUID(), fileName: "photos.2026/", totalBytes: 1)
        #expect(folder.isFolder)
        #expect(folder.badge == "")
        #expect(UploadActivity.Item(id: UUID(), fileName: "photos.2026", totalBytes: 1).isFolder == false)
    }
}

struct DropZoneGeometryTests {
    let icon = CGRect(x: 1_300, y: 875, width: 32, height: 25)
    let screen = CGRect(x: 0, y: 0, width: 1_440, height: 875)

    @Test func opensWithinTheProximityRadiusOnly() {
        #expect(DropZoneGeometry.isNearIcon(CGPoint(x: icon.midX, y: icon.midY - 100), iconFrame: icon))
        #expect(!DropZoneGeometry.isNearIcon(CGPoint(x: icon.midX - 200, y: icon.midY), iconFrame: icon))
    }

    @Test func panelHangsBelowTheIconAndStaysOnScreen() {
        let frame = DropZoneGeometry.panelFrame(iconFrame: icon, visibleScreenFrame: screen)
        #expect(frame.size == DropZoneGeometry.panelSize)
        #expect(frame.maxY < icon.minY)
        #expect(frame.maxX <= screen.maxX - 8)
        #expect(screen.contains(frame))

        let farLeft = DropZoneGeometry.panelFrame(iconFrame: CGRect(x: 4, y: 875, width: 32, height: 25), visibleScreenFrame: screen)
        #expect(farLeft.minX >= screen.minX + 8)
    }

    @Test func panelIsCenteredUnderTheIconWhenThereIsRoom() {
        let middle = CGRect(x: 700, y: 875, width: 32, height: 25)
        let frame = DropZoneGeometry.panelFrame(iconFrame: middle, visibleScreenFrame: screen)
        #expect(frame.midX == middle.midX)
        #expect(frame.maxY < middle.minY)
    }

    @Test func panelOnlyShiftsAsFarAsTheScreenEdgeRequires() {
        let nearRightEdge = CGRect(x: 1_380, y: 875, width: 32, height: 25)
        let frame = DropZoneGeometry.panelFrame(iconFrame: nearRightEdge, visibleScreenFrame: screen)
        #expect(frame.maxX == screen.maxX - 8)
        // Still under the icon, not hanging off to one side of it.
        #expect(frame.minX < nearRightEdge.minX && frame.maxX > nearRightEdge.maxX)
    }

    @Test func stayingOpenToleratesDriftAroundThePanel() {
        let frame = DropZoneGeometry.panelFrame(iconFrame: icon, visibleScreenFrame: screen)
        let justOutside = CGPoint(x: frame.minX - 10, y: frame.midY - 100)
        #expect(!DropZoneGeometry.isNearIcon(justOutside, iconFrame: icon))
        #expect(DropZoneGeometry.shouldStayOpen(justOutside, iconFrame: icon, panelFrame: frame))
        #expect(!DropZoneGeometry.shouldStayOpen(CGPoint(x: 100, y: 100), iconFrame: icon, panelFrame: frame))
    }

    @Test func panelSizeIsTheSingleTuningKnob() {
        let smaller = DropZoneGeometry.panelFrame(iconFrame: icon, visibleScreenFrame: screen, size: CGSize(width: 180, height: 140))
        #expect(smaller.size == CGSize(width: 180, height: 140))
    }
}

struct ActivityTextTests {
    @Test func timeLeftPhrases() {
        #expect(ActivityText.timeLeft(0.2) == "1 s left")
        #expect(ActivityText.timeLeft(3) == "3 s left")
        #expect(ActivityText.timeLeft(59.2) == "60 s left" || ActivityText.timeLeft(59.2) == "1 min left")
        #expect(ActivityText.timeLeft(61) == "2 min left")
        #expect(ActivityText.timeLeft(3 * 3600) == "3 h left")
        #expect(ActivityText.timeLeft(3600 + 600) == "1 h 10 min left")
        #expect(ActivityText.timeLeft(nil) == nil)
        #expect(ActivityText.timeLeft(.infinity) == nil)
        #expect(ActivityText.timeLeft(30 * 3600) == nil)
    }

    @Test func headersCountTheBatch() {
        var activity = UploadActivity()
        let t = Date(timeIntervalSince1970: 0)
        let ids = (0..<3).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            activity.apply(.queued(id: id, fileName: "f\(index)", totalBytes: 10), now: t)
        }
        #expect(ActivityText.uploadingHeader(activity) == "Uploading 1 of 3")
        activity.apply(.succeeded(id: ids[0], remotePath: "/f0"), now: t)
        activity.apply(.failed(id: ids[1], .unsupportedItem), now: t)
        #expect(ActivityText.uploadingHeader(activity) == "Uploading 3 of 3")
        activity.apply(.succeeded(id: ids[2], remotePath: "/f2"), now: t)
        #expect(ActivityText.finishedSummary(activity) == "2 uploaded · 1 failed")
    }
}
