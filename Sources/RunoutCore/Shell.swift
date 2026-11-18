import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }

    /// The last few lines of combined output, for an error message.
    public func tail(_ lines: Int = 4) -> String {
        let text = (errorOutput + "\n" + output).split(separator: "\n").suffix(lines).joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Resumes a continuation once, from whichever path finishes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

public enum Shell {
    /// PATH for child processes: the npm shims and Homebrew's node come first, as
    /// a GUI app inherits only the minimal launchd PATH.
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
                    "/sbin", env["PATH"] ?? ""]
        env["PATH"] = path.filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// Seconds a child gets to exit after SIGTERM before SIGKILL.
    static let killGrace: TimeInterval = 3

    /// SIGTERM now (Foundation signals the child's process group), then SIGKILL to that
    /// group if the child is still running after the grace period.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            guard process.isRunning else { return }
            // The child leads its own group; never signal a group it does not lead (ours).
            kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }

    /// Runs a command and collects its output. The result arrives by `timeout` plus a few
    /// seconds even when a grandchild keeps the output pipes open.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment ?? Shell.environment()
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    once.resume(.failure(error))
                    return
                }
                let timedOut = Box(false)
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.value = true
                        stop(process)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                // Last resort: the reads below can outlive the child when a grandchild holds the pipes.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + killGrace + 2) {
                    once.resume(.success(ProcessResult(status: -1, stdout: Data(), stderr: Data(), timedOut: true)))
                }
                let errData = Box(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.value = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                watchdog.cancel()
                once.resume(.success(ProcessResult(status: process.terminationStatus, stdout: outData,
                                                   stderr: errData.value, timedOut: timedOut.value)))
            }
        }
    }
}
