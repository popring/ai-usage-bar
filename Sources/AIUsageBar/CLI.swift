import Foundation

/// Runs a helper CLI headlessly.
///
/// Two things every call site here needs: a PATH that actually finds the tool
/// (GUI apps inherit a short one that misses `~/.local/bin` and Homebrew, where both
/// `claude` and `cswap` live), and a watchdog, so a background refresh can never hang
/// forever on a stuck child process.
enum CLI {

    /// True only on a clean exit 0. Output is discarded — callers care about the side
    /// effect (a renewed token, a rewritten usage cache), not the text.
    ///
    /// `env` overrides the inherited environment; a nil value unsets the variable.
    static func run(_ arguments: [String],
                    env overrides: [String: String?] = [:],
                    timeout: TimeInterval) -> Bool {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = arguments
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        // /dev/null rather than a Pipe nobody drains: a chatty child would otherwise
        // fill the pipe buffer and deadlock against our own watchdog.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning { proc.terminate(); return false }
        return proc.terminationStatus == 0
    }
}
