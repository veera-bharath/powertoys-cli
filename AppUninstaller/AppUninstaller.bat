@echo off
chcp 65001 >nul
setlocal

echo.
echo  =============================================
echo   AppUninstaller
echo  =============================================
echo.

set /p includeStore="  Include Microsoft Store apps? [Y/N] (default N): "

if /i "%includeStore%"=="Y" (
    powershell.exe -ExecutionPolicy Bypass -File "%~dp0AppUninstaller.ps1" -IncludeStore
) else (
    powershell.exe -ExecutionPolicy Bypass -File "%~dp0AppUninstaller.ps1"
)

endlocal
