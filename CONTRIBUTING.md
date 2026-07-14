# Contributing to VoxLocal

Thanks for your interest! VoxLocal is a privacy-first, fully local macOS dictation app. Contributions must preserve that core promise.

## Ground rules

1. **Privacy is non-negotiable.**
   - No cloud APIs for audio, transcripts or prompts. Refinement providers must be local (loopback) only.
   - No analytics, telemetry, tracking or crash-reporting SDKs.
   - Logs must never contain audio, transcript text or clipboard contents.
2. **No global package managers as build requirements.** Anything a build needs must be project-local (`vendor/`) or a standard macOS/Xcode tool.
3. **Pin dependencies** to a tag or commit and update `THIRD_PARTY_NOTICES.md` when adding/upgrading anything.
4. **Tests required** for logic changes: state machine, parsers, safeguards, settings, insertion policy — everything testable without a microphone should be tested (`swift test`).

## Development workflow

```bash
./scripts/bootstrap.sh   # once: whisper.cpp + project-local cmake
./scripts/test.sh        # must pass before any PR
swift run VoxLocal       # dev run without packaging (uses vendor/ whisper-cli)
./scripts/build_app.sh   # full bundle at dist/VoxLocal.app
```

Repository layout: application logic lives in `Sources/VoxLocalCore` (library, unit-testable), the executable target `Sources/VoxLocal` only boots AppKit. Tests are in `Tests/VoxLocalTests`.

## Style

- Swift 5.10+ / SwiftUI + AppKit, 4-space indentation.
- Prefer simple, dependable implementations over abstractions. New protocols should exist to enable testing or a real second implementation.
- User-facing strings go through `L10n.t(...)` and must be added to **both** `ru.lproj` and `en.lproj`.

## Reporting issues

Include macOS version, hardware (Apple Silicon/Intel), the model used, and the relevant tail of `~/Library/Logs/VoxLocal/voxlocal.log` (it is privacy-safe by design). Never attach recordings of private content.
