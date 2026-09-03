// swift-tools-version: 6.0
import PackageDescription
import Foundation

// No XCTest target on purpose. `gfcheck` is a plain executable that asserts and
// exits non-zero, so the checks run on any toolchain -- and in CI later without
// a Mac app runner. (XCTest does now exist, since Xcode is installed; the
// harness stays a decision, not a constraint.)
//
// Two dependencies, both confined to GatewayTTS on purpose.
//
// mlx-swift (Qwen3-TTS, v3) was removed here on 2026-08-26 along with the rest
// of that engine -- v4 is a fork specifically to make this swap, not an
// in-place change; v3 stays the frozen Qwen3 build. onnxruntime-swift-package-manager
// replaces it: a prebuilt binary XCFramework via Objective-C++, no Metal shader
// compilation step the way mlx-swift needed. CEspeakNG is new -- a vendored
// libespeak-ng.a + headers (built from pinned upstream revision 724808c by
// tools/rebuild-espeak.sh for arm64 + macOS 14.0) wrapped as a plain SwiftPM C
// target, since there is no system espeak-ng install to point at in a
// distributable app.
//
// `gfcheck`, `gfscaffold`, and `gfeval` deliberately do **not** depend on GatewayTTS --
// keep it that way, same rule as before, different reason: onnxruntime doesn't
// need Metal, so `swift build` may now work for everything (worth confirming,
// not assuming), but gfcheck staying free of the TTS stack entirely is still
// what keeps it fast and toolchain-independent.
// SwiftPM resolves relative linker search paths against whatever the build
// system's working directory happens to be, which isn't reliably the package
// root -- an absolute path computed from this file's own location is the
// standard fix vendored-binary packages use.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let espeakLibDir = packageRoot.appending(path: "Sources/CEspeakNG/lib").path

let package = Package(
    name: "GatewayForge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GatewaySync", targets: ["GatewaySync"]),
        .library(name: "GatewaySyncTransport", targets: ["GatewaySyncTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
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
        .target(name: "GatewayCore", dependencies: ["GatewaySync"]),
        // The authoritative desktop adapter: pairing registry, Keychain vault,
        // endpoint routing and safe projection onto GatewayCore.
        .target(name: "GatewaySyncService", dependencies: [
            "GatewayCore", "GatewaySync", "GatewaySyncTransport",
        ]),
        // Headers + a vendored static lib, no compiled source of its own --
        // see Sources/CEspeakNG/stub.c for why a source file exists at all.
        .target(name: "CEspeakNG",
                linkerSettings: [
                    .unsafeFlags(["-L\(espeakLibDir)", "-lespeak-ng", "-lucd"]),
                ]),
        // The synthesiser lives apart from GatewayCore so gfcheck stays light:
        // checks never load the model, and never link the TTS stack.
        .target(name: "GatewayTTS",
                dependencies: [
                    "GatewayCore",
                    "CEspeakNG",
                    .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                ],
                // Suno is the public voice. Named individually rather than
                // copying the directory, so a private/local model cannot ride
                // along into the release bundle.
                resources: [
                    .copy("Resources/en_US-snepssen-suno-medium.onnx"),
                    .copy("Resources/en_US-snepssen-suno-medium.onnx.json"),
                    .copy("Resources/espeak-ng-data"),
                ]),
        .executableTarget(name: "GatewayForge", dependencies: [
            "GatewayCore", "GatewayTTS", "GatewaySync", "GatewaySyncTransport",
            "GatewaySyncService",
        ]),
        .executableTarget(name: "gfcheck", dependencies: [
            "GatewayCore", "GatewaySync", "GatewaySyncTransport", "GatewaySyncService",
        ]),
        .executableTarget(name: "gfscaffold", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfeval", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfcorpus", dependencies: ["GatewayCore"]),
        .executableTarget(name: "gfrender", dependencies: ["GatewayCore", "GatewayTTS"]),
    ]
)
