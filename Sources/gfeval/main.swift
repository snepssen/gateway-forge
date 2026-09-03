import Darwin
import Foundation
import GatewayCore

@main
struct GFEval {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(Options.usage)
                return
            }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let suite = try ModelEvaluationSuite.load(
                from: root.appending(path: "library/evaluation/model-cases.json"))
            let fixtureProblems = suite.validationFindings()
            guard fixtureProblems.isEmpty else {
                throw EvaluationFailure("invalid evaluation fixtures: "
                                        + fixtureProblems.joined(separator: "; "))
            }

            let composerCases = suite.composer.filter(options.includes)
            let cartographerCases = suite.cartographer.filter(options.includes)
            guard !composerCases.isEmpty || !cartographerCases.isEmpty else {
                throw EvaluationFailure("no case matches '\(options.caseID ?? "")'")
            }

            print("Gateway Forge local-model evaluation")
            print("Profiles: \(LocalModelProfiles.models.joined(separator: ", "))")
            print("Runs per case: \(options.runs)\n")

            let client = OllamaClient()
            var failures = 0
            for run in 1...options.runs {
                for item in composerCases {
                    let started = Date()
                    do {
                        let proposal = try await client.proposeSession(
                            context: item.context, keepAlive: "5m")
                        let findings = item.findings(for: proposal)
                        failures += report(role: "composer", caseID: item.id, run: run,
                                           started: started, findings: findings,
                                           warnings: item.warnings(for: proposal))
                    } catch {
                        failures += report(role: "composer", caseID: item.id, run: run,
                                           started: started,
                                           findings: [error.localizedDescription])
                    }
                }
                for item in cartographerCases {
                    let started = Date()
                    do {
                        let proposal = try await client.describeStation(
                            level: item.level, entries: try item.journalEntries(), keepAlive: "5m")
                        let findings = item.findings(for: proposal)
                        failures += report(role: "cartographer", caseID: item.id, run: run,
                                           started: started, findings: findings)
                    } catch {
                        failures += report(role: "cartographer", caseID: item.id, run: run,
                                           started: started,
                                           findings: [error.localizedDescription])
                    }
                }
            }
            await client.unloadGatewayModels()

            let total = (composerCases.count + cartographerCases.count) * options.runs
            print("\n\(total - failures)/\(total) evaluations passed")
            if failures > 0 { exit(EXIT_FAILURE) }
        } catch {
            fputs("gfeval: \(error.localizedDescription)\n", stderr)
            fputs("Run `swift run gfeval --help` for usage. Ollama and both Gateway Forge "
                  + "profiles must be installed.\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func report(role: String, caseID: String, run: Int,
                               started: Date, findings: [String],
                               warnings: [String] = []) -> Int {
        let duration = Date().timeIntervalSince(started)
        let result = findings.isEmpty ? "PASS" : "FAIL"
        print(String(format: "[%@] %@/%@ run %d (%.2fs)",
                     result, role, caseID, run, duration))
        for warning in warnings { print("  - warning: \(warning)") }
        for finding in findings { print("  - \(finding)") }
        return findings.isEmpty ? 0 : 1
    }
}

private struct Options {
    var runs = 1
    var caseID: String?
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--runs":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw EvaluationFailure("--runs requires a positive integer")
                }
                runs = value
            case "--case":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw EvaluationFailure("--case requires an id")
                }
                caseID = arguments[index]
            case "--help", "-h": help = true
            default: throw EvaluationFailure("unknown option: \(arguments[index])")
            }
            index += 1
        }
    }

    func includes(_ item: ComposerEvaluationCase) -> Bool {
        caseID == nil || caseID == item.id
    }

    func includes(_ item: CartographerEvaluationCase) -> Bool {
        caseID == nil || caseID == item.id
    }

    static let usage = """
    Usage: swift run gfeval [--runs N] [--case ID]

      --runs N   Repeat each selected case N times (default: 1)
      --case ID  Run one composer or cartographer case

    This is an opt-in live evaluation. It calls the local Ollama service and
    exits non-zero if a product invariant fails. It never edits the library.
    """
}

private struct EvaluationFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
