import AppKit
import SwiftUI

/// Floating dictation indicator. A borderless, non-activating `NSPanel`
/// keeps keyboard focus in the user's current application.
@MainActor
public final class OverlayWindowController {
    private var panel: NSPanel?
    private weak var dictation: DictationController?
    private var hideTask: Task<Void, Never>?

    public init(dictation: DictationController) {
        self.dictation = dictation
        dictation.onStateChange = { [weak self] state in
            self?.handle(state: state)
        }
    }

    private func handle(state: DictationState) {
        switch state {
        case .idle:
            hide()
        case .preparing, .recording, .stopping, .transcribing, .refining, .inserting:
            show()
        case .completed, .cancelled, .error:
            show() // stays briefly; controller resets to .idle which hides it
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        if let dictation {
            panel.contentView = NSHostingView(rootView: OverlayView(dictation: dictation))
        }
        return panel
    }

    public func show() {
        hideTask?.cancel()
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        if !panel.isVisible {
            position(panel)
            // orderFrontRegardless keeps the target app active/focused.
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// SwiftUI content of the overlay: state icon, title, secondary message and
/// a live microphone level meter while listening.
struct OverlayView: View {
    @ObservedObject var dictation: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if dictation.state == .recording {
                    LevelMeter(level: dictation.micLevel, animate: !reduceMotion)
                        .frame(height: 10)
                        .accessibilityLabel(L10n.t("overlay.level.ax"))
                } else if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.t("app.name")): \(title). \(subtitle)")
    }

    private var title: String {
        L10n.t("state.\(dictation.state.rawValue)")
    }

    private var subtitle: String {
        if !dictation.statusMessage.isEmpty {
            return dictation.statusMessage
        }
        switch dictation.state {
        case .recording, .transcribing, .refining:
            return L10n.t("overlay.esc")
        default:
            return ""
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch dictation.state {
        case .preparing:
            Image(systemName: "mic")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
        case .stopping, .transcribing:
            ProgressView()
                .controlSize(.small)
        case .refining:
            Image(systemName: "wand.and.stars")
                .font(.system(size: 17))
                .foregroundStyle(.purple)
        case .inserting:
            Image(systemName: "text.insert")
                .font(.system(size: 17))
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }
}

/// Simple animated bar meter driven by the recorder's RMS level.
struct LevelMeter: View {
    let level: Float
    let animate: Bool
    private let barCount = 12

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let threshold = Float(index) / Float(barCount)
                    let active = level > threshold
                    RoundedRectangle(cornerRadius: 1)
                        .fill(active ? barColor(threshold) : Color.primary.opacity(0.15))
                        .frame(width: (geo.size.width - CGFloat(barCount - 1) * 2) / CGFloat(barCount))
                }
            }
        }
        .animation(animate ? .linear(duration: 0.08) : nil, value: level)
    }

    private func barColor(_ threshold: Float) -> Color {
        if threshold > 0.8 { return .orange }
        return .green
    }
}
