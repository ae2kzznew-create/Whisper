import XCTest
@testable import VoxLocalCore

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "voxlocal.tests.settings"

    override func setUp() {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hotkeyKeyCode, 49) // Space
        XCTAssertEqual(store.hotkeyModifiers, 0x0800) // Option
        XCTAssertEqual(store.hotkeyMode, .pressAndHold)
        XCTAssertEqual(store.whisperModel, "base")
        XCTAssertEqual(store.spokenLanguage, .auto)
        XCTAssertFalse(store.refinementEnabled)
        XCTAssertEqual(store.ollamaEndpoint, "http://127.0.0.1:11434")
        XCTAssertEqual(store.refinementPreset, .cleanDictation)
        XCTAssertEqual(store.insertionMode, .automatic)
        XCTAssertEqual(store.interfaceLanguage, .russian)
        XCTAssertTrue(store.removeArtifacts)
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertGreaterThanOrEqual(store.whisperThreads, 1)
    }

    func testPersistenceRoundtrip() {
        let store = SettingsStore(defaults: defaults)
        store.hotkeyKeyCode = 3
        store.hotkeyModifiers = KeyCombo.carbonCmd | KeyCombo.carbonShift
        store.hotkeyMode = .toggle
        store.whisperModel = "small"
        store.spokenLanguage = .russian
        store.whisperThreads = 6
        store.refinementEnabled = true
        store.ollamaModel = "qwen2.5:3b"
        store.refinementPreset = .concise
        store.customInstruction = "инструкция"
        store.refinementTimeout = 35
        store.insertionMode = .clipboardOnly
        store.interfaceLanguage = .english
        store.logLevel = .debug
        store.onboardingCompleted = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotkeyKeyCode, 3)
        XCTAssertEqual(reloaded.hotkeyModifiers, KeyCombo.carbonCmd | KeyCombo.carbonShift)
        XCTAssertEqual(reloaded.hotkeyMode, .toggle)
        XCTAssertEqual(reloaded.whisperModel, "small")
        XCTAssertEqual(reloaded.spokenLanguage, .russian)
        XCTAssertEqual(reloaded.whisperThreads, 6)
        XCTAssertTrue(reloaded.refinementEnabled)
        XCTAssertEqual(reloaded.ollamaModel, "qwen2.5:3b")
        XCTAssertEqual(reloaded.refinementPreset, .concise)
        XCTAssertEqual(reloaded.customInstruction, "инструкция")
        XCTAssertEqual(reloaded.refinementTimeout, 35)
        XCTAssertEqual(reloaded.insertionMode, .clipboardOnly)
        XCTAssertEqual(reloaded.interfaceLanguage, .english)
        XCTAssertEqual(reloaded.logLevel, .debug)
        XCTAssertTrue(reloaded.onboardingCompleted)
    }

    func testResetOnboarding() {
        let store = SettingsStore(defaults: defaults)
        store.onboardingCompleted = true
        store.resetOnboarding()
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertFalse(SettingsStore(defaults: defaults).onboardingCompleted)
    }
}

final class MockPasteboard: Pasteboarding {
    private(set) var changeCount = 0
    private(set) var items: [PasteboardItemSnapshot] = []
    var currentString: String? {
        items.first?.types["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }
    }

    func snapshotItems() -> [PasteboardItemSnapshot] { items }

    @discardableResult
    func writeString(_ string: String) -> Int {
        items = [PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(string.utf8)])]
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func restore(_ restored: [PasteboardItemSnapshot]) -> Int {
        items = restored
        changeCount += 1
        return changeCount
    }

    /// Simulates another application writing to the clipboard.
    func externalWrite(_ string: String) {
        items = [PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(string.utf8)])]
        changeCount += 1
    }
}

final class ClipboardRestoreTests: XCTestCase {
    func testRestoreWhenNobodyElseWrote() {
        let pasteboard = MockPasteboard()
        pasteboard.externalWrite("старое содержимое")
        let previous = pasteboard.snapshotItems()
        let afterOurWrite = pasteboard.writeString("транскрипт")

        XCTAssertTrue(ClipboardRestorePolicy.shouldRestore(
            changeCountAfterOurWrite: afterOurWrite,
            currentChangeCount: pasteboard.changeCount,
            hadPreviousContent: !previous.isEmpty))

        pasteboard.restore(previous)
        XCTAssertEqual(pasteboard.currentString, "старое содержимое")
    }

    func testNoRestoreWhenSomeoneElseWrote() {
        let pasteboard = MockPasteboard()
        pasteboard.externalWrite("старое")
        let previous = pasteboard.snapshotItems()
        let afterOurWrite = pasteboard.writeString("транскрипт")
        pasteboard.externalWrite("новое от другого приложения")

        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(
            changeCountAfterOurWrite: afterOurWrite,
            currentChangeCount: pasteboard.changeCount,
            hadPreviousContent: !previous.isEmpty))
        XCTAssertEqual(pasteboard.currentString, "новое от другого приложения")
    }

    func testNoRestoreWhenClipboardWasEmpty() {
        let pasteboard = MockPasteboard()
        let previous = pasteboard.snapshotItems()
        let afterOurWrite = pasteboard.writeString("транскрипт")

        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(
            changeCountAfterOurWrite: afterOurWrite,
            currentChangeCount: pasteboard.changeCount,
            hadPreviousContent: !previous.isEmpty))
        // The transcript stays available for manual paste.
        XCTAssertEqual(pasteboard.currentString, "транскрипт")
    }

    func testUnicodeAndMultilineSurviveRoundtrip() {
        let pasteboard = MockPasteboard()
        let text = "Первая строка\nВторая строка — ёжик 🦔\nThird line"
        pasteboard.writeString(text)
        XCTAssertEqual(pasteboard.currentString, text)
    }
}

final class PermissionGatingTests: XCTestCase {
    func testMicDeniedBlocks() {
        XCTAssertEqual(
            DictationPreflight.evaluate(microphone: .denied, accessibilityTrusted: true, modelInstalled: true, modelName: "base"),
            .blockedMicrophoneDenied)
    }

    func testMicNotDeterminedRequestsFirst() {
        XCTAssertEqual(
            DictationPreflight.evaluate(microphone: .notDetermined, accessibilityTrusted: false, modelInstalled: true, modelName: "base"),
            .needsMicrophoneRequest)
    }

    func testMissingModelBlocksWithName() {
        XCTAssertEqual(
            DictationPreflight.evaluate(microphone: .granted, accessibilityTrusted: true, modelInstalled: false, modelName: "small"),
            .blockedModelMissing(modelName: "small"))
    }

    func testMissingAccessibilityOnlyWarns() {
        XCTAssertEqual(
            DictationPreflight.evaluate(microphone: .granted, accessibilityTrusted: false, modelInstalled: true, modelName: "base"),
            .ready(warnAccessibilityMissing: true))
    }

    func testAllGranted() {
        XCTAssertEqual(
            DictationPreflight.evaluate(microphone: .granted, accessibilityTrusted: true, modelInstalled: true, modelName: "base"),
            .ready(warnAccessibilityMissing: false))
    }
}

final class KeyComboTests: XCTestCase {
    func testDefaultComboIsOptionSpace() {
        let combo = KeyCombo.default
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.modifiers, KeyCombo.carbonOption)
        XCTAssertEqual(combo.displayString, "⌥Space")
    }

    func testDisplayStringModifierOrder() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.carbonCmd | KeyCombo.carbonShift | KeyCombo.carbonControl | KeyCombo.carbonOption)
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘Space")
    }

    func testCodableRoundtrip() throws {
        let combo = KeyCombo(keyCode: 3, modifiers: KeyCombo.carbonCmd)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
    }

    func testNSEventConversion() {
        let combo = KeyCombo.fromNSEvent(keyCode: 49, flags: [.option, .command])
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.modifiers, KeyCombo.carbonOption | KeyCombo.carbonCmd)
    }

    func testSpecialKeyNames() {
        XCTAssertEqual(KeyCombo.keyName(for: 53), "Esc")
        XCTAssertEqual(KeyCombo.keyName(for: 36), "↩")
    }
}

final class WAVWriterTests: XCTestCase {
    func testHeaderAndDataLayout() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, sampleRate: 16000)
        let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
        try writer.append(samples)
        try writer.finalize()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")

        // sample rate at offset 24 (LE)
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        XCTAssertEqual(rate, 16000)
        // channels at offset 22
        let channels = data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        XCTAssertEqual(channels, 1)
        // bits per sample at offset 34
        let bits = data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        XCTAssertEqual(bits, 16)
        // data chunk size at offset 40
        let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        XCTAssertEqual(Int(dataSize), samples.count * 2)

        // first real sample after header
        let s0 = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        XCTAssertEqual(s0, 0)
        let s1 = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        XCTAssertEqual(s1, 1000)
    }

    func testDurationAndCancel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-wav-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, sampleRate: 16000)
        try writer.append([Int16](repeating: 0, count: 16000))
        XCTAssertEqual(writer.duration, 1.0, accuracy: 0.001)
        writer.cancelAndDelete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class PathRedactorTests: XCTestCase {
    func testHomeRedaction() {
        let home = NSHomeDirectory()
        XCTAssertEqual(PathRedactor.redact("\(home)/Library/x.log"), "~/Library/x.log")
        XCTAssertEqual(PathRedactor.redact("/usr/local/bin"), "/usr/local/bin")
    }
}
