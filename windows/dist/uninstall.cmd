@echo off
setlocal
chcp 65001 >nul
title Полное удаление VoxLocal

set "TARGET=%~dp0"
if "%TARGET:~-1%"=="\" set "TARGET=%TARGET:~0,-1%"

echo ============================================================
echo  Полное удаление VoxLocal
echo ============================================================
echo.
echo Будут удалены:
echo   - папка программы:  %TARGET%
echo   - настройки:        %APPDATA%\VoxLocal
echo   - модели и логи:    %LOCALAPPDATA%\VoxLocal
echo   - временный кэш и автозапуск при входе в систему
echo.
set /p CONFIRM=Продолжить? [y/N]: 
if /i not "%CONFIRM%"=="y" (
    echo Отменено. Ничего не удалено.
    pause
    exit /b 0
)

echo Останавливаю VoxLocal...
taskkill /im VoxLocal.exe /f >nul 2>nul

echo Убираю автозапуск...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v VoxLocal /f >nul 2>nul

echo Удаляю настройки, модели, логи и временный кэш...
rmdir /s /q "%APPDATA%\VoxLocal" >nul 2>nul
rmdir /s /q "%LOCALAPPDATA%\VoxLocal" >nul 2>nul
rmdir /s /q "%TEMP%\.net\VoxLocal" >nul 2>nul
del /q "%TEMP%\voxlocal-*.wav" >nul 2>nul

echo Удаляю папку программы...
echo @echo off> "%TEMP%\voxlocal-remove.cmd"
echo timeout /t 3 /nobreak ^>nul>> "%TEMP%\voxlocal-remove.cmd"
echo rmdir /s /q "%TARGET%">> "%TEMP%\voxlocal-remove.cmd"
echo del "%%~f0">> "%TEMP%\voxlocal-remove.cmd"
start "" /min /d "%TEMP%" cmd /c "%TEMP%\voxlocal-remove.cmd"

echo.
echo Готово. Это окно сейчас закроется, а папка программы исчезнет через пару секунд.
timeout /t 2 /nobreak >nul
exit
