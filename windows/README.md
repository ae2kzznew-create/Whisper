# VoxLocal для Windows (портированная версия)

Локальная диктовка: глобальный хоткей → запись с микрофона → распознавание whisper.cpp → (опционально) шлифовка текста через локальную Ollama → вставка в активное приложение. Всё выполняется локально, аудио и текст не покидают компьютер.

Порт оригинального macOS-приложения VoxLocal (Swift/AppKit) на **C#/.NET 8 + WPF**. Лицензия MIT.

## Требования

- Windows 10 21H2+ / Windows 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- Для сборки whisper.cpp: CMake + Visual Studio Build Tools (MSVC)

## Сборка приложения

```powershell
cd VoxLocal
dotnet restore
dotnet build -c Release
```

Результат: `src/VoxLocal.App/bin/Release/net8.0-windows/VoxLocal.exe`.

> **Важно:** перед первой сборкой добавьте иконки и whisper-cli (см. ниже), иначе:
> - без файлов `Icons/*.ico` сборка упадёт (они включены в .csproj как обязательные ресурсы);
> - без `tools/whisper-cli.exe` приложение соберётся, но онбординг сообщит, что движок распознавания не найден.

## 1. Иконки (`src/VoxLocal.App/Icons/`)

Нужны 4 файла: `mic.ico`, `mic-fill.ico`, `waveform.ico`, `mic-slash.ico` (мультиразмерные .ico: 16/24/32/48/256 px). Это аналоги SF Symbols `mic`, `mic.fill`, `waveform`, `mic.slash` — можно сконвертировать любые подходящие глифы (например, из Fluent UI System Icons) в .ico.

## 2. Движок распознавания (`src/VoxLocal.App/tools/`)

Соберите [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (использовалась v1.9.1) под Windows:

```powershell
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Скопируйте в `src/VoxLocal.App/tools/` рядом с будущим exe:
- `build/bin/Release/whisper-cli.exe`
- все `ggml*.dll` / `whisper.dll` из той же папки

(Файлы из `tools/` копируются в выходную папку при сборке; приложение ищет `tools/whisper-cli.exe` рядом с исполняемым файлом.)

## 3. Модели Whisper

Модели (`ggml-*.bin`) скачиваются прямо из приложения (вкладка «Транскрипция» или онбординг) с явным подтверждением размера и сохраняются в `%LOCALAPPDATA%\VoxLocal\models`. Можно положить файлы туда вручную.
Рекомендуемая модель по умолчанию: `base`.

## 4. Шлифовка текста (опционально)

Установите [Ollama](https://ollama.com) и любую модель (например `ollama pull llama3.2`). Приложение обращается только к локальному адресу `http://127.0.0.1:11434`; нелокальные адреса отклоняются, редиректы запрещены. Включается на вкладке «Шлифовка».

## Первый запуск

При первом запуске откроется онбординг: приватность → микрофон → движок → модель → Ollama (опционально) → хоткей → тестовая диктовка. Приложение живёт в трее (главного окна нет).

- Хоткей по умолчанию: **Alt+Space** (режимы: удержание / переключение)
- Настройки: `%APPDATA%\VoxLocal\settings.json`
- Логи: `%LOCALAPPDATA%\VoxLocal\Logs\voxlocal.log`

## Структура проекта

```
VoxLocal/
├── VoxLocal.sln
└── src/VoxLocal.App/
    ├── VoxLocal.App.csproj
    ├── Program.cs, App.xaml(.cs)          # запуск, DI, single-instance
    ├── DictationController.cs             # конечный автомат диктовки
    ├── TrayIconController.cs              # иконка и меню в трее
    ├── OverlayWindow(.xaml/.cs) + Controller  # плавающий индикатор
    ├── SettingsWindow.xaml(.cs)           # настройки (4 вкладки)
    ├── OnboardingWindow.xaml(.cs)         # мастер первого запуска
    ├── Core/                              # платформонезависимая логика
    │   ├── Models, Transcription, Audio, Hotkeys,
    │   ├── Insertion, Refinement, Settings,
    │   └── Permissions, Utilities
    ├── Resources/{ru,en}/Localizable.strings
    ├── Icons/  (добавьте 4 .ico — см. выше)
    └── tools/  (добавьте whisper-cli.exe + DLL — см. выше)
```
