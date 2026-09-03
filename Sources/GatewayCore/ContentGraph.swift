import Foundation

/// A measured map from authored segments to the places that consume them.
///
/// This is deliberately derived from `.gws` files every time the library is
/// scanned.  The Studio must not remember that a segment is "unused" after a
/// template starts using it, and Focus-local scripts count just as much as the
/// templates in `library/templates`.
public struct ContentGraph: Sendable {
    public struct Consumer: Hashable, Sendable {
        public enum Kind: String, Sendable { case template, focusScript }

        public var kind: Kind
        /// A stable, human-readable identifier, not an absolute machine path.
        public var id: String
        public var url: URL

        public init(kind: Kind, id: String, url: URL) {
            self.kind = kind
            self.id = id
            self.url = url
        }
    }

    public enum RuntimeRole: String, CaseIterable, Sendable {
        case sessionAnnouncement
        case resumeCeremony

        public var segmentID: String {
            switch self {
            case .sessionAnnouncement: SessionAnnouncement.segmentID
            case .resumeCeremony: ResumePlan.segmentID
            }
        }
    }

    public enum Placement: Equatable, Sendable {
        /// Referenced directly by one or more authored session documents.
        case used([Consumer])
        /// Requested by application behaviour rather than a template row.
        case runtime([RuntimeRole])
        /// Not selected itself, but offered beside a selected member of its
        /// `@family`.  This is choice, not orphaned content.
        case alternative(family: String, selected: [String])
        /// Kept deliberately without an active consumer, with its authored
        /// reason. This is a decision, not unfinished placement work.
        case shelved(reason: String)
        /// No authored or runtime path currently reaches this segment.
        case unassigned
    }

    public struct Node: Identifiable, Sendable {
        public var id: String { segment.segmentID }
        public var segment: SegmentRef
        public var placement: Placement
    }

    public struct UnresolvedUse: Equatable, Sendable {
        public var segmentID: String
        public var consumer: Consumer
    }

    public var nodes: [Node]
    public var unresolvedUses: [UnresolvedUse]

    public var used: [Node] { nodes.filter { if case .used = $0.placement { true } else { false } } }
    public var runtime: [Node] { nodes.filter { if case .runtime = $0.placement { true } else { false } } }
    public var alternatives: [Node] {
        nodes.filter { if case .alternative = $0.placement { true } else { false } }
    }
    public var shelved: [Node] {
        nodes.filter { if case .shelved = $0.placement { true } else { false } }
    }
    public var unassigned: [Node] {
        nodes.filter { if case .unassigned = $0.placement { true } else { false } }
    }

    public init(library: Library) {
        let known = Set(library.segments.map(\.segmentID))
        var consumersBySegment: [String: Set<Consumer>] = [:]
        var unresolved: [UnresolvedUse] = []

        func consume(_ url: URL, as consumer: Consumer) {
            guard let doc = ScriptDoc.load(url) else { return }
            for id in doc.steps.filter({ $0.kind == .use }).map(\.text) {
                if known.contains(id) {
                    consumersBySegment[id, default: []].insert(consumer)
                } else {
                    unresolved.append(.init(segmentID: id, consumer: consumer))
                }
            }
        }

        for url in library.templates {
            let id = url.deletingPathExtension().lastPathComponent
            consume(url, as: .init(kind: .template, id: id, url: url))
        }
        for folder in library.focus {
            for url in folder.scripts {
                let name = url.deletingPathExtension().lastPathComponent
                consume(url, as: .init(kind: .focusScript,
                                       id: "\(folder.key)/\(name)", url: url))
            }
        }

        let rolesBySegment = Dictionary(grouping: RuntimeRole.allCases, by: \.segmentID)
        var directlyReachable = Set(consumersBySegment.keys)
        directlyReachable.formUnion(rolesBySegment.keys)

        nodes = library.segments.map { segment in
            let consumers = (consumersBySegment[segment.segmentID] ?? [])
                .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
            let roles = (rolesBySegment[segment.segmentID] ?? [])
                .sorted { $0.rawValue < $1.rawValue }
            let placement: Placement
            if !consumers.isEmpty {
                placement = .used(consumers)
            } else if !roles.isEmpty {
                placement = .runtime(roles)
            } else if let family = segment.family {
                let selected = library.segments
                    .filter { $0.family == family && directlyReachable.contains($0.segmentID) }
                    .map(\.segmentID).sorted()
                placement = selected.isEmpty
                    ? .unassigned
                    : .alternative(family: family, selected: selected)
            } else if let reason = segment.shelved {
                placement = .shelved(reason: reason)
            } else {
                placement = .unassigned
            }
            return Node(segment: segment, placement: placement)
        }
        unresolvedUses = unresolved.sorted {
            ($0.consumer.kind.rawValue, $0.consumer.id, $0.segmentID)
                < ($1.consumer.kind.rawValue, $1.consumer.id, $1.segmentID)
        }
    }
}
