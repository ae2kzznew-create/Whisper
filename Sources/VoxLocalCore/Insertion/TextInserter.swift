import AppKit
import ApplicationServices
import Foundation

public enum InsertionOutcome: Equatable, Sendable {
    case insertedViaAccessibility
    case pastedViaClipboard
    /// Text left on the clipboard; the user pastes manually. The key
    /// explains why (localized message shown in the overlay/menu).
    case clipboardOnly(reasonKey: String)
}

/// Inserts the final text into the application that was frontmost when
/// dictation started. Strategy: Accessibility API first, synthetic ⌘V with
/// clipboard save/restore second, plain clipboard as the last resort.
public final class TextInserter {
    private let pasteboard: Pasteboarding

    public init(pasteboard: Pasteboarding = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    @MainActor
    public func insert(
        _ text: String,
        into target: NSRunningApplication?,
        mode: InsertionMode,
        accessibilityTrusted: Bool
    ) async -> InsertionOutcome {
        // A cancelled session must produce no side effects at all — no
        // clipboard writes, no synthetic keystrokes. The caller discards
        // the outcome after cancellation.
        guard !Task.isCancelled else {
            return .clipboardOnly(reasonKey: "insert.reason.pasteFailed")
        }
        if mode == .clipboardOnly {
            pasteboard.writeString(text)
            Log.shared.info("insertion: clipboard-only mode (chars: \(text.count))")
            return .clipboardOnly(reasonKey: "insert.reason.clipboardMode")
        }

        guard let target, !target.isTerminated else {
            pasteboard.writeString(text)
            Log.shared.info("insertion: target app gone, left text on clipboard")
            return .clipboardOnly(reasonKey: "insert.reason.targetGone")
        }

        // Bring the original target back to front if focus moved during
        // transcription.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled {
                    return .clipboardOnly(reasonKey: "insert.reason.targetGone")
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    break
                }
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                pasteboard.writeString(text)
                Log.shared.info("insertion: could not re-activate target, left text on clipboard")
                return .clipboardOnly(reasonKey: "insert.reason.targetGone")
            }
        }

        guard accessibilityTrusted else {
            pasteboard.writeString(text)
            Log.shared.info("insertion: no Accessibility permission, left text on clipboard")
            return .clipboardOnly(reasonKey: "insert.reason.noAccessibility")
        }

        switch focusedElementKind(pid: target.processIdentifier) {
        case .secureField:
            // Never auto-type into password fields.
            pasteboard.writeString(text)
            Log.shared.info("insertion: secure text field detected, left text on clipboard")
            return .clipboardOnly(reasonKey: "insert.reason.secureField")
        case .editable(let element):
            if insertViaAccessibility(text, element: element) {
                Log.shared.info("insertion: via Accessibility (chars: \(text.count))")
                return .insertedViaAccessibility
            }
        case .none:
            // No editable focus is visible via Accessibility. The paste may
            // still land (apps with poor AX support), but it may equally go
            // nowhere — so paste WITHOUT restoring the old clipboard: the
            // dictation must never be lost. The user is told it is on the
            // clipboard in case nothing visibly happened.
            if await pasteWithClipboardRestore(text, restoreAfterPaste: false) {
                Log.shared.info("insertion: no focused text field; pasted and kept text on clipboard (chars: \(text.count))")
                return .clipboardOnly(reasonKey: "insert.reason.noFocusedField")
            }
        }

        if await pasteWithClipboardRestore(text) {
            Log.shared.info("insertion: via simulated paste (chars: \(text.count))")
            return .pastedViaClipboard
        }

        guard !Task.isCancelled else {
            return .clipboardOnly(reasonKey: "insert.reason.pasteFailed")
        }
        pasteboard.writeString(text)
        Log.shared.info("insertion: paste failed, left text on clipboard")
        return .clipboardOnly(reasonKey: "insert.reason.pasteFailed")
    }

    // MARK: - Accessibility path

    private enum FocusKind {
        case editable(AXUIElement)
        case secureField
        case none
    }

    private func focusedElementKind(pid: pid_t) -> FocusKind {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .none
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == kAXSecureTextFieldSubrole as String {
            return .secureField
        }
        return .editable(element)
    }

    private func insertViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        // Replacing the (usually empty) selection inserts at the caret.
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .success
    }

    // MARK: - Clipboard + synthetic ⌘V path

    @MainActor
    private func pasteWithClipboardRestore(_ text: String, restoreAfterPaste: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        let previousItems = pasteboard.snapshotItems()
        let hadPreviousContent = !previousItems.isEmpty
        let countAfterWrite = pasteboard.writeString(text)

        guard postCmdV() else {
            return false
        }
        guard restoreAfterPaste else {
            return true
        }

        // The target app needs time to consume the pasteboard before the
        // restore. An unstructured Task does not inherit the pipeline's
        // cancellation, so a cancel arriving after ⌘V was posted cannot
        // collapse this grace period and restore the clipboard too early.
        let pasteboard = self.pasteboard
        let restore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if ClipboardRestorePolicy.shouldRestore(
                changeCountAfterOurWrite: countAfterWrite,
                currentChangeCount: pasteboard.changeCount,
                hadPreviousContent: hadPreviousContent) {
                pasteboard.restore(previousItems)
                Log.shared.debug("clipboard restored after paste")
            }
        }
        _ = await restore.value
        return true
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
