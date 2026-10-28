import BLEMCPCore
import BLEMCPReplay
import BLEMCPServer
import Dispatch
import Foundation
import Logging
import MCP

#if canImport(CoreBluetooth)
import BLEMCPCoreBluetooth
#endif

/// Composition root: reads the environment, wires the CoreBluetooth backend (or a replay) into a
/// session and serves it over stdio. stdout carries the MCP protocol, so everything else goes to
/// stderr. `ble-mcp diff` compares two captures instead.
@main
enum BLEMCPCommand {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "diff" {
            exit(DiffCommand.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--version") {
            print("\(BLEMCPServer.name) \(BLEMCPServer.version)")
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        if let unknown = arguments.first {
            fail("Unknown argument \(unknown). Run with --help for usage.", status: EX_USAGE)
        }

        let configuration: ServerConfiguration
        do {
            configuration = try ServerConfiguration(environment: ProcessInfo.processInfo.environment)
        } catch {
            fail(error.description, status: EX_CONFIG)
        }

        #if os(macOS)
        // A replay never touches Bluetooth, so there is no permission to attribute.
        if configuration.disclaimResponsibility, configuration.replay == nil {
            ResponsibilityDisclaimer.relaunchDisclaimedIfNeeded()
        }
        #endif

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = configuration.logLevel
            return handler
        }
        let logger = Logger(label: BLEMCPServer.name)

        let central: any BLECentral
        if let replay = configuration.replay {
            do {
                let recording = try CaptureRecording(contentsOf: replay.path)
                for warning in recording.warnings {
                    logger.warning("\(warning)", metadata: ["replay": "\(replay.path)"])
                }
                central = ReplayCentral(recording, options: ReplayCentral.Options(speed: replay.speed, isStrict: replay.isStrict))
            } catch {
                fail(error.description, status: EX_NOINPUT)
            }
        } else {
            #if canImport(CoreBluetooth)
            central = CoreBluetoothCentral()
            #else
            fail("ble-mcp needs CoreBluetooth; on this platform it can only play captures (BLE_MCP_REPLAY).", status: EXIT_FAILURE)
            #endif
        }

        let capture: JSONLCaptureFile?
        do {
            capture = try configuration.capturePath.map { (path: String) throws(CaptureFileError) in
                try JSONLCaptureFile(path: path, logger: logger)
            }
        } catch {
            fail(error.description, status: EX_CANTCREAT)
        }
        let session = BLESession(central: central, configuration: configuration.session, capture: capture)
        let server = BLEMCPServer(session: session, logger: logger)

        // On SIGINT/SIGTERM, release scans and links before exiting; the controller would
        // otherwise keep peripherals connected until it notices the process is gone.
        let signalSources = onTermination {
            await session.shutdown()
            capture?.flush()
            exit(EXIT_SUCCESS)
        }

        logger.notice(
            "starting",
            metadata: [
                "version": "\(BLEMCPServer.version)",
                "writes": "\(configuration.session.writePolicy.isEnabled)",
                "capture": "\(capture?.destination ?? "off")",
                "replay": "\(configuration.replay?.path ?? "off")",
            ])
        do {
            try await server.run(on: StdioServerTransport(logger: logger))
        } catch {
            logger.critical("server failed", metadata: ["error": "\(error)"])
            await session.shutdown()
            capture?.flush()
            exit(EXIT_FAILURE)
        }
        // `run` has shut the session down; its last capture rows may still be queued.
        capture?.flush()
        withExtendedLifetime(signalSources) {}
    }

    /// Runs `shutdown` once SIGINT or SIGTERM arrives. Keep the returned sources alive.
    ///
    /// `nonisolated` on purpose: a handler written inside `main` inherits its main-actor
    /// isolation, and the runtime then traps when the signal source runs it on its own queue,
    /// so the shutdown never happened and every stop left a crash report.
    nonisolated private static func onTermination(
        _ shutdown: @escaping @Sendable () async -> Void
    ) -> [any DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                Task { await shutdown() }
            }
            source.resume()
            return source
        }
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("ble-mcp: \(message)\n".utf8))
        exit(status)
    }

    private static var usage: String {
        let variables = ServerConfiguration.variables
            .map { "  \($0.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \($0.meaning)" }
            .joined(separator: "\n")
        return """
            \(BLEMCPServer.name) \(BLEMCPServer.version): a Bluetooth LE Model Context Protocol server.

            Speaks MCP over stdin/stdout; MCP clients launch it as a subprocess, for example:
              claude mcp add ble -- \(CommandLine.arguments.first ?? "ble-mcp")

            Options:
              --help, -h    Show this help.
              --version     Print the version.

            Comparing captures:
              \(BLEMCPServer.name) diff LEFT.jsonl RIGHT.jsonl [--kinds tx,rx,read] [--limit N]
                            Compares writes, notifications and reads, ignoring timing.
                            Exits 0 when they match, 1 when they differ, 2 on errors.

            Environment:
            \(variables)
            """
    }
}
