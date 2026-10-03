import Foundation

/// Short phrases for the popover, kept here so they are tested.
public enum ActivityText {
    /// `3 s left`, `2 min left`, `1 h 5 min left`. Nil when the estimate is unknown or absurd.
    public static func timeLeft(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 24 * 3600 else { return nil }
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(max(total, 1)) s left" }
        if total < 3600 { return "\(Int((Double(total) / 60).rounded(.up))) min left" }
        let hours = total / 3600
        let minutes = (total % 3600 + 59) / 60
        return minutes == 0 ? "\(hours) h left" : "\(hours) h \(minutes) min left"
    }

    /// `Uploading 2 of 3` for the section header, counting the files of the current batch.
    public static func uploadingHeader(_ activity: UploadActivity) -> String {
        let total = activity.batchTotal
        return "Uploading \(min(activity.batchDone + 1, total)) of \(total)"
    }

    /// `2 uploaded · 1 failed · 1 interrupted · 1 paused` for the finished section header.
    public static func finishedSummary(_ activity: UploadActivity) -> String {
        var uploaded = 0, failed = 0, interrupted = 0, paused = 0
        for item in activity.finished {
            switch item.state {
            case .succeeded: uploaded += 1
            case .failed: failed += 1
            case .interrupted: interrupted += 1
            case .paused: paused += 1
            default: break
            }
        }
        var parts: [String] = []
        if uploaded > 0 { parts.append("\(uploaded) uploaded") }
        if failed > 0 { parts.append("\(failed) failed") }
        if interrupted > 0 { parts.append("\(interrupted) interrupted") }
        if paused > 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }

    /// What the list shows for an upload: its name, or with names hidden a plain word that says what happened to it.
    public static func displayName(of item: UploadActivity.Item, hidingNames: Bool) -> String {
        guard hidingNames else { return item.fileName }
        let thing = item.isFolder ? "folder" : "file"
        if case .succeeded = item.state { return "Uploaded \(thing)" }
        return thing.capitalized
    }

    /// The failure message to show under an upload. With names hidden, nothing in it says what the upload was called or
    /// where it was going: the file's name (and the numbered name the server may have given it, `photo-1.png`), text in
    /// quotes, anything that looks like a path, and each folder of `hiddenPaths` (the upload folder, say) are all
    /// replaced. A folder's name can't be told apart from other words in free-form server text, so this takes out more
    /// than needed rather than less.
    public static func failureMessage(
        _ message: String,
        for item: UploadActivity.Item,
        hidingNames: Bool,
        hiddenPaths: [String] = []
    ) -> String {
        guard hidingNames else { return message }
        let ownName = item.isFolder ? String(item.fileName.dropLast()) : item.fileName
        let ownMask = item.isFolder ? Mask.folder : Mask.file
        // The stand-ins are single private-use characters, so a later step can't take one for part of a name.
        var text = String(String.UnicodeScalarView(message.unicodeScalars.filter { !Mask.all.unicodeScalars.contains($0) }))

        // What a name or path stands for: the item itself when it ends in the item's name, else something else.
        func mask(for path: String) -> String {
            let parts = path.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }
            if parts.count == 1 { return isName(path, ownName) ? ownMask : Mask.item }
            if let last = parts.last, !last.isEmpty, isName(String(last), ownName) { return ownMask }
            return Mask.folder
        }

        // Text in quotes is a name or a path: a folder upload reports "“sub/photo.png”: …".
        text = replacingMatches(of: #"“[^”]*”|"[^"]*""#, in: text) { quoted in
            mask(for: String(quoted.dropFirst().dropLast()))
        }

        // A word with a slash in it is a path. Punctuation around it stays, so the sentence still reads.
        let character = #"[^\s()\[\]{}<>"“”,;|]"#
        text = replacingMatches(of: character + #"*[/\\]"# + character + "*", in: text) { token in
            let (leading, core, trailing) = splitEdges(of: token, in: ".:!?'‘’")
            return leading + mask(for: core) + trailing
        }

        // Folders the upload went to, wherever the server names them without a slash around them.
        for segment in Set(hiddenPaths.flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) }) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { continue }
            text = replacingWholeWords(trimmed, in: text, with: Mask.folder)
        }

        // The item's own name, with the number the server may have added.
        if !ownName.isEmpty {
            let (stem, ext) = RemoteFileName.split(ownName)
            text = replacingWholeWords(
                NSRegularExpression.escapedPattern(for: stem) + "(-[0-9]+)?" + NSRegularExpression.escapedPattern(for: ext),
                in: text,
                with: ownMask,
                isPattern: true
            )
        }

        // One stand-in per run, so a path split at its spaces doesn't read "the folder the folder".
        text = replacingMatches(of: "([\u{E000}-\u{E002}])(?:\\s+\\1)+", in: text) { run in String(run.prefix(1)) }
        return text
            .replacingOccurrences(of: Mask.file, with: "the file")
            .replacingOccurrences(of: Mask.folder, with: "the folder")
            .replacingOccurrences(of: Mask.item, with: "the item")
    }

    // MARK: Hiding names

    private enum Mask {
        static let file = "\u{E000}"
        static let folder = "\u{E001}"
        static let item = "\u{E002}"
        static let all = file + folder + item
    }

    /// Whether `candidate` is the item's name, or that name with the number a server adds to avoid a clash.
    private static func isName(_ candidate: String, _ name: String) -> Bool {
        guard !name.isEmpty, !candidate.isEmpty else { return false }
        if candidate.caseInsensitiveCompare(name) == .orderedSame { return true }
        let (stem, ext) = RemoteFileName.split(name)
        let pattern = "^" + NSRegularExpression.escapedPattern(for: stem) + "(-[0-9]+)?" + NSRegularExpression.escapedPattern(for: ext) + "$"
        return candidate.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Splits `text` into the run of `edge` characters at its start, what is between, and the run at its end.
    private static func splitEdges(of text: String, in edge: String) -> (leading: String, core: String, trailing: String) {
        let characters = Array(text)
        var start = 0
        var end = characters.count
        while start < end, edge.contains(characters[start]) { start += 1 }
        while end > start, edge.contains(characters[end - 1]) { end -= 1 }
        return (String(characters[..<start]), String(characters[start..<end]), String(characters[end...]))
    }

    private static func replacingWholeWords(_ word: String, in text: String, with mask: String, isPattern: Bool = false) -> String {
        // Whole words only, so a short name like "a" doesn't cut into the words around it.
        let core = isPattern ? word : NSRegularExpression.escapedPattern(for: word)
        let pattern = #"(?<![\p{L}\p{N}_])"# + core + #"(?![\p{L}\p{N}_])"#
        return replacingMatches(of: pattern, in: text) { _ in mask }
    }

    /// Replaces each case-insensitive match of `pattern` with what `replacement` makes of the matched text.
    private static func replacingMatches(of pattern: String, in text: String, _ replacement: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = text
        // From the end, so earlier ranges stay valid while the text changes.
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }

    /// What to tell the user when a batch finishes, or nil when there is nothing to say (everything was cancelled).
    /// With `hidingNames` the notice says how many went through, but not what they were called.
    public static func completionNotice(
        _ activity: UploadActivity,
        hidingNames: Bool = false,
        hiddenPaths: [String] = []
    ) -> (title: String, body: String)? {
        var uploaded: [UploadActivity.Item] = []
        var failed: [UploadActivity.Item] = []
        for item in activity.batchItems {
            switch item.state {
            case .succeeded: uploaded.append(item)
            case .failed: failed.append(item)
            default: break
            }
        }
        func names(_ items: [UploadActivity.Item], more: Bool = false) -> String {
            hidingNames ? "" : items.prefix(3).map(\.fileName).joined(separator: ", ") + (more ? "…" : "")
        }
        switch (uploaded.count, failed.count) {
        case (0, 0):
            return nil
        case (1, 0):
            return ("Uploaded", hidingNames ? displayName(of: uploaded[0], hidingNames: true) : uploaded[0].fileName)
        case (let count, 0):
            return ("Uploaded \(count) files", names(uploaded, more: count > 3))
        case (0, 1):
            if case .failed(let message) = failed[0].state {
                return ("Upload failed", hidingNames ? failureMessage(message, for: failed[0], hidingNames: true, hiddenPaths: hiddenPaths) : "\(failed[0].fileName): \(message)")
            }
            return nil
        case (0, let count):
            return ("\(count) uploads failed", names(failed))
        case (let ok, let bad):
            return ("\(ok) uploaded, \(bad) failed", names(failed))
        }
    }
}
