# VoxLocal — Build Report / Engineering Log

Status: **READY** — `dist/VoxLocal.app` built, ad-hoc signed, smoke-launched; all automated tests pass (76 tests, 0 failures; see "Final results").

## Environment (detected 2026-07-13)

| Item | Value |
|---|---|
| macOS | 26.2 (build 25C56) |
| CPU | Apple Silicon, arm64, 14 cores |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| Xcode | 26.6 (17F113), full Xcode at /Applications/Xcode.app |
| cmake | not installed system-wide → project-local cmake 3.30.5 downloaded into `vendor/tools/` |
| git | 2.54.0 |
| Free disk | ~167 GiB |

## Key technical decisions

1. **whisper.cpp pinned to tag `v1.9.1`** (latest stable release at time of writing), cloned shallow into `vendor/whisper.cpp`.
2. **Subprocess integration**: `whisper-cli` is built statically (`BUILD_SHARED_LIBS=OFF`) with Metal (`GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` so the Metal shader library is embedded and a single binary can be bundled). The app invokes it via `Process` with JSON output (`-oj`) for robust parsing. Chosen over linking libwhisper because it isolates crashes, simplifies the SPM build, and matches the task's stated preference.
3. **cmake without Homebrew**: cmake is not installed on this machine and global package managers must not be required, so `bootstrap.sh` downloads the official Kitware universal binary tarball into `vendor/tools/` (no sudo, nothing outside the repo).
4. **App lifecycle**: AppKit `NSApplication` + `NSStatusItem` menu-bar app (no Dock icon via `LSUIElement`), SwiftUI for Settings/Onboarding/Overlay content views hosted in AppKit windows/panels. Overlay is a non-activating `NSPanel`.
5. **Global hotkey**: Carbon `RegisterEventHotKey` with both `kEventHotKeyPressed` and `kEventHotKeyReleased` handlers — supports press-and-hold *and* toggle modes and needs **no** Accessibility permission for the hotkey itself. Registration failure (`eventHotKeyExistsErr`) is surfaced as a conflict error. `Escape` is registered as a temporary hotkey only while a dictation session is active (cancellation).
6. **Audio**: `AVAudioEngine` input tap → `AVAudioConverter` → 16 kHz mono PCM16 WAV in a temporary directory; deleted after success/cancel/error. RMS level published for the overlay meter.
7. **Insertion**: Accessibility API (`AXUIElementSetAttributeValue` on `kAXSelectedText`) first; clipboard + synthetic ⌘V (CGEvent) fallback with pasteboard save/restore guarded by `changeCount`; final fallback = leave text on clipboard and tell the user.
8. **Refinement**: `TextRefinementProvider` protocol; `NoRefinementProvider`, `OllamaRefinementProvider` (localhost only, default `http://127.0.0.1:11434`), `MockRefinementProvider` for tests. Safeguard falls back to the raw transcript on empty/implausible/oversized output.
9. **Models**: catalog of ggml models (tiny/base/small/medium/large-v3, ×.en variants) downloaded from the official `ggerganov/whisper.cpp` Hugging Face repo (same source the upstream `download-ggml-model.sh` uses) with size shown and explicit in-app confirmation; integrity via ggml magic-number + minimum-size check.
10. **Localization**: Russian default, English included; in-app language override (system/ru/en) via a small L10n layer over `.lproj` bundles.
11. **License**: MIT.

## Implementation plan

- Phase 2: SPM package, state machine, settings store, bounded file logger, L10n. Unit tests from the start.
- Phase 3: recorder + WAV writer; Whisper command builder/parser/runner; model manager.
- Phase 4: hotkeys, overlay panel, inserter.
- Phase 5: refinement providers + safeguard + presets.
- Phase 6: onboarding, settings UI, privacy screen, strings RU/EN, accessibility.
- Phase 7: `test.sh`, `build_app.sh` (bundle assembly, Info.plist, ad-hoc codesign), smoke launch.
- Phase 8: audit sweep, docs, final report below.

## Commands run (chronological highlights)

- `sw_vers && uname -m && swift --version && xcodebuild -version` — environment survey (see table above).
- `git ls-remote --tags https://github.com/ggml-org/whisper.cpp.git` — chose pin `v1.9.1` (commit `f049fff95a089aa9969deb009cdd4892b3e74916`).
- `./scripts/bootstrap.sh` — downloaded project-local cmake 3.30.5, shallow-cloned whisper.cpp v1.9.1, built static `whisper-cli` (Metal embedded, arm64, 3.2 MB). **Succeeded**; re-run later to confirm idempotency — also succeeded.
- `swift build` / `swift build --build-tests` — iterated until zero errors/warnings.
- `./scripts/download_model.sh base -y` — installed `ggml-base.bin` (147 MB) to `~/Library/Application Support/VoxLocal/models`; ggml magic verified.
- `./scripts/test.sh` (= `swift test`) — **76 tests, 0 failures, 1 skip** (see below).
- `./scripts/build_app.sh` — release build, bundle assembly, Info.plist generation, ad-hoc codesign + verify. **Succeeded.**
- `open dist/VoxLocal.app` — smoke launch: process alive >7 s, `lsappinfo` type=`UIElement` (no Dock icon), log shows startup + `hotkey registered: ⌥Space`; terminated cleanly.

## Test results (final run)

```
Test Suite 'All tests' passed
Executed 76 tests, with 1 test skipped and 0 failures (0 unexpected)
```

- Suites: state machine (8), Whisper command builder (3), Whisper output parser (8), transcriber error mapping with mock runner (6, 1 skip*), model manager & catalog (10), refinement prompts (5), refinement safeguard (6), refinement pipeline fallback incl. cancellation (6), Ollama provider endpoint/body (3), settings persistence (3), clipboard restore policy (4), permission gating (5), key combo (5), WAV writer (2), path redactor (1), **integration smoke (1)**.
- **Integration smoke test runs for real** (not skipped): `say` → `afconvert` (16 kHz mono PCM16) → bundled `whisper-cli` with `ggml-base.bin` → non-empty transcript containing expected words. ~9 s on this machine.
- \*The one skipped test is `testMissingBinaryError`: it verifies the missing-binary error path, which is untestable on a machine where the real `whisper-cli` is discoverable at the vendor path; the skip message says exactly that. When the model is absent, the integration test skips with: *"SKIPPED: no Whisper model installed. Run ./scripts/download_model.sh base"* — skips are never reported as passes.

## Final audit (Phase 8)

Placeholder sweep over `Sources/`, `scripts/`, `Tests/` (vendor excluded): **zero** hits for TODO / FIXME / fatalError / preconditionFailure / "not implemented" / stub in production code. Justified remnants:
- two `try!` in `WhisperOutputParser` on compile-time-constant regex literals (exercised by every test run);
- the word "Placeholder" appears once in a `WAVWriter` comment describing the standard rewrite-header-on-finalize WAV technique — not stub code.

A five-dimension multi-agent audit (concurrency/cancellation, privacy, macOS API correctness, localization completeness, docs/scripts accuracy) with adversarial verification confirmed and I fixed:

1. **AudioRecorder data race** — the AVAudioEngine tap thread shared `writer`/`converter`/`peak` with main-thread `stop()/cancel()`; a late tap callback could race `WAVWriter.finalize()` and corrupt the WAV. Fixed with a single `NSLock` guarding all shared state; teardown detaches the writer under the lock.
2. **Cancellation during insertion** — a cancelled pipeline task made `try? await Task.sleep` return immediately, so the clipboard could be restored before the target app consumed ⌘V; side effects could also occur after cancel. Fixed: cancellation guards before any clipboard write/keystroke, and the paste-grace-period + restore now runs in an unstructured task immune to the cancel.
3. **Privacy: HTTP redirects** — URLSession would follow a 307 redirect from a local listener, potentially re-sending the transcript off-machine. Fixed with a `URLSessionTaskDelegate` that refuses all redirects; also removed `0.0.0.0` from the loopback allowlist.
4. **Hotkey re-registration** — changing to a conflicting combo unregistered the old hotkey before the new registration failed, leaving no hotkey at all. Fixed: register-new-then-unregister-old.

Fixed proactively during the audit window: `NSMenu.autoenablesItems = false` (menu items' manual enabled state was ignored), toggle-mode key-repeat debounce (350 ms), `testModeSink` cleared on every terminal state (a verifier later confirmed the fix as correct).

Localization audit: every `L10n.t` key (including dynamically built `state.*`, `refine.preset.*`, `privacy.p1–5`, `onboarding.welcome.point1–4`) present in both `ru.lproj` and `en.lproj` with matching format specifiers — zero findings.

After all fixes: full rebuild, `swift test` re-run (76/0/1), bundle rebuilt, re-signed, smoke-launched again — all green.

## Verified automatically vs. requires manual testing

**Verified automatically on this machine:**
- bootstrap, unit + integration tests, release build, bundle assembly, ad-hoc signature (`codesign --verify` passes), app launch without crash, UIElement (no Dock) activation policy, global hotkey registration (log-confirmed), real local transcription via `whisper-cli` + Metal on synthesized speech, model download + ggml integrity check, script idempotency.

**Requires manual macOS permission testing (cannot be automated without bypassing TCC, which was not attempted):**
- Granting Microphone and Accessibility permissions in System Settings and the onboarding recheck flow.
- Real microphone dictation end-to-end (hold ⌥Space → speak → release → text lands in TextEdit), including Cyrillic rendering in the target app.
- Overlay focus behavior during real use; Esc cancellation while another app is frontmost.
- Clipboard fallback path in an app that rejects synthetic paste; secure-field behavior.
- Ollama refinement against a locally installed Ollama (fallback-to-raw path is covered by unit tests; live-server path needs Ollama installed).
- Launch-at-login toggle (SMAppService requires user approval in System Settings).

## Known limitations

- Ad-hoc signature: macOS treats each rebuild as a new app → Microphone/Accessibility must be re-granted after rebuilding. Distribution to other Macs needs right-click → Open (Gatekeeper).
- `Esc` is captured system-wide only while a dictation session is active (released immediately after); this is the documented cancellation mechanism.
- No streaming partial transcripts — Whisper runs after recording stops.
- Interface-language change applies to new windows/menus immediately; an already-open settings window keeps some labels until reopened.
- No app icon (menu-bar-only app); cosmetic.

## Final artifact

```
dist/VoxLocal.app   (arm64, ad-hoc signed, org.voxlocal.VoxLocal, v1.0.0)
├── Contents/MacOS/VoxLocal      1.9 MB
├── Contents/MacOS/whisper-cli   3.2 MB (whisper.cpp v1.9.1, static, Metal embedded)
└── Contents/Resources/VoxLocal_VoxLocalCore.bundle (ru/en localizations)
```

Rebuild from scratch: `./scripts/bootstrap.sh && ./scripts/test.sh && ./scripts/build_app.sh && ./scripts/run.sh`.

## Addendum — Intel iMac / macOS 13.7 port (2026-07-16)

Environment: Intel x86_64 iMac, macOS 13.7.8, Swift 5.8.1 (CLT 14.3, no full Xcode).

- SwiftPM is unusable there: `swift build` fails with `xcrun: unable to lookup item 'PlatformPath'` (CLT 14.x has no platform dir; fixed upstream in later toolchains). `swift test` impossible — CLT ships without XCTest.
- Added `scripts/build_app_direct.sh`: compiles VoxLocalCore + entry point with plain swiftc as a single module (generates a `Bundle.module` shim replicating SwiftPM's accessor), assembles and ad-hoc signs `dist/VoxLocal.app` with `LSMinimumSystemVersion` 13.0.
- `Package.swift` lowered to swift-tools 5.8 / platform .v13 (still builds with the modern toolchain).
- `VoxLocalMain` now uses `@MainActor static func main()` instead of `MainActor.assumeIsolated` (unavailable in the macOS 13 SDK; behaviour identical).
- Verified on the iMac: bootstrap (whisper-cli built without Metal), app launches (UIElement, hotkey ⌥Space registered), end-to-end `say` → `afconvert` → `whisper-cli` transcription passes in Russian and English with `ggml-base.bin` (~3 s per short phrase, CPU only).
