import AppKit
import ApplicationServices
import AVFoundation
import Foundation

public enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Abstraction over macOS permission checks so permission-dependent logic
/// can be unit-tested with mocks.
public protocol PermissionsChecking: AnyObject {
    var microphoneStatus: PermissionStatus { get }
    func requestMicrophoneAccess() async -> Bool
    var accessibilityTrusted: Bool { get }
    /// Shows the system prompt that offers to open Accessibility settings.
    func promptForAccessibility()
    func openMicrophoneSettings()
    func openAccessibilitySettings()
}

public final class PermissionsService: PermissionsChecking {
    public init() {}

    public var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    public func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Result of the pre-flight check before a dictation session starts.
/// Pure decision logic (unit-tested with mocked permission states).
public enum DictationPreflight: Equatable, Sendable {
    case ready(warnAccessibilityMissing: Bool)
    case needsMicrophoneRequest
    case blockedMicrophoneDenied
    case blockedModelMissing(modelName: String)

    public static func evaluate(
        microphone: PermissionStatus,
        accessibilityTrusted: Bool,
        modelInstalled: Bool,
        modelName: String
    ) -> DictationPreflight {
        switch microphone {
        case .denied:
            return .blockedMicrophoneDenied
        case .notDetermined:
            return .needsMicrophoneRequest
        case .granted:
            guard modelInstalled else {
                return .blockedModelMissing(modelName: modelName)
            }
            // Missing Accessibility does not block dictation: the result
            // falls back to the clipboard.
            return .ready(warnAccessibilityMissing: !accessibilityTrusted)
        }
    }
}
