import Foundation

/// The whole default path at once: which lessons still need a session built,
/// which already have one, and which cannot be built at all.
///
/// **Why this exists.** Every lesson could already be built, one at a time:
/// open the plan, create the session, wait, open the next. That is fine for a
/// session someone is about to listen to. It is an hour of clicking for
/// someone loading the whole path onto a phone, and the owner had done that
/// hour twice, with more regenerations ahead. So Production gains one button
/// that queues every lesson, and this decides what that button queues.
///
/// Pure arithmetic over names, so `gfcheck` can hold it without an engine.
public enum DefaultPathBuild {
    public enum State: Equatable, Sendable {
        /// A session for this template is already assembled, at this folder.
        case assembled(URL)
        /// Already waiting in the assembly queue.
        case queued
        /// Nothing yet: the button builds it.
        case toBuild(template: URL)
        /// The lesson names a template the library does not have.
        case missingTemplate
    }

    public struct Item: Equatable, Sendable {
        /// One-based position on the path, which export uses to number files
        /// so a phone lists them in teaching order.
        public var position: Int
        public var lesson: DefaultPath.Lesson
        public var state: State
    }

    /// One item per *template*, in path order.
    ///
    /// Two lessons that resolve to the same template are one session: building
    /// it twice would assemble two identical tapes. The first lesson keeps it.
    ///
    /// - Parameters:
    ///   - assembled: for each template name, the newest assembled session.
    ///   - queued: template names already waiting for assembly.
    public static func items(path: DefaultPath, templates: [URL],
                             assembled: [String: URL],
                             queued: Set<String>) -> [Item] {
        let byName = Dictionary(templates.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                                uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [Item] = []
        for lesson in path.lessons where seen.insert(lesson.template).inserted {
            let state: State
            if let dir = assembled[lesson.template] { state = .assembled(dir) }
            else if queued.contains(lesson.template) { state = .queued }
            else if let url = byName[lesson.template] { state = .toBuild(template: url) }
            else { state = .missingTemplate }
            out.append(Item(position: out.count + 1, lesson: lesson, state: state))
        }
        return out
    }

    /// The newest assembled session per template, read from manifests.
    ///
    /// Newest by folder name: render folders begin with their date and time,
    /// so the name sorts as the build order without touching the disk again.
    public static func newestAssembled(renders: [URL],
                                       manifest: (URL) -> SessionManifest?) -> [String: URL] {
        var out: [String: URL] = [:]
        for dir in renders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let template = manifest(dir)?.template else { continue }
            out[template] = dir
        }
        return out
    }

    /// `07 Advanced Focus 10.wav`-style names for an export folder: the path
    /// position first, so any file browser lists the lessons in the order the
    /// tapes teach them.
    public static func exportFilename(position: Int, suggested: String) -> String {
        let n = position < 10 ? "0\(position)" : "\(position)"
        return "\(n) \(suggested)"
    }
}
