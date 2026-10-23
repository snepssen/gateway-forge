// swift-tools-version: 6.0
import PackageDescription

// No XCTest target on purpose. `gfcheck` is a plain executable that asserts and
// exits non-zero, so the checks run on any toolchain -- and in CI later without
// a Mac app runner. (XCTest does now exist, since Xcode is installed; the
// harness stays a decision, not a constraint.)
//
// One dependency, confined to GatewayTTS on purpose: voice-core.
//
// mlx-swift (Qwen3-TTS, v3) was removed here on 2026-08-26 along with the rest
// of that engine -- v4 is a fork specifically to make this swap, not an
// in-place change; v3 stays the frozen Qwen3 build. onnxruntime-swift-package-manager
// replaces it: a prebuilt binary XCFramework via Objective-C++, no Metal shader
// compilation step the way mlx-swift needed. CEspeakNG was a vendored
// libespeak-ng.a + headers (pinned upstream revision 724808c), wrapped as a
// plain SwiftPM C target.
//
// Since 2026-10-14 both come from voice-core, the speech engine Voice Forge
// and the Interpreter share: the same espeak-ng revision as an XCFramework,
// its data, the phonemizer, the voice config and the inference call. The
// copies had drifted into three builds and three phonemizers. This app's
// policy stays in GatewayTTS: the respellings, no em-dash spacing, the
// dropped final stop, two trailing pads, one call per sentence. `gfrender
// --phonemes-file` over the library's 310 lines gave the same phonemes and
// ids before and after.
//
// `gfcheck`, `gfscaffold`, and `gfeval` deliberately do **not** depend on GatewayTTS --
// keep it that way, same rule as before, different reason: onnxruntime doesn't
// need Metal, so `swift build` may now work for everything (worth confirming,
// not assuming), but gfcheck staying free of the TTS stack entirely is still
// what keeps it fast and toolchain-independent.

let package = Package(
    name: "GatewayForge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GatewaySync", targets: ["GatewaySync"]),
        .library(name: "GatewaySyncTransport", targets: ["GatewaySyncTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/snepssen/voice-core", from: "1.0.1"),
        // CryptoKit on Apple platforms; the same API from swift-crypto
        // elsewhere, so GatewayCore and gfcheck build on Linux. The version
        // companion-forge uses.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        // Language-neutral companion DTOs and validation. This target must
        // remain free of SwiftUI, AVFoundation, app paths and GatewayCore so a
        // future iOS package or non-Swift client can implement the same wire
        // contract without inheriting the Mac application.
        .target(name: "GatewaySync"),
        // Native TLS-PSK and the deliberately small HTTP/1.1 transport. This
        // is separate from the language-neutral DTO target: Apple Network is
        // useful to the Mac host and a future iOS companion, but it is not a
        // requirement imposed on Android, Windows or Linux clients.
        .target(name: "GatewaySyncTransport", dependencies: ["GatewaySync"]),
        .target(name: "GatewayCore", dependencies: [
            "GatewaySync",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        // The authoritative desktop adapter: pairing registry, Keychain vault,
        // endpoint routing and safe projection onto GatewayCore.
        .target(name: "GatewaySyncService", dependencies: [
            "GatewayCore", "GatewaySync", "GatewaySyncTransport",
        ]),
        // The synthesiser lives apart from GatewayCore so gfcheck stays light:
        // checks never load the model, and never link the TTS stack.
        .target(name: "GatewayTTS",
                dependencies: [
                    "GatewayCore",
                    .product(name: "VoiceCore", package: "voice-core"),
                ],
                // Suno is the public voice. Named individually rather than
                // copying the directory, so a private/local model cannot ride
                // along into the release bundle. espeak-ng's data comes in
                // voice-core's bundle; Resources/espeak-ng-data stays in the
                // tree for the Windows and Linux build, and build.sh requires
                // it to equal voice-core's.
                exclude: ["Resources/espeak-ng-data"],
                resources: [
                    .copy("Resources/en_US-snepssen-suno-medium.onnx"),
                    .copy("Resources/en_US-snepssen-suno-medium.onnx.json"),
                ]),
        .executableTarget(name: "GatewayForge", dependencies: [
            "GatewayCore", "GatewayTTS", "GatewaySync", "GatewaySyncTransport",
            "GatewaySyncService",
        ]),
        // The sync transport is Apple Network and the vault is the Keychain,
        // so elsewhere gfcheck runs without their suites (the companion is
        // suspended, and its transport is Apple's by design).
        .executableTarget(name: "gfcheck", dependencies: [
            "GatewayCore", "GatewaySync",
            .target(name: "GatewaySyncTransport", condition: .when(platforms: [.macOS, .iOS])),
            .target(name: "GatewaySyncService", condition: .when(platforms: [.macOS, .iOS])),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .executableTarget(name: "gfscaffold", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfeval", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfcorpus", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfrender", dependencies: ["GatewayCore", "GatewayTTS"]),
    ]
)
