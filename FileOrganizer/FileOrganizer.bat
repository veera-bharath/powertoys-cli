@echo off
:: Launcher for FileOrganizer.ps1
:: Prompts for a target path; uses the script's own directory if left blank.

set /p targetPath="Enter directory path to organize (leave blank for current dir): "

if "%targetPath%"=="" (
    set "targetPath=%~dp0"
)

powershell.exe -ExecutionPolicy Bypass -File "%~dp0FileOrganizer.ps1" -Path "%targetPath%"

pause
