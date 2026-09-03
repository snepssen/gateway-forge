# Gateway Forge companion and cross-platform architecture

**Status:** Contract, desktop projection, authenticated Mac LAN service,
desktop pairing controls, and the native iOS companion MVP are implemented.
The first signed run on a physical iPhone remains a device test.

**Date:** 2026-09-01

## Decision

The full desktop is the authoritative Gateway Forge node. It owns the editable
library, Ollama profiles, Cartographer promotion, voice models, rendering, and
the canonical practice record. Companion and future cross-platform interfaces
communicate through a versioned JSON/HTTP contract; they never mount or imitate
the desktop's directory tree.

The first mobile write surface is append-only:

- add a dated journal entry after a visit;
- report completion of a session played on the companion.

Mobile does not edit GWS source, templates, published material, standing notes,
station promotion, voice settings, or existing journal entries in protocol v1.
Those operations need explicit conflict and review semantics and should not be
smuggled into an initial “sync everything” implementation.

```text
                           local network
┌──────────────────────┐  TLS + JSON/HTTP   ┌──────────────────────────┐
│ iOS / Android        │◄──────────────────►│ Gateway Forge desktop    │
│ companion            │  Bonjour discovery │ authoritative node       │
│                      │                     │                          │
│ cached snapshot      │  GET snapshot       │ editable GWS / Markdown │
│ downloaded sessions  │  GET audio + Range  │ Ollama + Cartographer   │
│ pending visit log    │  POST append batch  │ Piper render + playback │
└──────────────────────┘                     └─────────────┬────────────┘
                                                         │
                                           GatewaySync DTO projection
                                                         │
                                              ┌──────────▼──────────┐
                                              │ file-backed library │
                                              │ remains canonical   │
                                              └─────────────────────┘
```

## Requirements and assumptions

- One listener, a small number of paired devices, and a trusted home LAN are
  the initial scale. There is no cloud account or public relay.
- The companion must remain useful offline after it has downloaded a snapshot
  and selected audio.
- A mobile retry after suspension or a lost response must not duplicate a
  journal entry, completion, or listening time.
- Published/reference material and lived accounts remain separately labelled
  all the way to the mobile UI.
- Audio files may be hundreds of megabytes. They are separate range-capable
  assets, never embedded in snapshot JSON.
- Private library paths, source transcripts, voice models, Ollama prompts, and
  raw render directories never appear on the wire.

## Components and ownership

| Component | Owns | Does not own |
|---|---|---|
| `GatewaySync` | protocol v1 DTOs, endpoint names, validation | files, UI, network listener |
| `GatewaySyncProjection` | canonical desktop data to a safe snapshot | authorization or caching policy |
| `DesktopSyncInbox` | validated, idempotent append operations | socket concurrency or pairing |
| `GatewaySyncTransport` | bounded HTTP/1.1, Apple TLS-PSK listener/client, Bonjour, file transfer | domain rules or credentials |
| `GatewaySyncService` | Keychain credentials, pairing, bearer authorization, endpoint routing, HTTP Range | UI or source editing |
| Desktop Companion feature | disabled-by-default lifecycle, pairing QR, device revocation | protocol validation |
| iOS companion | Keychain credential, last accepted snapshot, downloaded assets, pending operations | canonical library or authoring |

`GatewaySync` is a dependency-free Swift target apart from Foundation. Its JSON
is the contract, not Swift's in-memory types: a Flutter, Kotlin, Rust, C#, or
web client can implement it without embedding Swift or importing GatewayCore.

## Protocol v1

All authenticated endpoints live beneath `/gateway-sync/v1`.

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/pair` | exchange a one-use QR credential for a device token over PSK TLS |
| `GET` | `/hello` | server identity, protocol version, capabilities, current revision |
| `GET` | `/snapshot` | stations, provenance-separated descriptions, sessions, journal entries |
| `GET` | `/assets/{id}` | WAV download with `Range`, `ETag`, and resumable caching |
| `POST` | `/push` | append up to 100 journal/completion operations |

Timestamps are ISO-8601 strings. Identifiers are opaque, path-safe ASCII. A
snapshot revision is an opaque SHA-256 over canonical content with generation
time excluded, so polling does not invalidate an unchanged cache. Clients only
compare revisions; they do not interpret them as counters.

Each pushed operation has its own stable id. The desktop stores only that id
and a digest—not another copy of journal text. Repeating the same operation
returns `duplicate`; reusing an id for different content returns `conflict`.
Imported Markdown and activity completions also retain their sync ids, so a
crash between the domain write and receipt write remains recoverably
idempotent.

## Provenance and privacy

A station contains distinct fields for:

- documented name and published description;
- listener name and promoted Cartographer description;
- the editable standing note about the level;
- dated journal entries, each with its origin device;
- effective signal plus whether it is library-verified, estimated, or
  listener-tuned.

The companion may display these together, but it must not flatten them into one
description. That would recreate on mobile the provenance error the desktop
library was designed to prevent.

Bonjour advertises only protocol version, an opaque server id, and a display
name. It advertises no pairing code, practice state, Focus level, user identity,
or token. Snapshot, audio, and push require a paired device token.

## Pairing and transport

The network service does not ship as clear-text HTTP with a six-digit bearer
secret. The implemented flow is:

1. Desktop access is off until the listener explicitly enables it. Choosing
   Pair a device creates a five-minute offer.
2. The QR carries the opaque server id, a unique TLS identity, a random 256-bit
   pre-shared key, and a separate random one-use application credential. None
   of these secrets is in Bonjour.
3. The companion discovers the address by matching the Bonjour server id, then
   establishes TLS with the QR key before sending `/pair`. There is no initial
   clear-text request.
4. Desktop promotes that unique TLS identity to the paired device and returns
   a random bearer token inside the encrypted connection. Both transport key
   and bearer are stored in the desktop Keychain; the companion must use its
   platform secure credential store.
5. The offer expires after one use or five minutes. A paired device can be
   revoked without changing every other device credential; listener parameters
   are rebuilt so the revoked TLS key no longer connects.

Apple's older `NWConnection` API supports this PSK mode only with TLS 1.2, not
TLS 1.3. The transport pins exactly TLS 1.2 and a real localhost handshake is a
release check. This is an Apple-host implementation detail rather than part of
the JSON contract. Before selecting the Android/Windows client stack, prove its
TLS-PSK support; if common platform APIs make that impractical, migrate the
transport to generated local PKI while retaining the endpoints, bearer model,
and pairing/privacy boundary.

The service is off by default until the listener enables companion access. An
authenticated request is still validated as hostile input: authentication says
who sent bytes, not that the bytes are safe.

## Offline and failure behaviour

- Companion applies a snapshot atomically, then separately downloads chosen
  audio using `ETag` and HTTP Range.
- Pending writes remain in an on-device outbox until every operation receives
  `applied`, `duplicate`, `conflict`, or `rejected`.
- A connection loss after desktop application but before response is resolved
  by resending the identical operation id.
- One invalid operation does not discard valid siblings, except a malformed
  batch identity/version or duplicate operation ids, which rejects the batch.
- `conflict` is surfaced for review. Neither side chooses a winner silently.
- Desktop deletion does not become companion deletion in v1. A fresh snapshot
  replaces the companion catalogue; already downloaded audio can be offered
  for explicit cleanup later.

## Cross-platform path

This boundary lets the mobile companion and future Windows/Linux desktop begin
without rewriting the mature Mac application first:

1. Exercise the implemented native iOS client on real phones: snapshot
   browsing, resumable audio playback, visit capture, and the operation outbox.
2. Prove transport interoperability on the selected non-Apple client runtime;
   TLS-PSK support is a gate, not an assumption.
3. Reuse that client shell on iOS, Android, Windows, and Linux where appropriate.
4. Extract further authoring/rendering domain operations behind the same
   contract only when another desktop is ready to own them.
5. A future non-Mac full node can implement the same server contract around
   Ollama and Piper/ONNX on its platform. Authority remains one selected node
   per library; peers do not become multi-master by accident.

The Apple companion is native SwiftUI and shares only `GatewaySync` and
`GatewaySyncTransport` with the desktop. It does not link GatewayCore,
GatewayTTS, Ollama, or the desktop executable. The UI/runtime choice for
Android and future non-Apple desktops remains deliberately undecided; the v1
JSON boundary keeps that choice reversible.

## Native iOS companion

`GatewayCompanion.xcodeproj` targets iOS 17 and contains the first usable
client shell. It discovers `_gatewayforge._tcp` services with Bonjour, scans
the private pairing QR, performs `/pair` inside TLS-PSK, and stores the
resulting device credential in the iOS Keychain. Pairing links are never saved.
The desktop QR is rendered on an integer module grid with a four-module quiet
zone; the phone also offers a camera-free paste mode with explicit Paste and
Pair actions so QR recognition is never the only route into the same secure
flow.

The private offer also carries the desktop listener's unique Bonjour service
instance name. TXT-filtered browsing remains useful for showing nearby
desktops, but it is not a prerequisite for pairing: after scanning or pasting,
the companion can resolve that named service directly and authenticate it with
the QR's PSK. The name is retained with the Keychain credential for later
direct sync attempts. Connection attempts time out with an in-sheet error
rather than leaving the camera or Pair button apparently inert.

The app atomically caches the last validated snapshot, presents published and
listener findings in separate sections, and downloads complete session
packages to ETag-scoped partial files with HTTP Range resume. The narration WAV
remains dry by design; the snapshot also carries the exact bed stages and the
desktop's calibrated listening mix, while retained tuning and return recordings
are separate authenticated assets. The phone renders that bed locally into a
stereo AVAudioEngine graph and schedules every retained cue against the same
timeline. New findings, playback completions, and bounded session-generation
requests are durable operations in an Application Support outbox. They can be
created offline and are retried with the same ids when the paired desktop
returns. A generation request carries only destination, visit-versus-Continuous
mode, and verbosity; the desktop persists it before using the normal render
queue and remains the sole owner of source, voice choice, models, and assembly.

This is intentionally a companion rather than Gateway Forge in miniature. It
has no authoring, Cartographer promotion, local model, voice training, or local
rendering surface. See `docs/companion-ios.md` for the signed-device test path
and the first manual acceptance pass.

## Trade-offs and later review

- A full snapshot is simpler and auditable for one listener, but journal
  pagination or change feeds may be needed after thousands of visits.
- Desktop authority avoids multi-master conflicts but means authoring and new
  rendering require the authoritative node to be available.
- Self-managed local TLS and pairing cost more work than clear text but are
  necessary when the payload includes private journals and audio. Apple's PSK
  ceiling at TLS 1.2 is an explicit portability trade-off to review before the
  first Android or Windows client.
- Append-only mobile writes are intentionally limited. Existing-entry edits,
  station promotion, and note editing should be added only with base revisions,
  review UI, and explicit conflicts.
- LAN-only operation avoids an account system. Remote access, relays, shared
  libraries, and multiple users are out of scope until real use requires them.
