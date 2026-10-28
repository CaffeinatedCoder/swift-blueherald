#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Makes this process responsible for its own privacy permissions.
///
/// macOS privacy checks (TCC) evaluate the *responsible* process, which for a command-line tool
/// is the app that launched it: Claude, an IDE or a terminal. When that app's Info.plist lacks
/// `NSBluetoothAlwaysUsageDescription`, TCC aborts the tool the moment CoreBluetooth starts, and
/// the description embedded in this binary is never consulted.
///
/// Re-spawning ourselves with responsibility disclaimed (the SPI Chromium, LLDB and iTerm2 use for
/// the same problem) makes the child its own responsible process: TCC then reads this binary's
/// embedded Info.plist and the Bluetooth permission belongs to blueherald, whoever launched it.
enum ResponsibilityDisclaimer {
    private static let markerVariable = "BLUEHERALD_RESPONSIBILITY_DISCLAIMED"

    /// In the original process: spawns the disclaimed child, relays its exit status and never
    /// returns. In the child, or when the SPI is unavailable: returns immediately.
    ///
    /// posix_spawn, its attributes and the SPI take C pointers that no safe Swift API wraps; every
    /// one of them lives only for the calls in this function, which runs once, before any task.
    static func relaunchDisclaimedIfNeeded() {
        var environment = ProcessInfo.processInfo.environment
        guard environment[markerVariable] == nil,
            let executable = Bundle.main.executablePath,
            let setDisclaim = unsafe disclaimFunction()
        else { return }

        var attributes: posix_spawnattr_t?
        guard unsafe posix_spawnattr_init(&attributes) == 0 else { return }
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        guard unsafe setDisclaim(&attributes, 1) == 0 else { return }

        environment[markerVariable] = "1"
        let environmentBlock = unsafe environment.map { unsafe strdup("\($0.key)=\($0.value)") } + [nil]
        defer { unsafe environmentBlock.forEach { unsafe free($0) } }

        var child: pid_t = 0
        // No file actions: the child inherits stdin, stdout and stderr and speaks MCP directly.
        guard unsafe posix_spawn(&child, executable, nil, &attributes, CommandLine.unsafeArgv, environmentBlock) == 0 else {
            return
        }

        childProcess.store(child, ordering: .sequentiallyConsistent)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber) { received in
                kill(childProcess.load(ordering: .sequentiallyConsistent), received)
            }
        }

        var status: Int32 = 0
        while unsafe waitpid(child, &status, 0) == -1, errno == EINTR {}
        // Decode the wait status by hand: WIFEXITED and friends are macros Swift cannot import.
        let terminatingSignal = status & 0x7F
        exit(terminatingSignal == 0 ? (status >> 8) & 0xFF : 128 + terminatingSignal)
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static func disclaimFunction() -> SetDisclaim? {
        // RTLD_DEFAULT: search every image already loaded into the process.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafe unsafeBitCast(symbol, to: SetDisclaim.self)
    }
}

/// Read from a signal handler, so it must be lock-free.
private let childProcess = Atomic<pid_t>(0)
#endif
