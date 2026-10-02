import Foundation
import Testing
@testable import DropUpCore

struct FolderHistoryTests {
    @Test func startsWithNothingToGoBackOrForwardTo() {
        let history = FolderHistory(start: "drops/")
        #expect(history.current == "/drops")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.previous == nil && history.next == nil)
    }

    @Test func backClimbsOutOfTheStartingFolderOneLevelAtATimeWhenAsked() {
        var history = FolderHistory(start: "/drops/images/2026/", includingParents: true)
        #expect(history.current == "/drops/images/2026")
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.previous == "/drops/images")

        history.goBack()
        #expect(history.current == "/drops/images")
        history.goBack()
        history.goBack()
        #expect(history.current == "/")
        #expect(!history.canGoBack)

        history.goForward()
        #expect(history.current == "/drops")
        history.goForward()
        history.goForward()
        #expect(history.current == "/drops/images/2026")
        #expect(!history.canGoForward)
    }

    @Test func startingAtTheTopHasNothingToGoBackTo() {
        #expect(!FolderHistory(start: "/", includingParents: true).canGoBack)
        #expect(FolderHistory(start: "/drops", includingParents: true).previous == "/")
    }

    @Test func visitsAfterTheStartComeBeforeTheEnclosingFolders() {
        var history = FolderHistory(start: "/a/b", includingParents: true)
        history.visit("/a/b/c")
        history.goBack()
        #expect(history.current == "/a/b")
        history.goBack()
        #expect(history.current == "/a")
    }

    @Test func backAndForwardRetraceTheVisits() {
        var history = FolderHistory(start: "/")
        history.visit("/a")
        history.visit("/a/b")

        #expect(history.previous == "/a")
        history.goBack()
        #expect(history.current == "/a")
        history.goBack()
        #expect(history.current == "/")
        #expect(!history.canGoBack)

        #expect(history.next == "/a")
        history.goForward()
        history.goForward()
        #expect(history.current == "/a/b")
        #expect(!history.canGoForward)
    }

    @Test func aNewVisitDropsWhatForwardCouldReachLikeFinder() {
        var history = FolderHistory(start: "/")
        history.visit("/a")
        history.visit("/b")
        history.goBack()
        history.goBack()

        history.visit("/c")

        #expect(!history.canGoForward)
        history.goBack()
        #expect(history.current == "/")
    }

    @Test func visitingTheFolderAlreadyShownChangesNothing() {
        var history = FolderHistory(start: "/a")
        history.visit("/a/")
        #expect(!history.canGoBack)
    }

    @Test func goingBackOrForwardWithNowhereToGoIsHarmless() {
        var history = FolderHistory(start: "/a")
        history.goBack()
        history.goForward()
        #expect(history.current == "/a")
    }

    @Test func remembersAHundredFolders() {
        var history = FolderHistory(start: "/")
        for index in 1...150 { history.visit("/f\(index)") }
        var steps = 0
        while history.canGoBack {
            history.goBack()
            steps += 1
        }
        #expect(steps == 100)
        #expect(history.current == "/f50")
    }
}

struct EntrySortTests {
    private let day = TimeInterval(86_400)
    private func file(_ name: String, size: Int64? = nil, age: Double? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, size: size, modified: age.map { Date(timeIntervalSince1970: 1_000_000 + $0 * day) })
    }
    private func folder(_ name: String, age: Double? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .folder, modified: age.map { Date(timeIntervalSince1970: 1_000_000 + $0 * day) })
    }
    private func names(_ entries: [RemoteEntry]) -> [String] { entries.map(\.name) }

    @Test func sortsByNameInFinderOrderAndCanReverse() {
        let entries = [file("file10"), file("file2"), folder("zeta"), folder("alpha")]
        #expect(names(RemoteEntry.sorted(entries, by: .name, ascending: true)) == ["alpha", "zeta", "file2", "file10"])
        #expect(names(RemoteEntry.sorted(entries, by: .name, ascending: false)) == ["zeta", "alpha", "file10", "file2"])
    }

    @Test func foldersStayOnTopWhateverTheKeyOrDirection() {
        let entries = [file("a", size: 1, age: 1), folder("b", age: 0), file("c", size: 9, age: 9)]
        for key in RemoteEntry.SortKey.allCases {
            for ascending in [true, false] {
                #expect(RemoteEntry.sorted(entries, by: key, ascending: ascending).first?.name == "b")
            }
        }
    }

    @Test func sortsBySizeWithUnknownSizesFirstAndTiesByName() {
        let entries = [file("big", size: 900), file("tie-b", size: 5), file("unknown"), file("tie-a", size: 5)]
        #expect(names(RemoteEntry.sorted(entries, by: .size, ascending: true)) == ["unknown", "tie-a", "tie-b", "big"])
        #expect(names(RemoteEntry.sorted(entries, by: .size, ascending: false)) == ["big", "tie-a", "tie-b", "unknown"])
    }

    @Test func sortsByModifiedDateWithUnknownDatesOldest() {
        let entries = [file("new", age: 5), file("undated"), file("old", age: 1)]
        #expect(names(RemoteEntry.sorted(entries, by: .modified, ascending: true)) == ["undated", "old", "new"])
        #expect(names(RemoteEntry.sorted(entries, by: .modified, ascending: false)) == ["new", "old", "undated"])
    }

    @Test func foldersAreOrderedByTheKeyToo() {
        let entries = [folder("a", age: 3), folder("b", age: 1), folder("c", age: 2)]
        #expect(names(RemoteEntry.sorted(entries, by: .modified, ascending: false)) == ["a", "c", "b"])
    }
}
