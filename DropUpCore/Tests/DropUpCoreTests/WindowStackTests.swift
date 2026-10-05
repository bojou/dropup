import Foundation
import Testing
@testable import DropUpCore

/// Putting the app's windows back behind the windows of other apps that they were behind.
struct WindowStackTests {
    private let me: Int32 = 100
    private let other: Int32 = 200
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func mine(_ number: Int) -> StackedWindow { StackedWindow(number: number, ownerProcess: me, frame: frame) }
    private func theirs(_ number: Int) -> StackedWindow { StackedWindow(number: number, ownerProcess: other, frame: frame) }

    private func restores(_ before: [StackedWindow], _ now: [StackedWindow], allowed: Set<Int> = []) -> [StackRestore] {
        WindowStack.restores(before: before, now: now, ownProcess: me, allowed: allowed)
    }

    @Test func nothingMovedMeansNothingToPutBack() {
        let stack = [theirs(10), mine(1), theirs(11), mine(2)]
        #expect(restores(stack, stack).isEmpty)
    }

    @Test func aWindowThatCameInFrontOfTheOneThatCoveredItGoesBackBehindIt() {
        #expect(restores([theirs(10), mine(1)], [mine(1), theirs(10)]) == [StackRestore(window: 1, below: 10)])
    }

    @Test func aWindowThatWasAskedForIsLeftWhereItIs() {
        #expect(restores([theirs(10), mine(1)], [mine(1), theirs(10)], allowed: [1]).isEmpty)
    }

    @Test func aWindowIsPutBehindAllThatWereInFrontOfIt() {
        // Two apps' windows were in front; it came forward past both.
        let result = restores([theirs(10), theirs(11), mine(1)], [mine(1), theirs(10), theirs(11)])
        #expect(result == [StackRestore(window: 1, below: 11)])
    }

    @Test func aWindowThatCameForwardPastOnlyOneOfThemGoesBehindTheLastOfThem() {
        let result = restores([theirs(10), theirs(11), mine(1)], [theirs(10), mine(1), theirs(11)])
        #expect(result == [StackRestore(window: 1, below: 11)])
    }

    @Test func aWindowThatWasInFrontOfEverythingIsLeftAlone() {
        #expect(restores([mine(1), theirs(10)], [theirs(10), mine(1)]).isEmpty)
    }

    @Test func aWindowThatStayedBehindIsLeftAlone() {
        #expect(restores([theirs(10), theirs(11), mine(1)], [theirs(10), theirs(11), mine(1)]).isEmpty)
    }

    @Test func aCovererThatIsGoneNoLongerKeepsAnythingBehindIt() {
        // 10 closed. 1 was behind 11 as well, and is in front of it now.
        let result = restores([theirs(10), theirs(11), mine(1)], [mine(1), theirs(11)])
        #expect(result == [StackRestore(window: 1, below: 11)])
        #expect(restores([theirs(10), mine(1)], [mine(1)]).isEmpty)
    }

    @Test func aWindowThatIsNoLongerOnScreenIsLeftAlone() {
        #expect(restores([theirs(10), mine(1)], [theirs(10)]).isEmpty)
    }

    @Test func theAppsOwnWindowsDoNotCoverEachOther() {
        // 2 was in front of 1, and still is: neither is behind a window of another app.
        #expect(restores([mine(2), mine(1)], [mine(1), mine(2)]).isEmpty)
    }

    @Test func severalWindowsPutBehindTheSameOneKeepTheirOrder() {
        // 1 above 2 above 3, all behind 10. All three came forward. Backmost first, so that 1 ends up on top.
        let before = [theirs(10), mine(1), mine(2), mine(3)]
        let now = [mine(1), mine(2), mine(3), theirs(10)]
        #expect(restores(before, now) == [
            StackRestore(window: 3, below: 10), StackRestore(window: 2, below: 10), StackRestore(window: 1, below: 10),
        ])
    }

    @Test func onlyTheWindowsThatMovedAreListed() {
        let before = [theirs(10), mine(1), theirs(11), mine(2)]
        let now = [mine(1), theirs(10), theirs(11), mine(2)]
        #expect(restores(before, now) == [StackRestore(window: 1, below: 10)])
    }

    @Test func anEmptyListLeavesEverythingAlone() {
        #expect(restores([], []).isEmpty)
        #expect(restores([theirs(10), mine(1)], []).isEmpty)
    }
}
