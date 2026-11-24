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
    private var onCancel: (@Sendable () -> Void)?
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
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }

    func attach(_ process: Process) {
        attachCancel { Shell.stop(process) }
    }

    func attachCancel(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped {
            onCancel = action
        }
        lock.unlock()
        if alreadyStopped {
            action()
        }
    }

    func detach() {
        lock.lock()
        onCancel = nil
        lock.unlock()
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

    private static let launchQueue = DispatchQueue(label: "runout.shell.launch", qos: .userInitiated)
    private static let ioQueue = DispatchQueue(label: "runout.shell.io", qos: .userInitiated)

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

    private static func setNonBlocking(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        if fd >= 0 { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
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
        ioQueue.asyncAfter(deadline: .now() + killGrace) {
            guard process.isRunning else { return }
            // The child leads its own group; never signal a group it does not lead (ours).
            kill(groupLeader && getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }

    /// Coordinates non-blocking pipe reads, termination, timeouts, and cancellation on `Shell.ioQueue`.
    private final class RunState: @unchecked Sendable {
        let process: Process
        let once: ResumeOnce<ProcessResult>
        let handle: ProcessHandle?
        var stopOnStderr: (@Sendable (String) -> Bool)?
        let timeout: TimeInterval

        var pid: pid_t = 0
        var groupLeader = false
        var started = false
        var exited = false
        var outEOF = false
        var errEOF = false
        var timedOut = false
        var stopInitiated = false
        var stderrTriggered = false
        var finished = false

        var outData = Data()
        var errData = Data()

        var outSource: DispatchSourceRead?
        var errSource: DispatchSourceRead?
        var watchdog: DispatchSourceTimer?
        var killTimer: DispatchSourceTimer?
        var hardDeadline: DispatchSourceTimer?

        init(process: Process, once: ResumeOnce<ProcessResult>, handle: ProcessHandle?,
             stopOnStderr: (@Sendable (String) -> Bool)?, timeout: TimeInterval) {
            self.process = process
            self.once = once
            self.handle = handle
            self.stopOnStderr = stopOnStderr
            self.timeout = timeout
        }

        private func makeTimer(after delay: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
            let timer = DispatchSource.makeTimerSource(queue: Shell.ioQueue)
            timer.schedule(deadline: .now() + max(0, delay), leeway: .milliseconds(25))
            timer.setEventHandler(handler: handler)
            timer.resume()
            return timer
        }

        private func makeReadSource(pipe: Pipe, isStderr: Bool) -> DispatchSourceRead {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Shell.ioQueue)
            source.setEventHandler { [weak self] in
                self?.drain(fd: fd, isStderr: isStderr)
            }
            source.setCancelHandler {
                try? pipe.fileHandleForReading.close()
            }
            source.resume()
            return source
        }

        func start(pid: pid_t, groupLeader: Bool, out: Pipe, err: Pipe) {
            guard !finished else {
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
                return
            }
            self.pid = pid
            self.groupLeader = groupLeader
            self.started = true

            outSource = makeReadSource(pipe: out, isStderr: false)
            errSource = makeReadSource(pipe: err, isStderr: true)

            watchdog = makeTimer(after: timeout) { [weak self] in
                guard let self, !self.finished, !self.stopInitiated else { return }
                self.timedOut = true
                self.beginStop()
            }
            // Last resort: keeps RunState alive if a grandchild in another group holds the pipes open.
            hardDeadline = makeTimer(after: timeout + Shell.killGrace + 2) {
                guard !self.finished else { return }
                self.finish(ProcessResult(status: -1, stdout: Data(), stderr: Data(), timedOut: true,
                                          cancelled: self.handle?.cancelled ?? false))
            }

            handle?.attachCancel { [weak self] in
                Shell.ioQueue.async { self?.beginStop() }
            }

            if exited {
                handlePostExit()
            }
        }

        private func markEOF(isStderr: Bool) {
            if isStderr {
                errEOF = true
                errSource?.cancel()
                errSource = nil
            } else {
                outEOF = true
                outSource?.cancel()
                outSource = nil
            }
            maybeFinish()
        }

        private func drain(fd: Int32, isStderr: Bool) {
            guard !finished, !(isStderr ? errEOF : outEOF) else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if isStderr {
                        errData.append(contentsOf: buffer[0..<count])
                        if !stderrTriggered, let check = stopOnStderr,
                           check(String(decoding: errData, as: UTF8.self)) {
                            stderrTriggered = true
                            beginStop()
                        }
                    } else {
                        outData.append(contentsOf: buffer[0..<count])
                    }
                } else if count == 0 {
                    markEOF(isStderr: isStderr)
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    markEOF(isStderr: isStderr)
                    return
                }
            }
        }

        func beginStop() {
            guard !finished, !stopInitiated else { return }
            stopInitiated = true
            watchdog?.cancel()
            watchdog = nil

            if groupLeader && pid > 0 {
                _ = kill(-pid, SIGTERM)
            } else if process.isRunning {
                process.terminate()
            }

            killTimer = makeTimer(after: Shell.killGrace) { [weak self] in
                guard let self, !self.finished else { return }
                if self.groupLeader && self.pid > 0 {
                    _ = kill(-self.pid, SIGKILL)
                } else if self.process.isRunning {
                    _ = kill(self.pid, SIGKILL)
                }
            }
        }

        func handleTermination() {
            exited = true
            guard started else { return }
            handlePostExit()
        }

        private func handlePostExit() {
            // Re-signal the group when the leader died while a child it had already forked still holds pipes.
            if stopInitiated && !finished && groupLeader && pid > 0 && (!outEOF || !errEOF) {
                _ = kill(-pid, SIGTERM)
            }
            maybeFinish()
        }

        private func maybeFinish() {
            guard !finished, started, exited, outEOF, errEOF else { return }
            finish(ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData,
                                 timedOut: timedOut, cancelled: handle?.cancelled ?? false))
        }

        private func finish(_ result: ProcessResult) {
            guard !finished else { return }
            finished = true
            outSource?.cancel()
            outSource = nil
            errSource?.cancel()
            errSource = nil
            watchdog?.cancel()
            watchdog = nil
            killTimer?.cancel()
            killTimer = nil
            hardDeadline?.cancel()
            hardDeadline = nil
            process.terminationHandler = nil
            handle?.detach()
            stopOnStderr = nil
            once.resume(.success(result))
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
            if handle?.cancelled == true {
                once.resume(.success(ProcessResult(status: -1, stdout: Data(), stderr: Data(),
                                                   timedOut: false, cancelled: true)))
                return
            }
            let env = environment ?? Shell.environment()
            launchQueue.async {
                if handle?.cancelled == true {
                    once.resume(.success(ProcessResult(status: -1, stdout: Data(), stderr: Data(),
                                                       timedOut: false, cancelled: true)))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = env
                let state = RunState(process: process, once: once, handle: handle,
                                     stopOnStderr: stopOnStderr, timeout: timeout)
                process.terminationHandler = { _ in
                    ioQueue.async { state.handleTermination() }
                }
                let (out, err): (Pipe, Pipe)
                do {
                    (out, err) = try launch(process) {
                        let out = cloexecPipe(), err = cloexecPipe()
                        setNonBlocking(out.fileHandleForReading)
                        setNonBlocking(err.fileHandleForReading)
                        process.standardOutput = out
                        process.standardError = err
                        process.standardInput = FileHandle.nullDevice
                        return (out, err)
                    }
                } catch {
                    process.terminationHandler = nil
                    once.resume(.failure(error))
                    return
                }
                let pid = process.processIdentifier
                let groupLeader = pid > 0 && getpgid(pid) == pid
                ioQueue.async {
                    state.start(pid: pid, groupLeader: groupLeader, out: out, err: err)
                }
            }
        }
    }
}
