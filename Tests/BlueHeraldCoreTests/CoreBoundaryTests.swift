import Foundation
import Testing

/// BlueHeraldCore is meant to be usable without the MCP server, so it must not know the server's
/// tools or environment variables; those belong to BlueHeraldMCP and the command.
@Suite("Core boundary")
struct CoreBoundaryTests {
    static let coreSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/BlueHeraldCore")

    @Test("no core file names a tool or a BLUEHERALD_ variable")
    func noServerVocabulary() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.coreSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        let vocabulary = try Regex(#"\bble_[a-z_]+|BLUEHERALD_[A-Z_]+"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(vocabulary) {
                Issue.record(
                    "\(file.lastPathComponent):\(number + 1) names server vocabulary: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
