import Foundation
import GatewaySync

/// The desktop's read-only projection onto the companion protocol. It exports
/// values, never source files or absolute paths, and keeps each provenance
/// class in its own field.
public enum GatewaySyncProjection {
    /// Exact render assets exposed by protocol id. The id has already passed
    /// the wire contract's path-safe validation; callers still receive URLs
    /// only inside the scanned library rather than resolving arbitrary input.
    public static func audioAssets(library: Library) -> [String: URL] {
        var assets: [String: URL] = [:]
        for folder in library.focus {
            for directory in folder.renders {
                let id = directory.lastPathComponent
                let wav = directory.appending(path: "session.wav")
                guard SyncContract.validIdentifier(id), assets[id] == nil,
                      let manifest = SessionManifestIO.load(directory.appending(path: "manifest.json")),
                      manifest.bedPlan(levels: library.levels, signals: library.signals) != nil,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: wav.path),
                      (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
                else { continue }
                assets[id] = wav
                for (index, cue) in manifest.media.enumerated() {
                    let mediaID = "\(id)-media-\(index)"
                    let mediaURL = library.root.appending(path: "library").appending(path: cue.file)
                    guard SyncContract.validIdentifier(mediaID), assets[mediaID] == nil,
                          safeRelativePath(cue.file),
                          FileManager.default.fileExists(atPath: mediaURL.path)
                    else { continue }
                    assets[mediaID] = mediaURL
                }
                if manifest.purpose == .continuousJourney,
                   let exit = continuousExitURL(manifest: manifest, library: library) {
                    assets["\(id)-exit"] = exit
                }
                if manifest.purpose == .continuousJourney,
                   let level = manifest.level,
                   let catalog = try? AudioAssetCatalog.load(root: library.root),
                   let signal = exactlyOne(catalog.matches(role: .returnSignal, level: level)),
                   signal.hasSafeRelativePath,
                   FileManager.default.fileExists(atPath: signal.url(in: library.root).path) {
                    assets[signal.id] = signal.url(in: library.root)
                }
            }
        }
        return assets
    }

    public static func snapshot(library: Library, stationBook: StationBook,
                                generatedAt: Date = Date(),
                                desktopID: String = "desktop") -> SyncSnapshot {
        let levels = Dictionary(uniqueKeysWithValues: library.levels.map { ($0.key.uppercased(), $0) })
        let records = Dictionary(uniqueKeysWithValues: stationBook.records.map {
            ($0.key.uppercased(), $0)
        })
        var orderedKeys = library.levels.map { $0.key.uppercased() }
        for key in records.keys.sorted(by: focusOrder) where !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }

        let folders = Dictionary(uniqueKeysWithValues: library.focus.map {
            ($0.key.uppercased(), $0)
        })
        let stations = orderedKeys.map { key -> SyncStation in
            let level = levels[key]
            let record = records[key]
            let entries = JournalLog.entries(root: library.root, level: key)
            let standingBody = folders[key].map { NoteIO.load(from: $0.noteURL).body }
            let standing = standingBody?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tuned = record?.isTuned == true
            return SyncStation(
                key: key,
                documentedName: nonempty(level?.name),
                listenerName: nonempty(record?.title),
                documentedDescription: nonempty(level?.published),
                listenerDescription: nonempty(record?.found),
                standingNote: nonempty(standing),
                promoted: record?.promoted ?? false,
                beatHz: record?.beatHz ?? level?.beatHz,
                carrierHz: record?.carrierHz ?? level?.carrier,
                beatProvenance: tuned ? "listener-tuned"
                    : (level?.beatVerified == true ? "library-verified" : "estimated"),
                visitCount: entries.filter(\.isSubstantive).count)
        }

        var sessions: [SyncSession] = []
        let profile = AudioProfileIO.load(root: library.root)
        let syncMix = SyncAudioMix(
            speech: profile.speech, resonantTuning: profile.resonantTuning,
            returnSignal: profile.returnSignal, hemiSync: profile.hemiSync,
            pinkNoise: profile.pinkNoise, whiteNoise: profile.whiteNoise,
            surf: profile.surf, master: profile.master)
        for folder in library.focus {
            for directory in folder.renders {
                let wav = directory.appending(path: "session.wav")
                guard let manifest = SessionManifestIO.load(directory.appending(path: "manifest.json")),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: wav.path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      size > 0 else { continue }
                let id = directory.lastPathComponent
                guard SyncContract.validIdentifier(id) else { continue }
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
                guard let bedPlan = manifest.bedPlan(
                    levels: library.levels, signals: library.signals) else { continue }
                let bed = SyncBedPlan(stages: bedPlan.stages.map {
                        SyncBedPlan.Stage(start: $0.start, end: $0.end, level: $0.level,
                                          carrier: $0.carrier, beat: $0.beat,
                                          surf: $0.surf, pink: $0.pink, white: $0.white)
                    }, rampSeconds: bedPlan.rampSeconds, leadSeconds: bedPlan.leadSeconds,
                       duration: bedPlan.duration)
                let media = manifest.media.enumerated().compactMap { index, cue -> SyncMediaCue? in
                    let mediaID = "\(id)-media-\(index)"
                    let url = library.root.appending(path: "library").appending(path: cue.file)
                    guard safeRelativePath(cue.file),
                          let reference = assetReference(id: mediaID, url: url) else { return nil }
                    return SyncMediaCue(
                        role: cue.role.rawValue, startSeconds: cue.startSeconds,
                        seconds: cue.seconds, fit: cue.fit.rawValue,
                        crossfadeSeconds: cue.crossfadeSeconds,
                        edgeFadeSeconds: cue.edgeFadeSeconds, gain: cue.gain,
                        audio: reference)
                }
                let exitNarration: SyncAssetReference? = {
                    guard manifest.purpose == .continuousJourney,
                          let url = continuousExitURL(manifest: manifest, library: library)
                    else { return nil }
                    return assetReference(id: "\(id)-exit", url: url)
                }()
                let continuousReturnSignal: SyncMediaCue? = {
                    guard manifest.purpose == .continuousJourney,
                          let level = manifest.level,
                          let catalog = try? AudioAssetCatalog.load(root: library.root),
                          let signal = exactlyOne(
                            catalog.matches(role: .returnSignal, level: level)),
                          signal.hasSafeRelativePath,
                          let reference = assetReference(id: signal.id,
                                                        url: signal.url(in: library.root))
                    else { return nil }
                    return SyncMediaCue(
                        role: signal.role.rawValue, startSeconds: 0,
                        seconds: signal.seconds, fit: signal.fit.rawValue,
                        crossfadeSeconds: signal.crossfadeSeconds,
                        edgeFadeSeconds: signal.edgeFadeSeconds, gain: signal.gain,
                        audio: reference)
                }()
                // A Continuous session without its separately authored exit
                // is a trap: the phone could hold the listener at a station
                // and offer no valid way back. Keep older/incomplete renders
                // off mobile until the package is whole.
                if manifest.purpose == .continuousJourney,
                   exitNarration == nil || continuousReturnSignal == nil {
                    continue
                }
                sessions.append(SyncSession(
                    id: id,
                    title: SessionNaming.displayName(directory: directory, manifest: manifest),
                    destination: manifest.level,
                    seconds: manifest.seconds,
                    voice: manifest.voice,
                    audio: SyncAssetReference(
                        id: id, contentType: "audio/wav", bytes: size,
                        etag: "\(size)-\(Int64(modified))",
                        path: GatewaySyncProtocol.Endpoint.assets + "/" + encodedID),
                    bed: bed, mix: syncMix, media: media,
                    purpose: manifest.purpose.rawValue,
                    exitNarration: exitNarration,
                    continuousReturnSignal: continuousReturnSignal))
            }
        }
        sessions.sort { $0.id > $1.id }

        var journal: [SyncJournalEntry] = []
        for folder in library.focus {
            for entry in JournalLog.entries(root: library.root, level: folder.key) {
                let wireID: String
                if entry.id.hasPrefix("sync-") {
                    wireID = String(entry.id.dropFirst("sync-".count))
                } else {
                    wireID = "desktop-\(entry.level.lowercased())-\(entry.id)"
                }
                journal.append(SyncJournalEntry(
                    id: wireID, level: entry.level, sessionID: entry.session,
                    written: ISO8601DateFormatter().string(from: entry.written),
                    body: entry.body, originDeviceID: entry.originDeviceID ?? desktopID))
            }
        }
        journal.sort { $0.written < $1.written }

        var snapshot = SyncSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            stations: stations, sessions: sessions, journalEntries: journal)
        var canonical = snapshot
        canonical.generatedAt = "1970-01-01T00:00:00Z"
        canonical.revision = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        snapshot.revision = (try? encoder.encode(canonical)).map(FileIntegrity.sha256(of:)) ?? ""
        return snapshot
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func assetReference(id: String, url: URL) -> SyncAssetReference? {
        guard SyncContract.validIdentifier(id),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return SyncAssetReference(
            id: id, contentType: "audio/wav", bytes: size,
            etag: "\(size)-\(Int64(modified))",
            path: GatewaySyncProtocol.Endpoint.assets + "/" + encoded)
    }

    private static func continuousExitURL(manifest: SessionManifest,
                                          library: Library) -> URL? {
        guard let exit = manifest.exit, exit.hasSafePaths else { return nil }
        let source = library.root.appending(path: exit.sourceFile)
        let rendered = library.root.appending(path: "segments-rendered/\(manifest.voice)")
        let profile = VoiceProfileIO.load(
            from: library.root.appending(path: "voices/\(manifest.voice)/profile.json"))
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              RenderPlan.isCurrent(exit.outputName, source: text,
                                   in: rendered, renderKey: profile.renderKey) else { return nil }
        let url = rendered.appending(path: exit.outputName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func exactlyOne<T>(_ values: [T]) -> T? {
        values.count == 1 ? values[0] : nil
    }

    private static func focusOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = Int(lhs.drop(while: { !$0.isNumber }))
        let right = Int(rhs.drop(while: { !$0.isNumber }))
        if let left, let right, left != right { return left < right }
        return lhs < rhs
    }
}

/// Receipts contain only operation id and digest. They prove idempotency
/// without making a second copy of private journal text in `memory/`.
private struct SyncInboxReceipts: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var digests: [String: String] = [:]
}

public enum DesktopSyncInbox {
    public static func receiptURL(root: URL) -> URL {
        root.appending(path: "memory/sync-inbox.json")
    }

    /// Apply a companion batch. The eventual HTTP service must serialize calls
    /// to this method; the file-backed stores remain the desktop authority.
    public static func apply(_ request: SyncPushRequest, root: URL) -> SyncPushResponse {
        let globalIssues = SyncContract.validate(request).filter {
            !$0.path.hasPrefix("operations[")
        }
        guard globalIssues.isEmpty else {
            let message = globalIssues.map { "\($0.path): \($0.message)" }
                .joined(separator: "; ")
            return SyncPushResponse(snapshotChanged: false, results: request.operations.map {
                SyncOperationResult(id: $0.id, status: GatewaySyncProtocol.ResultStatus.rejected,
                                    message: message)
            })
        }

        var receipts = loadReceipts(root: root)
        var results: [SyncOperationResult] = []
        var changed = false
        var activity: ActivityLedger?
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for operation in request.operations {
            let issues = SyncContract.validate(operation)
            if !issues.isEmpty {
                results.append(.init(
                    id: operation.id, status: GatewaySyncProtocol.ResultStatus.rejected,
                    message: issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")))
                continue
            }
            let origins = [operation.journalEntry?.originDeviceID,
                           operation.completion?.originDeviceID,
                           operation.generationRequest?.originDeviceID].compactMap { $0 }
            guard origins.allSatisfy({ $0 == request.clientID }) else {
                results.append(.init(id: operation.id,
                                     status: GatewaySyncProtocol.ResultStatus.rejected,
                                     message: "payload origin does not match authenticated client"))
                continue
            }
            let digest = (try? encoder.encode(operation)).map(FileIntegrity.sha256(of:)) ?? ""
            if let previous = receipts.digests[operation.id] {
                results.append(.init(
                    id: operation.id,
                    status: previous == digest
                        ? GatewaySyncProtocol.ResultStatus.duplicate
                        : GatewaySyncProtocol.ResultStatus.conflict,
                    message: previous == digest ? nil : "operation id was already used"))
                continue
            }

            do {
                let status: String
                switch operation.kind {
                case GatewaySyncProtocol.OperationKind.journalAppend:
                    let entry = operation.journalEntry!
                    guard let written = parseTimestamp(entry.written) else {
                        throw SyncInboxError.invalidTimestamp
                    }
                    switch try JournalLog.importEntry(
                        root: root, id: entry.id, level: entry.level,
                        session: entry.sessionID, written: written, body: entry.body,
                        originDeviceID: entry.originDeviceID) {
                    case .inserted:
                        status = GatewaySyncProtocol.ResultStatus.applied
                        changed = true
                    case .duplicate:
                        status = GatewaySyncProtocol.ResultStatus.duplicate
                    case .conflict:
                        status = GatewaySyncProtocol.ResultStatus.conflict
                    }
                case GatewaySyncProtocol.OperationKind.completionAppend:
                    let completion = operation.completion!
                    guard let finished = parseTimestamp(completion.finished) else {
                        throw SyncInboxError.invalidTimestamp
                    }
                    if activity == nil { activity = try ActivityStore.load(root: root) }
                    if let existing = activity!.completions.first(where: {
                        $0.syncID == completion.id
                    }) {
                        let same = existing.track == completion.sessionID
                            && existing.level == completion.level
                            && abs(existing.seconds - completion.seconds) < 0.001
                            && abs(existing.finished.timeIntervalSince(finished)) < 1
                            && existing.originDeviceID == completion.originDeviceID
                        status = same ? GatewaySyncProtocol.ResultStatus.duplicate
                            : GatewaySyncProtocol.ResultStatus.conflict
                    } else {
                        var next = activity!
                        next.record(.init(
                            track: completion.sessionID, level: completion.level,
                            seconds: completion.seconds, finished: finished,
                            syncID: completion.id,
                            originDeviceID: completion.originDeviceID))
                        next.addListeningTime(completion.seconds)
                        try ActivityStore.save(next, root: root)
                        activity = next
                        changed = true
                        status = GatewaySyncProtocol.ResultStatus.applied
                    }
                case GatewaySyncProtocol.OperationKind.generationRequest:
                    switch try MobileGenerationQueue.enqueue(operation.generationRequest!,
                                                             root: root) {
                    case .inserted:
                        status = GatewaySyncProtocol.ResultStatus.applied
                    case .duplicate:
                        status = GatewaySyncProtocol.ResultStatus.duplicate
                    case .conflict:
                        status = GatewaySyncProtocol.ResultStatus.conflict
                    }
                default:
                    throw SyncInboxError.unsupportedOperation
                }
                if status != GatewaySyncProtocol.ResultStatus.conflict {
                    receipts.digests[operation.id] = digest
                }
                results.append(.init(id: operation.id, status: status))
            } catch {
                results.append(.init(id: operation.id,
                                     status: GatewaySyncProtocol.ResultStatus.rejected,
                                     message: error.localizedDescription))
            }
        }

        saveReceipts(receipts, root: root)
        return SyncPushResponse(snapshotChanged: changed, results: results)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let basic = ISO8601DateFormatter()
        if let date = basic.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private static func loadReceipts(root: URL) -> SyncInboxReceipts {
        guard let data = try? Data(contentsOf: receiptURL(root: root)),
              let receipts = try? JSONDecoder().decode(SyncInboxReceipts.self, from: data),
              receipts.schemaVersion == SyncInboxReceipts.currentSchemaVersion else {
            return SyncInboxReceipts()
        }
        return receipts
    }

    private static func saveReceipts(_ receipts: SyncInboxReceipts, root: URL) {
        let url = receiptURL(root: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(receipts) { try? data.write(to: url, options: .atomic) }
    }
}

private enum SyncInboxError: Error, LocalizedError {
    case invalidTimestamp
    case unsupportedOperation

    var errorDescription: String? {
        switch self {
        case .invalidTimestamp: "The companion timestamp is invalid."
        case .unsupportedOperation: "The companion operation is not supported."
        }
    }
}
