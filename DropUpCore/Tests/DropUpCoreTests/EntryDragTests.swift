import Foundation
import Testing
@testable import DropUpCore

struct EntryDragTests {
    @Test func roundTripsThroughText() throws {
        let drag = EntryDrag(server: "me@example.com", folder: "drops/", name: "Bericht – Größe \"1\".txt", isFolder: false)
        #expect(drag.folder == "/drops")
        #expect(EntryDrag(text: drag.text) == drag)
    }

    @Test func foldersComeBackAsFolders() throws {
        let drag = EntryDrag(server: "s", folder: "/", name: "photos", isFolder: true)
        let entry = try #require(EntryDrag(text: drag.text)).entry
        #expect(entry == RemoteEntry(name: "photos", kind: .folder))
    }

    @Test(arguments: ["", "hello", "dropup-entry:", "dropup-entry:{}", "dropup-entry:not json", "{\"name\":\"x\"}"])
    func otherTextIsNotADrag(_ text: String) {
        #expect(EntryDrag(text: text) == nil)
    }
}
