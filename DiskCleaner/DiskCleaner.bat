@echo off
chcp 65001 >nul
setlocal

echo.
echo  =============================================
echo   DiskCleaner
echo  =============================================
echo.

set /p targetPath="  Path to analyze (leave blank for current dir): "
if "%targetPath%"=="" set "targetPath=%CD%"

echo.
powershell.exe -ExecutionPolicy Bypass -File "%~dp0DiskCleaner.ps1" -Path "%targetPath%"

endlocal
