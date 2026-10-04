import Foundation
import Testing
@testable import DropUpCore

/// Which of the app's windows are out of sight behind another app's windows.
struct WindowCoverTests {
    private let me: Int32 = 100
    private let other: Int32 = 200
    private let mine = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func window(_ number: Int, of owner: Int32, _ frame: CGRect) -> StackedWindow {
        StackedWindow(number: number, ownerProcess: owner, frame: frame)
    }

    private func covered(_ stack: [StackedWindow], number: Int = 1) -> Bool {
        WindowCover.isCovered(windowNumber: number, frame: mine, ownProcess: me, stack: stack)
    }

    @Test func aWindowAtTheFrontIsNotCovered() {
        #expect(!covered([window(1, of: me, mine), window(2, of: other, mine)]))
    }

    @Test func anotherAppsWindowAboveItCoversIt() {
        #expect(covered([window(2, of: other, CGRect(x: 0, y: 0, width: 1000, height: 800)), window(1, of: me, mine)]))
    }

    @Test func aWindowThatOnlyPartlyOverlapsStillCovers() {
        #expect(covered([window(2, of: other, CGRect(x: 450, y: 350, width: 400, height: 300)), window(1, of: me, mine)]))
    }

    @Test func anotherAppsWindowAboveButElsewhereDoesNotCover() {
        #expect(!covered([window(2, of: other, CGRect(x: 600, y: 0, width: 300, height: 300)), window(1, of: me, mine)]))
    }

    @Test func windowsThatOnlyTouchAtAnEdgeDoNotOverlap() {
        #expect(!covered([window(2, of: other, CGRect(x: 500, y: 100, width: 300, height: 300)), window(1, of: me, mine)]))
    }

    @Test func anotherAppsWindowBehindItDoesNotCoverIt() {
        #expect(!covered([window(1, of: me, mine), window(2, of: other, CGRect(x: 0, y: 0, width: 1000, height: 800))]))
    }

    @Test func theAppsOwnWindowAboveDoesNotCoverIt() {
        #expect(!covered([window(3, of: me, mine), window(1, of: me, mine)]))
    }

    @Test func theFirstWindowAboveDecidesNotTheOnesBelow() {
        // Covered only through the topmost overlapping window of another app; the own window between is no help.
        #expect(covered([window(2, of: other, mine), window(3, of: me, mine), window(1, of: me, mine)]))
    }

    @Test func aWindowThatIsNotOnScreenIsCovered() {
        #expect(covered([window(2, of: other, mine)], number: 9))
    }

    @Test func anEmptyWindowListCoversNothing() {
        #expect(!covered([]))
    }
}
