@echo off
setlocal
chcp 65001 >nul
title VoxLocal - установка Ollama

echo ============================================================
echo  VoxLocal: установка Ollama - локальная доработка текста ИИ
echo ============================================================
echo.
echo Всё скачивается только с официального сервера ollama.com
echo и работает полностью локально - текст никуда не отправляется.
echo.

set "OLLAMA_EXE=%LOCALAPPDATA%\Programs\Ollama\ollama.exe"

where ollama >nul 2>nul
if %errorlevel%==0 goto pull
if exist "%OLLAMA_EXE%" goto pull

echo [1/2] Скачиваю установщик Ollama - примерно 700 МБ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile '%TEMP%\OllamaSetup.exe'"
if errorlevel 1 (
    echo ОШИБКА: не удалось скачать установщик. Проверьте интернет и запустите файл ещё раз.
    pause
    exit /b 1
)

echo [1/2] Устанавливаю Ollama...
start /wait "" "%TEMP%\OllamaSetup.exe" /VERYSILENT /NORESTART
del "%TEMP%\OllamaSetup.exe" >nul 2>nul

:pull
set "OLLAMA_CMD=ollama"
if exist "%OLLAMA_EXE%" set "OLLAMA_CMD=%OLLAMA_EXE%"

echo [2/2] Скачиваю языковую модель qwen2.5:3b - примерно 2 ГБ, только в первый раз...
"%OLLAMA_CMD%" pull qwen2.5:3b
if errorlevel 1 (
    echo ОШИБКА: не удалось скачать модель. Запустите этот файл ещё раз.
    pause
    exit /b 1
)

echo.
echo ГОТОВО! Осталось один раз включить в настройках VoxLocal:
echo   Настройки - Доработка текста - включить, модель: qwen2.5:3b
echo   Адрес оставить по умолчанию: http://127.0.0.1:11434
echo.
pause
