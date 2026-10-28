import BLEMCPServer
import Foundation
import Testing

/// Holds the README's statements about the tool surface against the catalogue, so a tool that is
/// added, renamed or removed without its README row fails here instead of drifting.
@Suite("README conventions")
struct ReadmeConventionTests {
    /// The README, found by walking up to the `Package.swift` marker rather than counting `../`.
    static func readme() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
            let parent = directory.deletingLastPathComponent()
            try #require(parent != directory, "no Package.swift above \(#filePath)")
            directory = parent
        }
        return try String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8)
    }

    /// The tool names in the first column of the README's tool table. A row may name several, as in
    /// `ble_scan_start` / `ble_scan_results` / `ble_scan_stop`.
    static func documentedTools(in readme: String) -> [String] {
        readme.split(separator: "\n").flatMap { line -> [String] in
            guard line.hasPrefix("| `ble_") else { return [] }
            let firstCell = line.dropFirst().prefix { $0 != "|" }
            return firstCell.matches(of: #/`(ble_[a-z_]+)`/#).map { String($0.output.1) }
        }
    }

    @Test("every built-in tool has a README row, and every row names a built-in tool")
    func toolTableMatchesCatalogue() throws {
        let documented = Self.documentedTools(in: try Self.readme())
        let built = BLEMCPServer.builtInTools.map(\.name)

        #expect(documented.count >= 10, "found only \(documented.count) tool names in the README: the table was not found")
        #expect(Set(built).count == built.count, "a tool name is registered twice")
        #expect(Set(documented).count == documented.count, "a tool has two README rows")

        let undocumented = Set(built).subtracting(documented)
        let unknown = Set(documented).subtracting(built)
        #expect(undocumented.isEmpty, "tools without a README row: \(undocumented.sorted())")
        #expect(unknown.isEmpty, "README rows without a tool: \(unknown.sorted())")
    }

    @Test("the README states the number of tools")
    func toolCountMatchesCatalogue() throws {
        let readme = try Self.readme()
        let match = try #require(readme.firstMatch(of: #/(\d+) typed MCP tools/#), "the README no longer states a tool count")
        #expect(Int(match.output.1) == BLEMCPServer.builtInTools.count)
    }
}
