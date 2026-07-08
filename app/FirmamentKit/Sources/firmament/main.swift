import FirmamentKit
import Foundation

// firmament — the CLI escape hatch (SPEC §5.5, §11.7). Hand-rolled argument
// handling: the dependency list is closed (SPEC §17.1) and two subcommands
// don't need ArgumentParser.

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func ledgerPath(from arguments: inout [String]) -> String {
    if let index = arguments.firstIndex(of: "--ledger") {
        guard index + 1 < arguments.count else { fail("--ledger requires a path") }
        let path = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return path
    }
    return FirmamentPaths.defaultLedger().path
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? nil : arguments.removeFirst()

switch command {
case "export":
    let path = ledgerPath(from: &arguments)
    guard FileManager.default.fileExists(atPath: path) else { fail("no ledger at \(path)", code: 66) }
    do {
        let store = try LedgerStore.queue(at: path)
        print(try LedgerVerifier.export(store: store), terminator: "")
    } catch {
        fail("export failed: \(error)", code: 70)
    }

case "verify":
    let path = ledgerPath(from: &arguments)
    guard FileManager.default.fileExists(atPath: path) else { fail("no ledger at \(path)", code: 66) }
    do {
        let store = try LedgerStore.queue(at: path)
        let outcome = try LedgerVerifier.verify(store: store)
        for line in outcome.lines { print(line) }
        exit(outcome.exitCode)
    } catch {
        fail("verify failed: \(error)", code: 70)
    }

case "stress-capture":
    // The U11 crash-harness driver: continuous synthetic captures through
    // the real capture pipeline until killed.
    guard let rootIndex = arguments.firstIndex(of: "--root"), rootIndex + 1 < arguments.count else {
        fail("stress-capture requires --root <dir>")
    }
    let root = URL(fileURLWithPath: arguments[rootIndex + 1])
    do {
        try await StressCapture.run(root: root)
    } catch {
        fail("stress-capture failed: \(error)", code: 70)
    }

case "reconcile":
    // The crash-harness relaunch half: adopt survivors, report, exit
    // non-zero on any fatal dangling local event.
    guard let rootIndex = arguments.firstIndex(of: "--root"), rootIndex + 1 < arguments.count else {
        fail("reconcile requires --root <dir>")
    }
    let root = URL(fileURLWithPath: arguments[rootIndex + 1])
    do {
        let report = try await StressCapture.reconcile(root: root)
        print("adopted-partials: \(report.adoptedPartials.count)")
        print("adopted-completes: \(report.adoptedCompletes.count)")
        print("collected-empty-temps: \(report.collectedEmptyTemps)")
        print("pending-foreign-assets: \(report.pendingForeignAssets.count)")
        if !report.fatalDanglingLocal.isEmpty {
            print("FATAL dangling local events: \(report.fatalDanglingLocal.map { $0.uuidString.lowercased() }.joined(separator: ", "))")
            exit(1)
        }
    } catch {
        fail("reconcile failed: \(error)", code: 70)
    }

case "version":
    print("firmament \(FirmamentKit.version)")

default:
    fail("""
    usage: firmament <command> [--ledger <path>]

    commands:
      export           write the ledger as canonical NDJSON to stdout
      verify           verify per-device hash chains against stored bytes
      stress-capture   --root <dir>  crash-harness driver (U11)
      reconcile        --root <dir>  adopt crash survivors, report
      version
    """)
}
