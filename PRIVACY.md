# VoxLocal Privacy Policy / Политика конфиденциальности

## English

VoxLocal is designed so that your speech never leaves your Mac.

- **Audio.** Recording goes to a temporary 16 kHz WAV file in the system temporary directory. It exists only for the duration of one dictation and is deleted immediately after successful insertion, cancellation, or any error. There is no recording history and no opt-in to keep recordings in this version.
- **Transcription.** Performed entirely on-device by a bundled `whisper.cpp` binary. No transcription service, no API key, no account.
- **Text refinement (optional).** If you enable it, the transcript is sent to an Ollama server **on your own machine**. The endpoint is restricted to loopback addresses (`127.0.0.1`, `localhost`, `::1`); any other host is rejected. If Ollama is unavailable, the raw transcript is used.
- **Network.** The app makes exactly one kind of outbound request: downloading a Whisper model from the official `ggerganov/whisper.cpp` Hugging Face repository — only when you explicitly start it, and only after the approximate size is shown. Nothing else is uploaded or downloaded.
- **Clipboard.** Used only as an insertion mechanism. When simulated paste is used, the previous clipboard contents are restored automatically unless another app changed the clipboard in the meantime. Clipboard contents are never logged.
- **Analytics / telemetry.** None. No trackers, no crash reporters, no advertising SDKs, no unique identifiers.
- **Logs.** A local, size-bounded log (`~/Library/Logs/VoxLocal/`) records events and errors. It never contains raw audio, dictated text, or clipboard contents; home-directory paths are shortened. You can set the log level to *Off*.
- **Settings.** Stored locally in macOS `UserDefaults`.
- **Permissions.** Microphone (recording) and Accessibility (inserting text) are requested through standard macOS mechanisms and can be revoked at any time in System Settings; the app degrades gracefully (clipboard-only mode) without Accessibility.

## Русский

VoxLocal устроен так, чтобы ваша речь никогда не покидала ваш Mac.

- **Аудио.** Запись идёт во временный WAV-файл (16 кГц) в системной временной папке. Он существует только на время одной диктовки и удаляется сразу после вставки, отмены или ошибки. Истории записей нет; в этой версии нет даже настройки, позволяющей их хранить.
- **Распознавание.** Выполняется целиком на устройстве встроенным `whisper.cpp`. Без сервисов распознавания, ключей API и аккаунтов.
- **Улучшение текста (опционально).** Если вы его включили, расшифровка отправляется на сервер Ollama **на вашем же компьютере**. Разрешены только loopback-адреса (`127.0.0.1`, `localhost`, `::1`); любой другой адрес отклоняется. Если Ollama недоступен — используется исходная расшифровка.
- **Сеть.** Единственный тип исходящих запросов — загрузка модели Whisper из официального репозитория `ggerganov/whisper.cpp` на Hugging Face: только по вашей явной команде и только после показа примерного размера. Больше ничего не скачивается и не отправляется.
- **Буфер обмена.** Используется только как механизм вставки. При имитации ⌘V прежнее содержимое буфера автоматически восстанавливается, если его тем временем не изменило другое приложение. Содержимое буфера никогда не пишется в журнал.
- **Аналитика / телеметрия.** Отсутствуют. Ни трекеров, ни crash-репортеров, ни рекламных SDK, ни уникальных идентификаторов.
- **Журналы.** Локальный журнал ограниченного размера (`~/Library/Logs/VoxLocal/`) фиксирует события и ошибки. В нём нет аудио, текста диктовок и содержимого буфера; пути внутри домашней папки сокращаются. Уровень журнала можно выключить совсем.
- **Настройки.** Хранятся локально в `UserDefaults` macOS.
- **Разрешения.** Микрофон (запись) и Универсальный доступ (вставка текста) запрашиваются стандартными средствами macOS и в любой момент отзываются в Настройках системы; без Универсального доступа приложение продолжает работать в режиме «только буфер обмена».
