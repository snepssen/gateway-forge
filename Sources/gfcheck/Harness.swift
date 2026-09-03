import Foundation

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class Check {
    private(set) var passed = 0, failed = 0
    private var current = ""

    func suite(_ name: String) { current = name }

    /// Something true and worth seeing that is **not** a pass/fail.
    ///
    /// Facts about the machine's disk are not defects in the code being built.
    /// Without this, the only way to surface one was to assert it — and an
    /// assertion that reddens the build over state the code already handles
    /// correctly trains people to ignore red.
    func note(_ what: String) {
        FileHandle.standardError.write("  note [\(current)] \(what)\n".data(using: .utf8)!)
    }

    func expect(_ cond: Bool, _ what: String,
                file: StaticString = #file, line: UInt = #line) {
        if cond { passed += 1 }
        else {
            failed += 1
            FileHandle.standardError.write("  FAIL [\(current)] \(what)  (line \(line))\n"
                .data(using: .utf8)!)
        }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
        if a == b { passed += 1 }
        else {
            failed += 1
            FileHandle.standardError.write(
                "  FAIL [\(current)] \(what): \(a) != \(b)  (line \(line))\n".data(using: .utf8)!)
        }
    }

    func throwsError<T>(_ what: String, line: UInt = #line, _ body: () throws -> T) {
        do { _ = try body(); failed += 1
             FileHandle.standardError.write(
                "  FAIL [\(current)] \(what): expected a throw  (line \(line))\n".data(using: .utf8)!) }
        catch { passed += 1 }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

/// Locating sources by name instead of by exact path.
///
/// The app target is organised into feature directories, so a check that
/// hardcodes `Sources/GatewayForge/AppPaths.swift` breaks the day that file
/// moves — or worse, a check that lists one directory non-recursively keeps
/// passing while silently measuring a fraction of the target. Both of those
/// were real: this exists so neither can come back.
enum SourceTree {
    /// Every `.swift` file under a target, at any depth.
    static func swiftFiles(under target: String, root: URL) -> [URL] {
        let dir = root.appending(path: "Sources/\(target)")
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    static func file(named name: String, under target: String, root: URL) -> URL? {
        swiftFiles(under: target, root: root).first { $0.lastPathComponent == name }
    }
}

/// A suite body that genuinely cannot throw.
///
/// Most suites read the disk and want the `do`/`catch` that turns a thrown
/// error into one visible failure. A suite that only reads source text with
/// `try?` has nothing to catch, and wrapping it anyway produces a warning that
/// trains people to skim warnings.
func run(_ body: () -> Void) { body() }
