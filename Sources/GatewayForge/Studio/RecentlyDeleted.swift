import SwiftUI
import GatewayCore

/// The one place a deleted session plan, assembled session or segment
/// can be seen and taken back.
///
/// Every fact on this page is read from `DeletionStore` at render time: what is
/// in the store, whether its bytes are still on disk, and how many days it has
/// left. Nothing here remembers a countdown — a row that said "27 days" because
/// it was told so once is exactly the kind of confident stale claim this
/// codebase keeps producing.
struct RecentlyDeletedStudioView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var listings: [DeletedListing] = []
    @State private var failure: String?
    @State private var confirming: DeletedListing?

    var body: some View {
        FeaturePage(StudioDestination.deleted.title,
                    subtitle: StudioDestination.deleted.subtitle) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Monokai.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The sweep runs at library reload. If it threw, the window is not
            // being enforced and the page has to say so rather than go on
            // printing confident countdowns.
            if let sweep = store.deletionError {
                Label("The \(DeletionPolicy.retentionDays)-day sweep did not run: \(sweep)",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Monokai.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(listings.isEmpty
                         ? "Nothing deleted"
                         : "\(listings.count) item\(listings.count == 1 ? "" : "s")")
                        .font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Button("Refresh") { refresh() }.controlSize(.small)
                }

                if listings.isEmpty {
                    Text("""
                         Deleted sessions, session plans and segments \
                         are kept here for \(DeletionPolicy.retentionDays) days \
                         and can be put back exactly where they were. After that \
                         they are gone.
                         """)
                        .font(.callout).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(listings) { listing in
                        DeletedRow(listing: listing,
                                   restore: { restore(listing) },
                                   removeNow: { confirming = listing })
                        if listing.id != listings.last?.id { Divider().opacity(0.3) }
                    }
                }
            }
            .panel()
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Delete “\(confirming?.item.title ?? "")” permanently?",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let listing = confirming { removeNow(listing) }
                confirming = nil
            }
            Button("Keep", role: .cancel) { confirming = nil }
        } message: {
            Text("It leaves Gateway Forge now and goes to the Finder Trash.")
        }
    }

    /// Gray when the store is empty, orange while something is counting down:
    /// it is not a defect, but it will change on its own if left alone.
    static func status(store: LibraryStore) -> UIStatus {
        let waiting = (try? DeletionStore.listings(root: store.root)) ?? []
        return waiting.isEmpty ? .unavailable : .pending
    }

    private func refresh() {
        do {
            listings = try DeletionStore.listings(root: store.root)
            failure = nil
        } catch {
            listings = []
            failure = "Recently Deleted could not be read: \(error.localizedDescription)"
        }
    }

    private func restore(_ listing: DeletedListing) {
        do {
            try DeletionStore.restore(id: listing.item.id, root: store.root)
            failure = nil
            store.reload()
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    private func removeNow(_ listing: DeletedListing) {
        do {
            try DeletionStore.remove(id: listing.item.id, root: store.root, disposal: .trash)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

/// One deleted thing. A row that cannot be restored says why instead of
/// offering a button that would fail.
private struct DeletedRow: View {
    let listing: DeletedListing
    let restore: () -> Void
    let removeNow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(listing.payloadExists ? Monokai.orange : Monokai.comment)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(listing.item.title).font(.headline).foregroundStyle(Monokai.fg)
                Text(subtitle).font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
                Text(listing.item.originalPath)
                    .font(.caption.monospaced()).foregroundStyle(Monokai.comment)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if listing.payloadExists {
                    Button("Restore", action: restore).controlSize(.small)
                }
                Button(listing.payloadExists ? "Delete Now" : "Remove Record",
                       action: removeNow)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts = [listing.item.kind.label]
        if let detail = listing.item.detail, !detail.isEmpty { parts.append(detail) }
        guard listing.payloadExists else {
            parts.append("no longer on disk — cannot be restored")
            return parts.joined(separator: " · ")
        }
        parts.append(listing.daysRemaining == 1
                     ? "1 day left"
                     : "\(listing.daysRemaining) days left")
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch listing.item.kind {
        case .template: "rectangle.stack"
        case .session: "waveform.circle"
        case .segment: "text.alignleft"
        case .voice: "waveform"
        case .other: "doc"
        }
    }
}
