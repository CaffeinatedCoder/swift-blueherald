import Foundation
import Testing

/// A task that is kept, in a property or a local, outlives the call that started it, so it carries
/// a name for Instruments and crash logs. Fire-and-forget hops (`Task { await self.cancel(...) }`)
/// end at once and stay unnamed.
@Suite("Task names")
struct TaskNameConventionTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    @Test("every task that is kept has a name")
    func keptTasksAreNamed() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let unnamed = try Regex(#"=\s*Task(\.detached)?\s*\{"#)
        let named = try Regex(#"=\s*Task(\.detached)?\s*\("#)
        var kept = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains(named) { kept += 1 }
                if line.contains(unnamed) {
                    Issue.record(
                        "\(file.lastPathComponent):\(number + 1) keeps an unnamed task: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(kept >= 6)
    }
}
