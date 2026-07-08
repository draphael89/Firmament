import FirmamentKit
import Foundation

// firmament — the CLI escape hatch (SPEC §5.5, §11.7).
// Subcommands land with their units: export/verify (U8), stress-capture (U11).

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "version":
    print("firmament \(FirmamentKit.version)")
case .none:
    FileHandle.standardError.write(Data("usage: firmament <version>\n".utf8))
    exit(64)
case .some(let other):
    FileHandle.standardError.write(Data("firmament: unknown command '\(other)'\n".utf8))
    exit(64)
}
