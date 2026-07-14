import Foundation

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum SubprocessError: Error, Equatable {
    case launchFailed(String)
    case timeout
}

/// Abstraction over `Process` so transcription logic can be unit-tested
/// with a mock runner.
public protocol SubprocessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> SubprocessResult
}

public struct ProcessSubprocessRunner: SubprocessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Reading pipes from background threads avoids deadlocks when the
        // child writes more than the pipe buffer.
        actor DataBox {
            var stdout = Data()
            var stderr = Data()
            func setStdout(_ d: Data) { stdout = d }
            func setStderr(_ d: Data) { stderr = d }
        }
        let box = DataBox()

        let timedOut = LockedFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubprocessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SubprocessError.launchFailed(error.localizedDescription))
                    return
                }

                let readQueue = DispatchQueue(label: "voxlocal.subprocess.read", attributes: .concurrent)
                let group = DispatchGroup()
                group.enter()
                readQueue.async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    Task { await box.setStdout(data); group.leave() }
                }
                group.enter()
                readQueue.async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    Task { await box.setStderr(data); group.leave() }
                }

                let killTimer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                        // Escalate if terminate is ignored.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                if timeout > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killTimer)
                }

                process.terminationHandler = { proc in
                    killTimer.cancel()
                    group.notify(queue: .global()) {
                        Task {
                            if timedOut.isSet {
                                continuation.resume(throwing: SubprocessError.timeout)
                            } else {
                                let result = SubprocessResult(
                                    exitCode: proc.terminationStatus,
                                    stdout: await box.stdout,
                                    stderr: await box.stderr)
                                continuation.resume(returning: result)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Tiny thread-safe boolean used to distinguish timeout from normal exit.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}
