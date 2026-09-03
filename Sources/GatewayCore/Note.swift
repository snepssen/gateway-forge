import Foundation

/// A journal note: markdown with YAML-ish frontmatter. Plain files on disk, so
/// the writing survives the app and opens in any editor.
public struct Note: Sendable, Equatable {
    public var frontmatter: [String: String] = [:]
    public var body: String = ""

    public init(frontmatter: [String: String] = [:], body: String = "") {
        self.frontmatter = frontmatter; self.body = body
    }

    public static func parse(_ text: String) -> Note {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return Note(body: text) }

        var fm: [String: String] = [:]
        for l in lines[1..<end] {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if !k.isEmpty { fm[k] = v }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
                     .trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(frontmatter: fm, body: body)
    }

    public func serialised() -> String {
        guard !frontmatter.isEmpty else { return body }
        let keys = frontmatter.keys.sorted()
        let fm = keys.map { "\($0): \(frontmatter[$0]!)" }.joined(separator: "\n")
        return "---\n\(fm)\n---\n\n\(body)\n"
    }
}

extension Note {
    /// Merge in the keys the app owns, leaving anything written by hand alone.
    /// The app never owns your writing -- it only stamps what it needs to.
    public func stamped(_ keys: [String: String], at date: Date = Date()) -> Note {
        var n = self
        for (k, v) in keys { n.frontmatter[k] = v }
        n.frontmatter["updated"] = ISO8601DateFormatter().string(from: date)
        return n
    }
}

/// Reading and writing notes. Autosave lives on top of this: the debounce is a
/// UI concern, but the decision of whether a note is worth a file is not.
public enum NoteIO {
    public static func load(from url: URL) -> Note {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Note() }
        return Note.parse(text)
    }

    /// Clicking through levels nobody has written in yet must not litter the tree
    /// with empty files -- most levels are placeholders waiting for content, and
    /// an empty `notes.md` in every one of them is noise. Once a file exists it
    /// stays in step, including when the writing is deliberately cleared.
    public static func shouldWrite(_ note: Note, exists: Bool) -> Bool {
        exists || !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns whether anything was written. Atomic, so a crash mid-save cannot
    /// truncate a journal entry.
    @discardableResult
    public static func save(_ note: Note, to url: URL) throws -> Bool {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        guard shouldWrite(note, exists: exists) else { return false }
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(note.serialised().utf8).write(to: url, options: .atomic)
        return true
    }
}

