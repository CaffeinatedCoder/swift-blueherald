import BLEMCPCore
import BLEMCPServer
import Dispatch
import Foundation
import Logging
import MCP

#if canImport(CoreBluetooth)
import BLEMCPCoreBluetooth
#endif

/// Composition root: reads the environment, wires the CoreBluetooth backend into a session and
/// serves it over stdio. stdout carries the MCP protocol, so everything else goes to stderr.
@main
enum BLEMCPCommand {
    static func main() async {
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
        if configuration.disclaimResponsibility {
            ResponsibilityDisclaimer.relaunchDisclaimedIfNeeded()
        }
        #endif

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = configuration.logLevel
            return handler
        }
        let logger = Logger(label: BLEMCPServer.name)

        #if canImport(CoreBluetooth)
        let session = BLESession(central: CoreBluetoothCentral(), configuration: configuration.session)
        let server = BLEMCPServer(session: session, logger: logger)

        // On SIGINT/SIGTERM, release scans and links before exiting; the controller would
        // otherwise keep peripherals connected until it notices the process is gone.
        let signalSources = [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                Task {
                    await session.shutdown()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
            return source
        }

        logger.notice(
            "starting",
            metadata: [
                "version": "\(BLEMCPServer.version)",
                "writes": "\(configuration.session.writePolicy.isEnabled)",
            ])
        do {
            try await server.run(on: StdioTransport(logger: logger))
        } catch {
            logger.critical("server failed", metadata: ["error": "\(error)"])
            await session.shutdown()
            exit(EXIT_FAILURE)
        }
        withExtendedLifetime(signalSources) {}
        #else
        fail("ble-mcp needs CoreBluetooth; no Bluetooth backend exists for this platform yet.", status: EXIT_FAILURE)
        #endif
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

            Environment:
            \(variables)
            """
    }
}
