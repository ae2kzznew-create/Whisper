# Third-Party Notices

VoxLocal bundles or uses the following third-party software.

## whisper.cpp (bundled)

- Source: https://github.com/ggml-org/whisper.cpp — pinned to tag **v1.9.1**
- Usage: compiled to the `whisper-cli` executable that ships inside `VoxLocal.app/Contents/MacOS/` and performs on-device speech recognition (includes ggml and its Metal backend).
- License: MIT

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Whisper models (downloaded by the user, not bundled)

- Source: https://huggingface.co/ggerganov/whisper.cpp (ggml conversions of OpenAI Whisper weights)
- Original model: OpenAI Whisper — https://github.com/openai/whisper — MIT License.
- Models are downloaded only on explicit user action and stored in `~/Library/Application Support/VoxLocal/models`.

## CMake (build tool only, not distributed)

- Source: https://cmake.org (Kitware), version 3.30.5, downloaded into `vendor/tools/` by `scripts/bootstrap.sh` **only if** cmake is not already installed.
- License: BSD 3-Clause. CMake is used exclusively at build time and is not part of the application bundle.

## Ollama (optional, user-installed)

- https://ollama.com — MIT License. Not bundled, not required. VoxLocal only talks to a user-installed Ollama server over localhost when refinement is enabled.

## Apple frameworks

AppKit, SwiftUI, AVFoundation, CoreAudio, Carbon (HIToolbox), ApplicationServices, ServiceManagement — used under the Apple SDK license as part of macOS.
