import SwiftUI
import GatewayCore

/// One Focus level, whether or not anything has been written about it.
///
/// **This replaced two pages that were the same page.** `LevelView` was
/// reached six ways -- the climb rail, Home, a segment chip, the worklist, a
/// continuous journey -- and showed the production side: the climb that
/// reaches here, the sessions built for it, the scripts, the segments.
/// `StationView` was reached exactly one way, from the Focus menu, and showed
/// the practice side: what was found here, what the listener wrote, whether it
/// has earned a name. Both drew the same signal, the same description and the
/// same list of rendered sessions out of the same three fields.
///
/// Worse, the routing inverted the rule it was built on. The climb rail is
/// listener navigation, so clicking a level went to the maintenance page while
/// the listener's own page hid behind a menu they had to go and find.
///
/// So: one page, two tabs. **Practice is what you read and record; Production
/// is what you build.** The header belongs to neither, because a level's
/// identity and its signal are true on both sides. Production is absent
/// entirely for a station that is not on the map yet -- there is nothing to
/// build for a place with no entry in `levels.json`, and an empty tab is a
/// worse answer than no tab.
struct FocusLevelView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var continuous: ContinuousMode
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var activity: ActivityRecorder
    @State private var draft = ""
    @State private var writeError: String?
    @State private var editingBed = false
    @State private var drafting = false
    @State private var proposal: CartographerProposal?
    @State private var draftError: String?
    @State private var promoteError: String?
    @State private var visitError: String?
    @State private var beatDraft = ""
    @State private var carrierDraft = ""
    @State private var tab: Tab = .practice
    let key: String

    private enum Tab: String, CaseIterable, Identifiable {
        case practice = "Practice"
        case production = "Production"
        var id: String { rawValue }
    }

    private var levels: [Level] { store.library?.levels ?? [] }
    private var level: Level? { levels.first { $0.key == key } }
    /// On the map, as opposed to merely on the ladder. Decides whether there
    /// is a Production side at all.
    private var isDocumented: Bool { level != nil }
    private var station: ContinuousLadder.Station? {
        ContinuousLadder.number(key).flatMap {
            ContinuousLadder.station($0, levels: levels, book: store.stationBook)
        }
    }
    private var record: StationRecord {
        store.stationBook.record(key) ?? StationRecord(key: key)
    }
    private var entries: [JournalEntry] { store.entries(for: key) }
    private var standing: StationPromotion.Standing {
        StationPromotion.standing(for: key, entries: entries,
                                  documented: levels.map(\.key))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                signalRow
                if isDocumented {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if tab == .practice || !isDocumented {
                    practice
                } else {
                    production
                }
                Spacer(minLength: 20)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .topLeading)
            // Willing to be narrower; see FeaturePage.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: key) { _, _ in tab = .practice }
    }

    /// What you read and record.
    @ViewBuilder private var practice: some View {
        // Continuous puts the journey first: the reason to be on this page at
        // all is to go there.
        if continuous.enabled, key != "F1" {
            JourneyPanel(level: key)
        }
        descriptionSection
        entriesSection
        cartographerSection
        travelSection
        bedSection
        promotionSection
    }

    /// What you build. Only ever shown for a level that is on the map.
    @ViewBuilder private var production: some View {
        ClimbPathSection(level: key)
        // No `RenderedSessionsSection` here. Practice already lists the ready
        // sessions under "Getting here", and putting them on both tabs would
        // recreate across tabs exactly the duplication this page was merged to
        // remove. Playing a session is practice; building one is production.
        ScriptsSection(level: key)
        BriefingComposeSection(level: key)
        SegmentSection(level: key)
        UsedInSection(level: key)
        ReferenceSection(level: key)
        SourceTapeSection(level: key)
    }

    private var header: some View {
        let s = standing
        return VStack(alignment: .leading, spacing: 8) {
            Text(StationNaming.displayName(key: key, title: record.title,
                                           levelName: level?.name))
                .font(.largeTitle).foregroundStyle(Monokai.fg)
            HStack(spacing: 6) {
                Chip(text: key, color: Monokai.cyan)
                Chip(text: s.standingLabel,
                     color: s.isDocumented ? Monokai.green
                          : (s.isEligible ? Monokai.purple : Monokai.comment))
                // Which affirmation opens a dive here follows from how well
                // known the place is, so it is shown rather than hidden in a
                // setting the listener would have to remember.
                Chip(text: StationPromotion.affirmation(for: s), color: Monokai.yellow)
            }
            // **A subtitle is one line.** `notes` is an editorial gloss for a
            // documented level -- "way-station; review and planning" -- and the
            // header is the right place for it. Promotion writes something
            // else into the same field: the listener's whole account, joined
            // from their visits, so that the map carries it even if the
            // station book is lost. Rendered here in full that became three
            // paragraphs above the signal, saying exactly what the Description
            // panel below already said.
            if let notes = level?.notes, !notes.isEmpty, !notes.contains("\n") {
                Text(notes).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var signalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signal").font(.headline).foregroundStyle(Monokai.fg)
            if let st = station {
                HStack(spacing: 7) {
                    StatusDot(status: st.provenance == .measured ? .ok : .pending)
                    Text(st.hasDifferential
                         ? String(format: "%.2f Hz differential at %.0f Hz carrier",
                                  st.beatHz, st.carrierHz)
                         : "no differential — textures only")
                        .font(.callout).monospaced().foregroundStyle(Monokai.comment)
                }
                Text(provenanceNote(st.provenance))
                    .font(.caption).foregroundStyle(Monokai.comment)
            } else {
                Text("This station is below Focus 10, where the count is an induction rather than a ladder.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        // Every panel is as wide as the column. Without this the box shrinks
        // to its own text and sits visibly narrower than its neighbours.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func provenanceNote(_ p: ContinuousLadder.Provenance) -> String {
        switch p {
        case .measured: "Tuned or measured for this level."
        case .stated: "Stated in levels.json, not yet verified."
        case .estimated: "Interpolated from the nearest placed neighbours — an estimate, not a measurement."
        case .tuned: "Tuned by you from what you found here. Your practice, not a measured tape."
        }
    }

    /// Both accounts, side by side, and never one instead of the other.
    ///
    /// The station page used to show the found account only when nothing was
    /// published -- an `else if` -- so on every documented level the
    /// listener's own record of the place was invisible. That is the opposite
    /// of what "never merged" asks for: keeping them apart means showing both
    /// under their own headings, not letting the published one win.
    ///
    /// The coverage chip moved up here from a panel of its own. It answers
    /// "whose account is this" about the text directly beneath it, and as a
    /// separate section headed "Sources" it also collided with the source
    /// documents over on Production.
    private var descriptionSection: some View {
        let published = level?.published ?? ""
        let found = record.found ?? ""
        let coverage = store.library?.coverage(for: key, entries: entries.count) ?? .none
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Description").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                CoverageChip(coverage: coverage)
            }
            if published.isEmpty, found.isEmpty {
                Text("Nothing describes this level yet. What is here is yours to find.")
                    .font(.callout).foregroundStyle(Monokai.comment)
            }
            if !published.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PUBLISHED · MONROE INSTITUTE")
                        .font(.caption2).monospaced().foregroundStyle(Monokai.comment)
                    Text(published).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FOUND · YOUR ACCOUNT")
                        .font(.caption2).monospaced().foregroundStyle(Monokai.cyan)
                    Text(found).font(.callout).foregroundStyle(Monokai.fg)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !published.isEmpty, !found.isEmpty {
                Text("A source and an account answer different questions, so they are never merged.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Visits").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Text("\(entries.count) written")
                    .font(.caption).monospaced().foregroundStyle(Monokai.comment)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.written.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).monospaced().foregroundStyle(Monokai.cyan)
                        if let session = entry.session {
                            Text(session).font(.caption2).monospaced()
                                .foregroundStyle(Monokai.comment).lineLimit(1)
                        }
                        Spacer()
                        // Removing is easy on purpose: testing makes junk, and
                        // the alternative -- making writing harder -- would
                        // cost the real entries too.
                        Button {
                            JournalLog.remove(root: store.root, level: key, id: entry.id)
                            store.objectWillChange.send()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Monokai.comment)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this entry")
                    }
                    Text(entry.body).font(.callout).foregroundStyle(Monokai.fg)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            TextEditor(text: $draft)
                .font(.system(.callout, design: .default))
                .frame(minHeight: 70, maxHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("An entry is a visit. Three of them let this station be named.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                Spacer()
                Button("Add entry") { addEntry() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let writeError {
                Label(writeError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private var cartographerSection: some View {
        let written = entries.filter(\.isSubstantive)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Draft a description").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if drafting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("From your visits") { draftDescription(written) }
                        .disabled(written.count < StationPromotion.requiredEntries)
                }
            }
            Text(written.count < StationPromotion.requiredEntries
                 ? "Needs \(StationPromotion.requiredEntries) written visits. Your entries are the only source it may use."
                 : "Reads only what you wrote, at the time you wrote it. It adds nothing you did not observe.")
                .font(.caption).foregroundStyle(Monokai.comment)

            if let p = proposal {
                if p.enough {
                    Text(p.description)
                        .font(.callout).foregroundStyle(Monokai.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                    // Fidelity, not a warning. Sharing the listener's wording
                    // is the point here -- the inverse of the composer, where
                    // a lifted phrase means it paraphrased instead of writing.
                    let kept = Cartographer.retainedPhrases(description: p.description,
                                                            entries: written)
                    Text(kept.isEmpty
                         ? "Shares none of your phrasing — read it closely before accepting."
                         : "Keeps \(kept.count) phrase\(kept.count == 1 ? "" : "s") of your own wording.")
                        .font(.caption)
                        .foregroundStyle(kept.isEmpty ? Monokai.orange : Monokai.green)
                    HStack {
                        Button("Accept as the description") { accept(p) }
                            .buttonStyle(.borderedProminent).tint(Monokai.green)
                        Button("Discard") { proposal = nil }
                        Spacer()
                    }
                } else {
                    Label(p.description.isEmpty
                          ? "Not enough here to describe it honestly yet."
                          : p.description, systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(Monokai.orange)
                    Text("Refusing is a correct answer. Another visit may be all it needs.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            }
            if let draftError {
                Label(draftError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func draftDescription(_ written: [JournalEntry]) {
        drafting = true; draftError = nil; proposal = nil
        Task {
            do {
                proposal = try await OllamaClient().describeStation(level: key, entries: written)
            } catch {
                draftError = "the cartographer did not answer: \(error.localizedDescription)"
            }
            drafting = false
        }
    }

    private func accept(_ p: CartographerProposal) {
        var r = record
        r.found = p.description
        if r.title == nil, let name = offeredName(p.title) { r.title = name }
        store.updateStation(r)
        proposal = nil
    }

    /// A name only if it is one.
    ///
    /// **The model will hand back the level key.** Asked for "the listener's
    /// own name for the place, if their entries settle on one", an 8B model
    /// given entries that never named anything answered `"F16"` -- and it was
    /// stored, because it was not empty. Nothing looked wrong: the header
    /// renders `record.title ?? level?.name ?? key`, so a title of "F16" is
    /// indistinguishable from no title at all.
    ///
    /// It is not harmless. The station is recorded as named when the listener
    /// never named it, and promotion passes `title` through as the level's
    /// name, so the map would have gained "F16" where it should read
    /// "Focus 16". The unnamed case is the *ordinary* one -- most stations are
    /// reached long before they are called anything -- so this rejects the
    /// key, and the default the key would have produced, rather than trusting
    /// the model to have withheld a name it was asked for.
    private func offeredName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let flat = name.lowercased().replacingOccurrences(of: " ", with: "")
        let number = key.uppercased().dropFirst()
        guard flat != key.lowercased(), flat != "focus\(number)" else { return nil }
        return name
    }

    /// The default visit, offered rather than described.
    ///
    /// What stood here was a sentence: *"No assembled session reaches this
    /// station. Continuous mode climbs to it from wherever you are."* True, and
    /// a dead end — it named a second feature the listener had to go and find,
    /// on a page that had just finished telling them about this place's bed,
    /// its briefing and its name. Every station has a visit now, so the page
    /// can offer the thing itself.
    ///
    /// The density is chosen from how many times this station has been reached
    /// before, and said out loud, because a session that quietly decides how
    /// much to explain should say that it decided.
    @ViewBuilder private var visitOffer: some View {
        let seen = SessionGuidance.completions(atLevel: key, ledger: activity.snapshot())
        let suggested = SessionGuidance.suggestedVerbosity(completionsAtLevel: seen)
        if let lib = store.library, let visit = lib.visit(to: key, standing: standing) {
            Text(visit.usesLadder
                 ? "No tape describes the way here, so the visit counts up the ladder one station at a time."
                 : "A plain visit: down to Focus 10, up to \(key), time there, and back.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
            Text(SessionGuidance.rationale(completionsAtLevel: seen))
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Assemble a visit") { assembleVisit(visit, verbosity: suggested) }
                    .disabled(renderer.voice.isEmpty)
                if visit.isDerived {
                    Text("Derived now, from the library as it stands.")
                        .font(.caption2).foregroundStyle(Monokai.comment)
                }
            }
            if let visitError { Text(visitError).font(.caption).foregroundStyle(Monokai.red) }
        } else {
            Text("No route reaches this station yet. Continuous mode climbs to it from wherever you are.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assembleVisit(_ visit: DefaultVisit, verbosity: Int) {
        guard let lib = store.library else { return }
        guard let plan = lib.visitPlan(visit, voice: renderer.voice, verbosity: verbosity,
                                       isRendered: { output, file in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
            let dir = AppPaths.rendered.appending(path: renderer.voice)
            let renderKey = VoiceProfileIO.load(
                from: AppPaths.voice(renderer.voice).appending(path: "profile.json")).renderKey
            return RenderPlan.isCurrent(output, source: source, in: dir, renderKey: renderKey)
        }) else {
            visitError = "this station's visit could not be planned"
            return
        }
        visitError = renderer.enqueueVisit(visit, verbosity: verbosity, plan: plan)
            ? nil : "could not queue the visit"
    }

    /// Getting here, and what already exists that does.
    ///
    /// A documented level has authored sessions; a station nobody has
    /// described has none, and never will until it is promoted -- so the way
    /// there is Continuous, which is exactly what Continuous is for.
    ///
    /// The list itself is `RenderedSessionsSection`, which this used to
    /// duplicate: both read the same renders off the same Focus album and both
    /// opened the same track. Only the empty case and the Continuous toggle
    /// were ever this section's own.
    private var travelSection: some View {
        let sessions = store.library?.focus.first { $0.key == key }?.renders ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if sessions.isEmpty {
                Text("Getting here").font(.headline).foregroundStyle(Monokai.fg)
                visitOffer
            } else {
                RenderedSessionsSection(level: key)
            }
            Toggle("Continuous mode", isOn: $continuous.enabled)
                .help("Choose a station and be carried there from wherever you are")
            Text(continuous.enabled
                 ? "Choosing a station in the rail travels there and holds."
                 : "With Continuous on, the rail lists every station, not only the described ones.")
                .font(.caption).foregroundStyle(Monokai.comment)
        }
        // Every panel is as wide as the column. Without this the box shrinks
        // to its own text and sits visibly narrower than its neighbours.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private var bedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bed").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Toggle("Edit", isOn: $editingBed).toggleStyle(.switch).controlSize(.small)
            }
            if editingBed {
                HStack(spacing: 10) {
                    LabeledContent("beat Hz") {
                        TextField(station.map { String(format: "%.2f", $0.beatHz) } ?? "",
                                  text: $beatDraft)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    LabeledContent("carrier Hz") {
                        TextField(station.map { String(format: "%.0f", $0.carrierHz) } ?? "",
                                  text: $carrierDraft)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                }
                HStack {
                    Button("Save tuning") { saveTuning() }
                        .disabled(Double(beatDraft) == nil && Double(carrierDraft) == nil)
                    if record.isTuned {
                        Button("Revert to the ladder") { revertTuning() }
                    }
                    Spacer()
                }
                Text("A tuned station is your practice, not a measured tape, and is labelled so.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            } else if record.isTuned {
                Text("Tuned by you. Turn Edit on to change or revert it.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            } else {
                Text("Using the ladder's value. Turn Edit on if you have found a better one.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func saveTuning() {
        var r = record
        if let b = Double(beatDraft), b >= 0 { r.beatHz = b }
        if let c = Double(carrierDraft), c > 0 { r.carrierHz = c }
        store.updateStation(r)
        beatDraft = ""; carrierDraft = ""
    }

    private func revertTuning() {
        var r = record
        r.beatHz = nil; r.carrierHz = nil
        store.updateStation(r)
    }

    private var promotionSection: some View {
        let s = standing
        return VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline).foregroundStyle(Monokai.fg)
            if s.isDocumented {
                Label("Described — already on the documented map.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Monokai.green)
            } else if s.isEligible {
                Label("Ready to name.", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(Monokai.purple)
                Text("Promoting adds this station to the map as found, carrying your account. "
                     + "It writes no published description, because none exists.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                Button("Promote to a level") { promote() }
                    .buttonStyle(.borderedProminent).tint(Monokai.purple)
                if let promoteError {
                    Label(promoteError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Monokai.red)
                }
            } else {
                Label(s.outstanding ?? "Not yet.", systemImage: "circle.dotted")
                    .font(.callout).foregroundStyle(Monokai.comment)
            }

            Divider().overlay(Monokai.inset)
            Toggle(isOn: Binding(
                get: { record.channelRestriction },
                set: { var r = record; r.channelRestriction = $0; store.updateStation(r) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak the channel restriction before arriving")
                    Text("Sets what you are open to. Not a barrier — the authored fixed words.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func addEntry() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            try JournalLog.append(root: store.root, level: key, body: body)
            draft = ""
            writeError = nil
            store.objectWillChange.send()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func promote() {
        var r = record
        r.promoted = true
        if r.found == nil || r.found?.isEmpty == true {
            // The account is what the listener already wrote. Joined rather
            // than summarised: nothing here paraphrases them.
            r.found = entries.map(\.body).joined(separator: "\n\n")
        }

        let signal = station
        let level = StationPromotion.promotedLevel(
            key: key, name: r.title,
            beatHz: signal?.beatHz ?? 0, carrier: signal?.carrierHz ?? 110,
            notes: r.found ?? "")
        guard let updated = StationPromotion.insert(level, into: levels) else {
            promoteError = "\(key) is already on the map."
            return
        }
        do {
            try LevelsIO.save(updated, root: store.root)
            store.updateStation(r)
            store.reload()
            promoteError = nil
        } catch {
            promoteError = "could not write levels.json: \(error.localizedDescription)"
        }
    }
}
