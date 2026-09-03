import Foundation

/// The public, language-neutral boundary between an authoritative Gateway
/// Forge desktop and a companion. Nothing here knows a filesystem path,
/// SwiftUI type, audio engine, Ollama model, or private app service.
public enum GatewaySyncProtocol {
    public static let currentVersion = 1
    public static let serviceType = "_gatewayforge._tcp"
    public static let apiRoot = "/gateway-sync/v1"

    public enum Endpoint {
        public static let hello = apiRoot + "/hello"
        public static let snapshot = apiRoot + "/snapshot"
        public static let push = apiRoot + "/push"
        public static let assets = apiRoot + "/assets"
        public static let pair = apiRoot + "/pair"
    }

    public enum Capability {
        public static let snapshot = "snapshot"
        public static let journalAppend = "journal.append"
        public static let completionAppend = "completion.append"
        public static let generationRequest = "generation.request"
        public static let audioDownload = "audio.download"
    }

    public enum OperationKind {
        public static let journalAppend = "journal.append"
        public static let completionAppend = "completion.append"
        public static let generationRequest = "generation.request"
    }

    public enum ResultStatus {
        public static let applied = "applied"
        public static let duplicate = "duplicate"
        public static let conflict = "conflict"
        public static let rejected = "rejected"
    }
}

/// Bonjour-visible information. It deliberately contains no journal facts,
/// library revision, pairing code, bearer token, user name, or absolute path.
public struct SyncAdvertisement: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverID: String
    public var displayName: String

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                serverID: String, displayName: String) {
        self.protocolVersion = protocolVersion
        self.serverID = serverID
        self.displayName = displayName
    }
}

/// Returned only over the TLS connection after a companion authenticates.
public struct SyncHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverID: String
    public var displayName: String
    /// Opaque content revision. Clients compare it for equality; they never
    /// parse it or assume it is numeric.
    public var snapshotRevision: String
    public var capabilities: [String]

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                serverID: String, displayName: String, snapshotRevision: String,
                capabilities: [String]) {
        self.protocolVersion = protocolVersion
        self.serverID = serverID
        self.displayName = displayName
        self.snapshotRevision = snapshotRevision
        self.capabilities = capabilities
    }
}

public struct SyncPairingChallenge: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverID: String
    public var tlsFingerprint: String
    public var expiresAt: String
    public var codeLength: Int

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                serverID: String, tlsFingerprint: String,
                expiresAt: String, codeLength: Int = 6) {
        self.protocolVersion = protocolVersion
        self.serverID = serverID
        self.tlsFingerprint = tlsFingerprint
        self.expiresAt = expiresAt
        self.codeLength = codeLength
    }
}

public struct SyncPairingRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var clientID: String
    public var displayName: String
    public var oneTimeCode: String

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                clientID: String, displayName: String, oneTimeCode: String) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.displayName = displayName
        self.oneTimeCode = oneTimeCode
    }
}

public struct SyncPairingResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var clientID: String
    public var bearerToken: String
    public var issuedAt: String

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                clientID: String, bearerToken: String, issuedAt: String) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.bearerToken = bearerToken
        self.issuedAt = issuedAt
    }
}

/// The private QR payload used to bootstrap the first encrypted connection.
/// It is part of the portable contract because every companion must parse it;
/// it is never Bonjour metadata and must never be logged or persisted after
/// the resulting device credential has been stored securely.
public struct SyncPairingPayload: Equatable, Sendable {
    public var serverID: String
    public var serviceName: String
    public var tlsIdentity: Data
    public var tlsSecret: Data
    public var oneTimeCode: String
    public var expiresAt: Date

    public init(serverID: String, serviceName: String = "Gateway Forge",
                tlsIdentity: Data, tlsSecret: Data,
                oneTimeCode: String, expiresAt: Date) {
        self.serverID = serverID
        self.serviceName = serviceName
        self.tlsIdentity = tlsIdentity
        self.tlsSecret = tlsSecret
        self.oneTimeCode = oneTimeCode
        self.expiresAt = expiresAt
    }

    public init?(url: URL) {
        guard url.scheme == "gatewayforge", url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        let serviceName = values["service"] ?? "Gateway Forge"
        guard values["v"] == String(GatewaySyncProtocol.currentVersion),
              let serverID = values["server"], SyncContract.validIdentifier(serverID),
              !serviceName.isEmpty, serviceName.utf8.count <= 63,
              let identity = values["identity"].flatMap(Data.init(base64URL:)),
              !identity.isEmpty, identity.count <= 128,
              let secret = values["secret"].flatMap(Data.init(base64URL:)),
              secret.count == 32,
              let code = values["code"], (20...256).contains(code.count),
              let expires = values["expires"].flatMap(parseSyncTimestamp)
        else { return nil }
        self.init(serverID: serverID, serviceName: serviceName,
                  tlsIdentity: identity, tlsSecret: secret,
                  oneTimeCode: code, expiresAt: expires)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "gatewayforge"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(GatewaySyncProtocol.currentVersion)),
            URLQueryItem(name: "server", value: serverID),
            URLQueryItem(name: "service", value: serviceName),
            URLQueryItem(name: "identity", value: tlsIdentity.base64URLEncodedString()),
            URLQueryItem(name: "secret", value: tlsSecret.base64URLEncodedString()),
            URLQueryItem(name: "code", value: oneTimeCode),
            URLQueryItem(name: "expires", value: ISO8601DateFormatter().string(from: expiresAt)),
        ]
        return components.url
    }
}

/// Published and lived descriptions remain two different fields on the wire,
/// preserving the same provenance boundary as the desktop library.
public struct SyncStation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var documentedName: String?
    public var listenerName: String?
    public var documentedDescription: String?
    public var listenerDescription: String?
    /// The standing, editable note about the level. This remains distinct from
    /// both a promoted Cartographer description and dated visit entries.
    public var standingNote: String?
    public var promoted: Bool
    public var beatHz: Double?
    public var carrierHz: Double?
    public var beatProvenance: String
    public var visitCount: Int

    public init(key: String, documentedName: String? = nil,
                listenerName: String? = nil, documentedDescription: String? = nil,
                listenerDescription: String? = nil, standingNote: String? = nil,
                promoted: Bool = false,
                beatHz: Double? = nil, carrierHz: Double? = nil,
                beatProvenance: String, visitCount: Int) {
        self.key = key
        self.documentedName = documentedName
        self.listenerName = listenerName
        self.documentedDescription = documentedDescription
        self.listenerDescription = listenerDescription
        self.standingNote = standingNote
        self.promoted = promoted
        self.beatHz = beatHz
        self.carrierHz = carrierHz
        self.beatProvenance = beatProvenance
        self.visitCount = visitCount
    }
}

public struct SyncAssetReference: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var contentType: String
    public var bytes: Int64
    public var etag: String
    public var sha256: String?
    /// API-relative URL. Never a desktop filesystem path.
    public var path: String

    public init(id: String, contentType: String, bytes: Int64, etag: String,
                sha256: String? = nil, path: String) {
        self.id = id
        self.contentType = contentType
        self.bytes = bytes
        self.etag = etag
        self.sha256 = sha256
        self.path = path
    }
}

/// A platform-neutral description of the live bed. Companions generate this
/// locally so the binaural differential remains stereo and continuous rather
/// than receiving a narration-only WAV or a lossy pre-mix.
public struct SyncBedPlan: Codable, Equatable, Sendable {
    public struct Stage: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var level: String
        public var carrier: Double
        public var beat: Double
        public var surf: Double
        public var pink: Double
        public var white: Double

        public init(start: Double, end: Double, level: String,
                    carrier: Double, beat: Double, surf: Double,
                    pink: Double, white: Double) {
            self.start = start; self.end = end; self.level = level
            self.carrier = carrier; self.beat = beat
            self.surf = surf; self.pink = pink; self.white = white
        }
    }

    public var stages: [Stage]
    public var rampSeconds: Double
    public var leadSeconds: Double
    public var duration: Double

    public init(stages: [Stage], rampSeconds: Double, leadSeconds: Double,
                duration: Double) {
        self.stages = stages; self.rampSeconds = rampSeconds
        self.leadSeconds = leadSeconds; self.duration = duration
    }
}

/// Listening levels travel with the session because these are playback
/// choices, not render settings. A companion should sound like the calibrated
/// desktop, not silently substitute its own defaults.
public struct SyncAudioMix: Codable, Equatable, Sendable {
    public var speech: Double
    public var resonantTuning: Double
    public var returnSignal: Double
    public var hemiSync: Double
    public var pinkNoise: Double
    public var whiteNoise: Double
    public var surf: Double
    public var master: Double

    public init(speech: Double, resonantTuning: Double, returnSignal: Double,
                hemiSync: Double, pinkNoise: Double, whiteNoise: Double,
                surf: Double, master: Double) {
        self.speech = speech; self.resonantTuning = resonantTuning
        self.returnSignal = returnSignal; self.hemiSync = hemiSync
        self.pinkNoise = pinkNoise; self.whiteNoise = whiteNoise
        self.surf = surf; self.master = master
    }

    public static let standard = SyncAudioMix(
        speech: 1, resonantTuning: 0.5, returnSignal: 0.85,
        hemiSync: 0.45, pinkNoise: 0.35, whiteNoise: 0,
        surf: 0.30, master: 0.8)
}

public struct SyncMediaCue: Codable, Equatable, Sendable, Identifiable {
    public var id: String { audio.id }
    public var role: String
    public var startSeconds: Double
    public var seconds: Double
    public var fit: String
    public var crossfadeSeconds: Double
    public var edgeFadeSeconds: Double
    public var gain: Double
    public var audio: SyncAssetReference

    public init(role: String, startSeconds: Double, seconds: Double,
                fit: String, crossfadeSeconds: Double, edgeFadeSeconds: Double,
                gain: Double, audio: SyncAssetReference) {
        self.role = role; self.startSeconds = startSeconds; self.seconds = seconds
        self.fit = fit; self.crossfadeSeconds = crossfadeSeconds
        self.edgeFadeSeconds = edgeFadeSeconds; self.gain = gain; self.audio = audio
    }
}

public struct SyncSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var destination: String?
    public var seconds: Double
    public var voice: String
    public var audio: SyncAssetReference
    public var bed: SyncBedPlan?
    public var mix: SyncAudioMix?
    public var media: [SyncMediaCue]?
    /// `continuousJourney` keeps the final bed stage alive after narration.
    /// Optional so snapshots cached by an older companion remain readable.
    public var purpose: String?
    /// Continuous return audio is deliberately outside the main timeline and
    /// cannot start until the listener explicitly asks to return.
    public var exitNarration: SyncAssetReference?
    public var continuousReturnSignal: SyncMediaCue?

    public init(id: String, title: String, destination: String?, seconds: Double,
                voice: String, audio: SyncAssetReference,
                bed: SyncBedPlan? = nil, mix: SyncAudioMix? = nil,
                media: [SyncMediaCue]? = nil, purpose: String? = nil,
                exitNarration: SyncAssetReference? = nil,
                continuousReturnSignal: SyncMediaCue? = nil) {
        self.id = id
        self.title = title
        self.destination = destination
        self.seconds = seconds
        self.voice = voice
        self.audio = audio
        self.bed = bed
        self.mix = mix
        self.media = media
        self.purpose = purpose
        self.exitNarration = exitNarration
        self.continuousReturnSignal = continuousReturnSignal
    }

    public var isContinuous: Bool { purpose == "continuousJourney" }
}

public struct SyncJournalEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var level: String
    public var sessionID: String?
    public var written: String
    public var body: String
    public var originDeviceID: String

    public init(id: String, level: String, sessionID: String? = nil,
                written: String, body: String, originDeviceID: String) {
        self.id = id
        self.level = level
        self.sessionID = sessionID
        self.written = written
        self.body = body
        self.originDeviceID = originDeviceID
    }
}

public struct SyncCompletion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var level: String?
    public var seconds: Double
    public var finished: String
    public var originDeviceID: String

    public init(id: String, sessionID: String, level: String? = nil,
                seconds: Double, finished: String, originDeviceID: String) {
        self.id = id
        self.sessionID = sessionID
        self.level = level
        self.seconds = seconds
        self.finished = finished
        self.originDeviceID = originDeviceID
    }
}

/// A durable request for the authoritative desktop to generate a session.
/// The phone chooses only an existing station, the established verbosity
/// axis, and visit versus Continuous. It never sends GWS, prompts, or paths.
public struct SyncGenerationRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Mode {
        public static let visit = "visit"
        public static let continuous = "continuous"
    }

    public var id: String
    public var destination: String
    public var mode: String
    public var verbosity: Int
    public var requestedAt: String
    public var originDeviceID: String

    public init(id: String, destination: String, mode: String, verbosity: Int,
                requestedAt: String, originDeviceID: String) {
        self.id = id; self.destination = destination; self.mode = mode
        self.verbosity = verbosity; self.requestedAt = requestedAt
        self.originDeviceID = originDeviceID
    }
}

public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var generatedAt: String
    /// SHA-256 of the canonical snapshot content with this field blank.
    public var revision: String
    public var stations: [SyncStation]
    public var sessions: [SyncSession]
    public var journalEntries: [SyncJournalEntry]

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                generatedAt: String, revision: String = "",
                stations: [SyncStation], sessions: [SyncSession],
                journalEntries: [SyncJournalEntry]) {
        self.protocolVersion = protocolVersion
        self.generatedAt = generatedAt
        self.revision = revision
        self.stations = stations
        self.sessions = sessions
        self.journalEntries = journalEntries
    }
}

/// An operation carries one payload selected by `kind`. Optional fields are
/// deliberate: an older server can decode a future kind and reject only that
/// operation instead of losing the entire batch at JSON decoding.
public struct SyncOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var journalEntry: SyncJournalEntry?
    public var completion: SyncCompletion?
    public var generationRequest: SyncGenerationRequest?

    public init(id: String, kind: String, journalEntry: SyncJournalEntry? = nil,
                completion: SyncCompletion? = nil,
                generationRequest: SyncGenerationRequest? = nil) {
        self.id = id
        self.kind = kind
        self.journalEntry = journalEntry
        self.completion = completion
        self.generationRequest = generationRequest
    }
}

public struct SyncPushRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var clientID: String
    public var operations: [SyncOperation]

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                clientID: String, operations: [SyncOperation]) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.operations = operations
    }
}

public struct SyncOperationResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var message: String?

    public init(id: String, status: String, message: String? = nil) {
        self.id = id
        self.status = status
        self.message = message
    }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var snapshotChanged: Bool
    public var results: [SyncOperationResult]

    public init(protocolVersion: Int = GatewaySyncProtocol.currentVersion,
                snapshotChanged: Bool, results: [SyncOperationResult]) {
        self.protocolVersion = protocolVersion
        self.snapshotChanged = snapshotChanged
        self.results = results
    }
}

public struct SyncValidationIssue: Codable, Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public enum SyncContract {
    public static func validate(_ request: SyncPushRequest) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if request.protocolVersion != GatewaySyncProtocol.currentVersion {
            issues.append(.init(path: "protocolVersion", message: "unsupported protocol version"))
        }
        if !validIdentifier(request.clientID) {
            issues.append(.init(path: "clientID", message: "invalid client identifier"))
        }
        if request.operations.count > 100 {
            issues.append(.init(path: "operations", message: "a push may contain at most 100 operations"))
        }
        let duplicateIDs = Dictionary(grouping: request.operations.map(\.id), by: { $0 })
            .filter { $0.value.count > 1 }.keys
        for id in duplicateIDs {
            issues.append(.init(path: "operations", message: "duplicate operation id: \(id)"))
        }
        for (index, operation) in request.operations.enumerated() {
            issues += validate(operation, path: "operations[\(index)]")
        }
        return issues
    }

    public static func validate(_ snapshot: SyncSnapshot) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if snapshot.protocolVersion != GatewaySyncProtocol.currentVersion {
            issues.append(.init(path: "protocolVersion", message: "unsupported protocol version"))
        }
        if !validTimestamp(snapshot.generatedAt) {
            issues.append(.init(path: "generatedAt", message: "invalid ISO-8601 timestamp"))
        }
        if !validIdentifier(snapshot.revision) {
            issues.append(.init(path: "revision", message: "invalid snapshot revision"))
        }
        for (path, ids) in [
            ("stations", snapshot.stations.map(\.key)),
            ("sessions", snapshot.sessions.map(\.id)),
            ("journalEntries", snapshot.journalEntries.map(\.id)),
        ] {
            let duplicates = Dictionary(grouping: ids, by: { $0 })
                .filter { $0.value.count > 1 }.keys
            for id in duplicates {
                issues.append(.init(path: path, message: "duplicate id: \(id)"))
            }
        }
        for (index, station) in snapshot.stations.enumerated() {
            if !validLevel(station.key) {
                issues.append(.init(path: "stations[\(index)].key", message: "invalid Focus level"))
            }
            if station.visitCount < 0 {
                issues.append(.init(path: "stations[\(index)].visitCount", message: "cannot be negative"))
            }
        }
        for (index, session) in snapshot.sessions.enumerated() {
            if !validIdentifier(session.id) {
                issues.append(.init(path: "sessions[\(index)].id", message: "invalid session identifier"))
            }
            if !session.seconds.isFinite || session.seconds < 0 {
                issues.append(.init(path: "sessions[\(index)].seconds", message: "invalid duration"))
            }
            issues += validate(session.audio, path: "sessions[\(index)].audio")
            if let purpose = session.purpose,
               purpose != "standard" && purpose != "continuousJourney" {
                issues.append(.init(path: "sessions[\(index)].purpose",
                                    message: "unknown session purpose"))
            }
            if session.isContinuous {
                if let exit = session.exitNarration {
                    issues += validate(exit, path: "sessions[\(index)].exitNarration")
                } else {
                    issues.append(.init(path: "sessions[\(index)].exitNarration",
                                        message: "continuous journey requires return narration"))
                }
                if let signal = session.continuousReturnSignal {
                    issues += validate(signal, path: "sessions[\(index)].continuousReturnSignal")
                } else {
                    issues.append(.init(path: "sessions[\(index)].continuousReturnSignal",
                                        message: "continuous journey requires wake-up signal"))
                }
            } else if session.exitNarration != nil || session.continuousReturnSignal != nil {
                issues.append(.init(path: "sessions[\(index)]",
                                    message: "only a continuous journey may carry return audio"))
            }
            for (mediaIndex, cue) in (session.media ?? []).enumerated() {
                let path = "sessions[\(index)].media[\(mediaIndex)]"
                issues += validate(cue, path: path)
            }
        }
        for (index, entry) in snapshot.journalEntries.enumerated() {
            issues += validate(entry, path: "journalEntries[\(index)]")
        }
        return issues
    }

    public static func validate(_ operation: SyncOperation) -> [SyncValidationIssue] {
        validate(operation, path: "operation")
    }

    public static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160, !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || value == 45 || value == 46 || value == 95
        }
    }

    public static func validLevel(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper.first == "F" && upper.dropFirst().allSatisfy(\.isNumber)
            && !upper.dropFirst().isEmpty
    }

    public static func validTimestamp(_ value: String) -> Bool {
        let basic = ISO8601DateFormatter()
        if basic.date(from: value) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil
    }

    private static func validate(_ operation: SyncOperation,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !validIdentifier(operation.id) {
            issues.append(.init(path: path + ".id", message: "invalid operation identifier"))
        }
        switch operation.kind {
        case GatewaySyncProtocol.OperationKind.journalAppend:
            if operation.completion != nil || operation.generationRequest != nil
                || operation.journalEntry == nil {
                issues.append(.init(path: path, message: "journal.append requires only journalEntry"))
            } else if let entry = operation.journalEntry {
                issues += validate(entry, path: path + ".journalEntry")
            }
        case GatewaySyncProtocol.OperationKind.completionAppend:
            if operation.journalEntry != nil || operation.generationRequest != nil
                || operation.completion == nil {
                issues.append(.init(path: path, message: "completion.append requires only completion"))
            } else if let completion = operation.completion {
                issues += validate(completion, path: path + ".completion")
            }
        case GatewaySyncProtocol.OperationKind.generationRequest:
            if operation.journalEntry != nil || operation.completion != nil
                || operation.generationRequest == nil {
                issues.append(.init(path: path,
                                    message: "generation.request requires only generationRequest"))
            } else if let request = operation.generationRequest {
                issues += validate(request, path: path + ".generationRequest")
            }
        default:
            issues.append(.init(path: path + ".kind", message: "unsupported operation kind"))
        }
        return issues
    }

    private static func validate(_ entry: SyncJournalEntry,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !validIdentifier(entry.id) {
            issues.append(.init(path: path + ".id", message: "invalid journal identifier"))
        }
        if !validLevel(entry.level) {
            issues.append(.init(path: path + ".level", message: "invalid Focus level"))
        }
        if !validTimestamp(entry.written) {
            issues.append(.init(path: path + ".written", message: "invalid ISO-8601 timestamp"))
        }
        let trimmed = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || entry.body.utf8.count > 200_000 {
            issues.append(.init(path: path + ".body", message: "journal body is empty or too large"))
        }
        if !validIdentifier(entry.originDeviceID) {
            issues.append(.init(path: path + ".originDeviceID", message: "invalid device identifier"))
        }
        if let sessionID = entry.sessionID, !validIdentifier(sessionID) {
            issues.append(.init(path: path + ".sessionID", message: "invalid session identifier"))
        }
        return issues
    }

    private static func validate(_ completion: SyncCompletion,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !validIdentifier(completion.id) {
            issues.append(.init(path: path + ".id", message: "invalid completion identifier"))
        }
        if !validIdentifier(completion.sessionID) {
            issues.append(.init(path: path + ".sessionID", message: "invalid session identifier"))
        }
        if let level = completion.level, !validLevel(level) {
            issues.append(.init(path: path + ".level", message: "invalid Focus level"))
        }
        if !completion.seconds.isFinite || completion.seconds <= 0 {
            issues.append(.init(path: path + ".seconds", message: "invalid duration"))
        }
        if !validTimestamp(completion.finished) {
            issues.append(.init(path: path + ".finished", message: "invalid ISO-8601 timestamp"))
        }
        if !validIdentifier(completion.originDeviceID) {
            issues.append(.init(path: path + ".originDeviceID", message: "invalid device identifier"))
        }
        return issues
    }

    private static func validate(_ request: SyncGenerationRequest,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !validIdentifier(request.id) {
            issues.append(.init(path: path + ".id", message: "invalid request identifier"))
        }
        if !validLevel(request.destination) {
            issues.append(.init(path: path + ".destination", message: "invalid Focus level"))
        }
        if request.mode != SyncGenerationRequest.Mode.visit
            && request.mode != SyncGenerationRequest.Mode.continuous {
            issues.append(.init(path: path + ".mode", message: "unknown generation mode"))
        }
        if !(1...3).contains(request.verbosity) {
            issues.append(.init(path: path + ".verbosity", message: "verbosity must be 1, 2, or 3"))
        }
        if !validTimestamp(request.requestedAt) {
            issues.append(.init(path: path + ".requestedAt", message: "invalid ISO-8601 timestamp"))
        }
        if !validIdentifier(request.originDeviceID) {
            issues.append(.init(path: path + ".originDeviceID", message: "invalid device identifier"))
        }
        return issues
    }

    private static func validate(_ cue: SyncMediaCue,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !cue.startSeconds.isFinite || cue.startSeconds < 0
            || !cue.seconds.isFinite || cue.seconds <= 0 {
            issues.append(.init(path: path, message: "invalid media timing"))
        }
        if cue.role != "resonantTuning" && cue.role != "returnSignal" {
            issues.append(.init(path: path + ".role", message: "unknown media role"))
        }
        issues += validate(cue.audio, path: path + ".audio")
        return issues
    }

    private static func validate(_ asset: SyncAssetReference,
                                 path: String) -> [SyncValidationIssue] {
        var issues: [SyncValidationIssue] = []
        if !validIdentifier(asset.id) {
            issues.append(.init(path: path + ".id", message: "invalid asset identifier"))
        }
        if asset.bytes < 0 {
            issues.append(.init(path: path + ".bytes", message: "cannot be negative"))
        }
        if !asset.path.hasPrefix(GatewaySyncProtocol.Endpoint.assets + "/")
            || asset.path.contains("..") || asset.path.contains("\\") {
            issues.append(.init(path: path + ".path", message: "asset URL must stay inside the API"))
        }
        if let digest = asset.sha256,
           digest.count != 64 || !digest.allSatisfy(\.isHexDigit) {
            issues.append(.init(path: path + ".sha256", message: "invalid SHA-256"))
        }
        return issues
    }
}

private func parseSyncTimestamp(_ value: String) -> Date? {
    let basic = ISO8601DateFormatter()
    if let date = basic.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
}

private extension Data {
    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
