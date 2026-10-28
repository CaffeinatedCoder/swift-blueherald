import BLEMCPReplay
import Foundation

/// `ble-mcp diff LEFT RIGHT [--kinds tx,rx,read] [--limit N]`, with diff(1)'s exit codes.
enum DiffCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var paths: [String] = []
        var kinds = Set(CaptureDiff.Kind.allCases)
        var limit = 20
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--kinds":
                let parsed = remaining.popFirst()?.split(separator: ",").map { CaptureDiff.Kind(rawValue: String($0)) }
                guard let parsed, !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else {
                    return usage("--kinds takes a comma-separated list of tx, rx and read")
                }
                kinds = Set(parsed.compactMap { $0 })
            case "--limit":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value >= 0 else {
                    return usage("--limit takes a non-negative number")
                }
                limit = value
            case let option where option.hasPrefix("--"):
                return usage("unknown option \(option)")
            default:
                paths.append(argument)
            }
        }
        guard paths.count == 2 else { return usage("pass two capture files") }

        let left: CaptureRecording
        let right: CaptureRecording
        do {
            left = try CaptureRecording(contentsOf: paths[0])
            right = try CaptureRecording(contentsOf: paths[1])
        } catch {
            FileHandle.standardError.write(Data("ble-mcp diff: \(error.description)\n".utf8))
            return 2
        }
        for (path, recording) in [(paths[0], left), (paths[1], right)] {
            for warning in recording.warnings {
                FileHandle.standardError.write(Data("ble-mcp diff: \(path): \(warning)\n".utf8))
            }
        }
        let diff = CaptureDiff(left, right, kinds: kinds)
        print(diff.summary(leftName: paths[0], rightName: paths[1], limit: limit))
        return diff.isIdentical ? 0 : 1
    }

    private static func usage(_ problem: String) -> Int32 {
        FileHandle.standardError.write(
            Data("ble-mcp diff: \(problem)\nusage: ble-mcp diff LEFT.jsonl RIGHT.jsonl [--kinds tx,rx,read] [--limit N]\n".utf8))
        return 2
    }
}
