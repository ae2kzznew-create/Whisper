@echo off
setlocal
chcp 65001 >nul
title Voice2kzz · установка Ollama

set "PS1=%~dp0tools\install-ollama.ps1"
if not exist "%PS1%" (
    echo Файл tools\install-ollama.ps1 не найден.
    echo Держите install-ollama.cmd в папке программы рядом с папкой tools.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%
