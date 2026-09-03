import SwiftUI
import GatewayCore

/// Every station on the ladder, documented or not.
///
/// **A root destination, not a Studio submenu.** Studio is maintenance —
/// queues, calibration, installed components. This is where exploring
/// happens and where a station earns its name, which is the listener's own
/// work. The owner placed it between Home and Studio for that reason.
struct FocusMenuView: View {
    /// Said once. Home advertises this destination with the same sentence,
    /// and two copies of a description drift the moment one is edited.
    static let subtitle = "Every station on the ladder — described, explored, or waiting."

    @EnvironmentObject var store: LibraryStore

    private var stations: [ContinuousLadder.Station] {
        let levels = store.library?.levels ?? []
        return (ContinuousLadder.floor...ContinuousLadder.ceiling)
            .compactMap { ContinuousLadder.station($0, levels: levels, book: store.stationBook) }
    }

    var body: some View {
        FeaturePage("Focus", subtitle: FocusMenuView.subtitle) {
            let all = stations
            let documented = all.filter(\.isDocumented).count
            HStack(spacing: 6) {
                Chip(text: "\(all.count) stations", color: Monokai.cyan)
                Chip(text: "\(documented) described", color: Monokai.green)
                Chip(text: "\(all.count - documented) estimated", color: Monokai.comment)
            }
            ForEach(all, id: \.key) { station in
                StationRow(station: station)
            }
        }
    }
}

/// One station in the list: what it is called, and where it stands.
private struct StationRow: View {
    @EnvironmentObject var store: LibraryStore
    let station: ContinuousLadder.Station

    private var standing: StationPromotion.Standing {
        StationPromotion.standing(
            for: station.key,
            entries: store.entries(for: station.key),
            documented: (store.library?.levels ?? []).map(\.key))
    }

    private var title: String {
        StationNaming.displayName(
            key: station.key,
            title: store.stationBook.record(station.key)?.title,
            levelName: store.library?.levels.first { $0.key == station.key }?.name)
    }

    var body: some View {
        let s = standing
        FeatureLinkCard(
            title: "\(station.key) · \(title)",
            subtitle: subtitle(s),
            icon: station.isDocumented ? "circle.fill" : "circle.dotted",
            status: status(s)
        ) {
            store.selection = .level(station.key)
        }
    }

    private func subtitle(_ s: StationPromotion.Standing) -> String {
        var parts = [s.standingLabel]
        // Say where the signal comes from. An interpolated beat must never
        // read as a measured one.
        switch station.provenance {
        case .measured: parts.append("measured signal")
        case .stated: parts.append("stated signal")
        case .estimated: parts.append("estimated signal")
        case .tuned: parts.append("tuned by you")
        }
        if s.entries > 0 {
            parts.append("\(s.entries) written visit\(s.entries == 1 ? "" : "s")")
        }
        if let outstanding = s.outstanding { parts.append(outstanding) }
        return parts.joined(separator: " · ")
    }

    private func status(_ s: StationPromotion.Standing) -> UIStatus {
        if s.isDocumented { return .ok }
        if s.isEligible { return .active }
        return s.entries > 0 ? .pending : .unavailable
    }
}
