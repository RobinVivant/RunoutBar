import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    /// Stopped through its `ProcessHandle` before it ended.
    public var cancelled = false

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

/// Lets a caller stop a command it started with `Shell.run`.
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    public init() {}

    public var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Stop the command; one that has not started yet stops as it starts.
    public func cancel() {
        lock.lock()
        stopped = true
        let running = process
        lock.unlock()
        if let running { Shell.stop(running) }
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = stopped
        lock.unlock()
        if stop { Shell.stop(process) }
    }
}

public enum Shell {
    /// PATH for child processes: the npm shims and Homebrew's node come first, as
    /// a GUI app inherits only the minimal launchd PATH.
    ///
    /// `first` goes ahead of them: a script that starts with `env node`, as npm and TeamClaude do, runs with
    /// the first Node on PATH, which has to be the one this app chose.
    public static func environment(first: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path: [String] = []
        for folder in first + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                               "/usr/sbin", "/sbin"] + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        where !folder.isEmpty && !path.contains(folder) {
            path.append(folder)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Seconds a child gets to exit after SIGTERM before SIGKILL.
    static let killGrace: TimeInterval = 3

    /// Serializes pipe creation (with `FD_CLOEXEC`) and `Process.run()` so concurrent spawns never
    /// inherit another command's pipe write ends and block its EOF.
    private static let spawnLock = NSLock()

    static func cloexecPipe() -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let fd = handle.fileDescriptor
            if fd >= 0 { _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) }
        }
        return pipe
    }

    static func launch<T>(_ process: Process, configure: () -> T) throws -> T {
        spawnLock.lock()
        defer { spawnLock.unlock() }
        let state = configure()
        try process.run()
        return state
    }

    /// SIGTERM now (to the child's process group when it leads one), then SIGKILL to that
    /// group if the child is still running after the grace period.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let groupLeader = pid > 0 && getpgid(pid) == pid
        if groupLeader {
            kill(-pid, SIGTERM)
        } else {
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            guard process.isRunning else { return }
            // The child leads its own group; never signal a group it does not lead (ours).
            kill(groupLeader && getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }

    /// Runs a command and collects its output. The result arrives by `timeout` plus a few
    /// seconds even when a grandchild keeps the output pipes open.
    /// When `stopOnStderr` returns true on accumulated stderr, the process is stopped immediately
    /// without marking the run as timed out.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 30, handle: ProcessHandle? = nil,
                           stopOnStderr: (@Sendable (String) -> Bool)? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment ?? Shell.environment()
                let (out, err): (Pipe, Pipe)
                do {
                    (out, err) = try launch(process) {
                        let out = cloexecPipe(), err = cloexecPipe()
                        process.standardOutput = out
                        process.standardError = err
                        process.standardInput = FileHandle.nullDevice
                        return (out, err)
                    }
                } catch {
                    once.resume(.failure(error))
                    return
                }
                handle?.attach(process)
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
                    if let stopOnStderr {
                        var data = Data()
                        var triggered = false
                        while true {
                            let chunk = err.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            data.append(chunk)
                            if !triggered, stopOnStderr(String(decoding: data, as: UTF8.self)) {
                                triggered = true
                                stop(process)
                            }
                        }
                        errData.value = data
                    } else {
                        errData.value = err.fileHandleForReading.readDataToEndOfFile()
                    }
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                watchdog.cancel()
                once.resume(.success(ProcessResult(status: process.terminationStatus, stdout: outData,
                                                   stderr: errData.value, timedOut: timedOut.value,
                                                   cancelled: handle?.cancelled ?? false)))
            }
        }
    }
}
