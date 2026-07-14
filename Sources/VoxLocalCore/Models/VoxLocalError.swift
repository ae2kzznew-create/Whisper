import Foundation

/// User-facing errors of the dictation pipeline. `messageKey` maps to a
/// localized string; `detail` carries technical context for the log only.
public enum VoxLocalError: Error, Equatable {
    case microphonePermissionDenied
    case microphoneUnavailable
    case recordingFailed(String)
    case emptyRecording
    case whisperBinaryMissing(String)
    case modelMissing(String)
    case modelInvalid(String)
    case transcriptionFailed(exitCode: Int32, detail: String)
    case transcriptionTimeout
    case transcriptionOutputMissing
    case unsupportedArchitecture(String)
    case hotkeyConflict(String)
    case insertionTargetGone
    case cancelled

    public var messageKey: String {
        switch self {
        case .microphonePermissionDenied: return "error.mic.denied"
        case .microphoneUnavailable: return "error.mic.unavailable"
        case .recordingFailed: return "error.recording.failed"
        case .emptyRecording: return "error.recording.empty"
        case .whisperBinaryMissing: return "error.whisper.binary"
        case .modelMissing: return "error.whisper.model.missing"
        case .modelInvalid: return "error.whisper.model.invalid"
        case .transcriptionFailed: return "error.whisper.failed"
        case .transcriptionTimeout: return "error.whisper.timeout"
        case .transcriptionOutputMissing: return "error.whisper.output"
        case .unsupportedArchitecture: return "error.whisper.arch"
        case .hotkeyConflict: return "error.hotkey.conflict"
        case .insertionTargetGone: return "error.insert.target.gone"
        case .cancelled: return "state.cancelled"
        }
    }

    /// Technical detail for logs. Never contains transcript text or audio.
    public var logDetail: String {
        switch self {
        case .recordingFailed(let d): return "recording failed: \(d)"
        case .whisperBinaryMissing(let p): return "whisper-cli not found, searched: \(d(p))"
        case .modelMissing(let p): return "model missing at \(d(p))"
        case .modelInvalid(let p): return "model invalid at \(d(p))"
        case .transcriptionFailed(let code, let detail): return "whisper exit \(code): \(detail)"
        case .unsupportedArchitecture(let a): return "unsupported architecture: \(a)"
        case .hotkeyConflict(let c): return "hotkey conflict: \(c)"
        default: return String(describing: self)
        }
    }

    private func d(_ path: String) -> String { PathRedactor.redact(path) }
}

/// Replaces the user's home directory prefix in paths before logging.
public enum PathRedactor {
    public static func redact(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
