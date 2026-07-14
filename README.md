# VoxLocal

**Privacy-first, fully local voice dictation for macOS.** Press a global shortcut, speak, release — the recognized text is inserted into whatever app you were using. Speech never leaves your Mac.

Русская версия: [README_RU.md](README_RU.md)

## What it does

- **Menu-bar app** (no Dock icon) with a global shortcut — default **⌥ Option + Space**:
  - *press-and-hold*: record while held, transcribe on release;
  - *toggle*: press to start, press again to stop.
- **On-device transcription** with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (pinned to `v1.9.1`), Metal-accelerated on Apple Silicon. Russian, English and auto-detection.
- **Optional text refinement** (punctuation, capitalization, filler-word cleanup) through a **local Ollama** server on `localhost`. If Ollama is missing, unreachable, times out or returns nonsense, the raw transcript is used — dictation never breaks.
- **System-wide insertion**: Accessibility API first, simulated ⌘V with clipboard restore second, plain "copied to clipboard" as the last resort.
- A compact floating **overlay** shows ready / listening (with a mic level meter) / transcribing / refining / inserting / completed / cancelled / error. `Esc` cancels. The overlay never steals focus.
- **Russian (default) and English** interface.

## Privacy model

- Audio is recorded to a temporary WAV, transcribed locally and **deleted immediately** after success, cancellation or error.
- **No cloud APIs, no API keys, no accounts.** The only network access is downloading a Whisper model — you start it explicitly and see the size first.
- Ollama refinement talks to `http://127.0.0.1:11434` (configurable, **loopback addresses only** — remote hosts are rejected).
- **No analytics, telemetry, tracking or crash reporting.**
- Logs never contain audio, transcripts or clipboard contents. Details: [PRIVACY.md](PRIVACY.md).

## Requirements

- macOS **14+** (built and tested on macOS 26, Apple Silicon).
- Apple Silicon recommended (Metal acceleration). Intel builds work without Metal.
- Xcode **Command Line Tools** (or full Xcode) to build.
- Disk space: ~500 MB for build artifacts + your chosen model (base ≈ 148 MB, small ≈ 488 MB, large-v3 ≈ 3.1 GB).
- Optional: [Ollama](https://ollama.com) with any instruct model (e.g. `ollama pull qwen2.5:3b`).

## Build & run

```bash
git clone https://github.com/romarayt/VoxLocal.git && cd VoxLocal

./scripts/bootstrap.sh    # checks tools, fetches project-local cmake if needed,
                          # clones whisper.cpp v1.9.1, builds whisper-cli (Metal)
./scripts/test.sh         # runs the automated test suite
./scripts/download_model.sh base   # ~148 MB, asks for confirmation (or use the in-app downloader)
./scripts/build_app.sh    # builds dist/VoxLocal.app (ad-hoc signed)
./scripts/run.sh          # launches the app
```

No Homebrew, CocoaPods or other global package managers are required; everything is project-local (`vendor/`).

## First-run setup (permissions)

The app opens an onboarding wizard that walks through all of this:

1. **Microphone** — macOS shows a prompt at first recording; or System Settings → Privacy & Security → Microphone → enable *VoxLocal*.
2. **Accessibility** (for inserting text into other apps) — System Settings → Privacy & Security → Accessibility → add/enable *VoxLocal*. Without it the app still works: text is copied to the clipboard and you paste with ⌘V.
3. **Model** — download `base` (recommended) from the app (Settings → Transcription) or with `./scripts/download_model.sh`.
4. **Ollama (optional)** — install from ollama.com, `ollama pull qwen2.5:3b`, then enable refinement in Settings → Refinement and pick the model. Change the model any time in the same tab.

> **Note on ad-hoc signing:** each rebuild produces a new signature, so macOS treats it as a new app — you may need to re-grant Microphone/Accessibility after rebuilding.

## Settings overview

Shortcut & mode (hold/toggle), microphone device, Whisper model & spoken language & threads, artifact cleanup, refinement on/off + endpoint + model + preset (raw / clean / concise / business / preserve wording / custom instruction) + timeout, insertion mode (auto / clipboard-only), launch at login, interface language (RU/EN/system), log level, reset onboarding.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Shortcut does nothing | Another app owns ⌥Space — VoxLocal shows a conflict alert; pick another combo in Settings → General. |
| "Microphone access is denied" | System Settings → Privacy & Security → Microphone → enable VoxLocal. |
| Text not inserted, "copied to clipboard" message | Grant Accessibility permission, or paste manually with ⌘V. Secure (password) fields are never auto-filled by design. |
| "No speech model is installed" | Download one in Settings → Transcription (or `./scripts/download_model.sh base`). |
| "whisper-cli not found" | Run `./scripts/bootstrap.sh`, then `./scripts/build_app.sh` again. |
| Refinement never applies | Check Settings → Refinement → "Check": the Ollama server and model must both exist. The endpoint must be a localhost address. |
| Recognition is slow | Use a smaller model (`base`/`tiny`) or increase threads in Settings → Transcription. |
| Reset macOS permissions | `tccutil reset Microphone org.voxlocal.VoxLocal && tccutil reset Accessibility org.voxlocal.VoxLocal` |

Logs: menu bar → *Open Logs* (`~/Library/Logs/VoxLocal/`, bounded size, privacy-filtered).

## Known limitations

- Ad-hoc signature ⇒ permission re-grants after rebuilds (see above); Gatekeeper may require right-click → Open on other Macs.
- While dictation is active, `Esc` is captured globally to allow cancellation; it is released as soon as the session ends.
- Whisper transcribes after recording stops (no streaming partial results).
- Some apps that block synthetic paste (rare, e.g. certain secure terminals) fall back to clipboard-only mode.
- `large-v3` on 8 GB Macs can be slow/memory-hungry; `base`/`small` recommended.

## Uninstall

1. Quit VoxLocal (menu bar → Quit).
2. Delete `dist/VoxLocal.app` (or wherever you copied it).
3. Remove data (optional):
   ```bash
   rm -rf ~/Library/Application\ Support/VoxLocal   # models
   rm -rf ~/Library/Logs/VoxLocal                   # logs
   defaults delete org.voxlocal.VoxLocal 2>/dev/null # settings
   tccutil reset Microphone org.voxlocal.VoxLocal
   tccutil reset Accessibility org.voxlocal.VoxLocal
   ```

## License

MIT — see [LICENSE](LICENSE). Third-party components: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Contributions welcome: [CONTRIBUTING.md](CONTRIBUTING.md).
