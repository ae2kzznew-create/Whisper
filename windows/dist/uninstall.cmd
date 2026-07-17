@echo off
setlocal
chcp 65001 >nul
title Полное удаление Voice2kzz

set "TARGET=%~dp0"
if "%TARGET:~-1%"=="\" set "TARGET=%TARGET:~0,-1%"

echo ============================================================
echo  Полное удаление Voice2kzz
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

echo Останавливаю Voice2kzz...
taskkill /im Voice2kzz.exe /f >nul 2>nul
taskkill /im VoxLocal.exe /f >nul 2>nul

echo Убираю автозапуск...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v VoxLocal /f >nul 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Voice2kzz /f >nul 2>nul

echo Удаляю настройки, модели, логи и временный кэш...
rmdir /s /q "%APPDATA%\VoxLocal" >nul 2>nul
rmdir /s /q "%LOCALAPPDATA%\VoxLocal" >nul 2>nul
rmdir /s /q "%TEMP%\.net\VoxLocal" >nul 2>nul
rmdir /s /q "%TEMP%\.net\Voice2kzz" >nul 2>nul
del /q "%TEMP%\voxlocal-*.wav" >nul 2>nul

echo Удаляю папку программы...
echo @echo off> "%TEMP%\voice2kzz-remove.cmd"
echo timeout /t 3 /nobreak ^>nul>> "%TEMP%\voice2kzz-remove.cmd"
echo rmdir /s /q "%TARGET%">> "%TEMP%\voice2kzz-remove.cmd"
echo del "%%~f0">> "%TEMP%\voice2kzz-remove.cmd"
start "" /min /d "%TEMP%" cmd /c "%TEMP%\voice2kzz-remove.cmd"

echo.
echo Готово. Это окно сейчас закроется, а папка программы исчезнет через пару секунд.
timeout /t 2 /nobreak >nul
exit
