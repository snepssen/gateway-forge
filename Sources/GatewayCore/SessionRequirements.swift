import Foundation

/// Narration that must exist before a template can become a playable session.
///
/// Most requirements are visible `use` rows. The resume ceremony is an app
/// behaviour rather than a point in the tape's timeline, but it is no less a
/// requirement: a session is not operationally complete if pausing it can only
/// produce a caption where authored speech was promised.
public enum SessionRequirements {
    public static func items(library: Library, template: ScriptDoc,
                             verbosity: Int? = nil) -> [RenderPlan.Item] {
        var items: [RenderPlan.Item] = []
        for row in library.resolve(template: template,
                                   verbosity: verbosity ?? template.verbosity ?? 3) {
            guard let file = row.file,
                  let source = try? String(contentsOf: file, encoding: .utf8),
                  let item = RenderPlan.items(gwsFile: file, source: source).first else { continue }
            items.append(item)
        }
        if let resume = ResumePlan.renderItem(in: library) { items.append(resume) }

        // A template may intentionally reuse a segment. It is spoken twice in
        // the session but rendered once in the cache.
        var seen = Set<String>()
        return items.filter { seen.insert($0.outputName).inserted }
    }
}
