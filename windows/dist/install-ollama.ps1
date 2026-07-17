# Voice2kzz — установка Ollama (локальное улучшение текста).
# Всё скачивается только с официального ollama.com и работает локально.
# Технический вывод скрыт: показываются только шаги и аккуратная анимация.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Voice2kzz · установка Ollama' } catch { }

function Show-Header {
    Clear-Host
    Write-Host ''
    Write-Host '   ──────────────────────────────────────────────────' -ForegroundColor DarkMagenta
    Write-Host '     V O I C E 2 K Z Z' -ForegroundColor Magenta
    Write-Host '     Установка Ollama — умное улучшение текста' -ForegroundColor White
    Write-Host '   ──────────────────────────────────────────────────' -ForegroundColor DarkMagenta
    Write-Host ''
    Write-Host '     Всё скачивается только с официального ollama.com' -ForegroundColor DarkGray
    Write-Host '     и работает целиком на этом ПК — без облака.' -ForegroundColor DarkGray
    Write-Host ''
}

# Ожидание с анимацией: никакого технического вывода, только шаг и «крутилка».
function Wait-Spinner([string]$label, [scriptblock]$isDone) {
    $frames = '|', '/', '-', '\'
    $i = 0
    while (-not (& $isDone)) {
        Write-Host -NoNewline ("`r     [" + $frames[$i % 4] + '] ' + $label + '  ')
        Start-Sleep -Milliseconds 160
        $i++
    }
    Write-Host ("`r     [+] " + $label + '  ') -ForegroundColor Green
}

function Fail([string]$message) {
    Write-Host ''
    Write-Host ('     [x] ' + $message) -ForegroundColor Red
    Write-Host '         Проверьте интернет и запустите установку ещё раз.' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Нажмите Enter, чтобы закрыть' | Out-Null
    exit 1
}

Show-Header

$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$ollamaCmd = $null
if (Get-Command ollama -ErrorAction SilentlyContinue) { $ollamaCmd = 'ollama' }
elseif (Test-Path $ollamaExe) { $ollamaCmd = $ollamaExe }

if (-not $ollamaCmd) {
    # Шаг 1: скачивание установщика (прогресс скрыт намеренно).
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    $job = Start-Job -ScriptBlock {
        param($url, $out)
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    } -ArgumentList 'https://ollama.com/download/OllamaSetup.exe', $setup
    Wait-Spinner 'Шаг 1 из 3 · Скачиваю Ollama с ollama.com (~1,5 ГБ)' { $job.State -ne 'Running' }
    if ($job.State -ne 'Completed') { Fail 'Не удалось скачать установщик Ollama.' }
    Remove-Job $job -Force

    # Шаг 2: тихая установка, без окон и вопросов.
    $p = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/NORESTART' -PassThru
    Wait-Spinner 'Шаг 2 из 3 · Устанавливаю Ollama (тихи