@echo off
:: Launcher for FileOrganizerAI.ps1
:: Requires Ollama running on localhost:11434.

set /p targetPath="Enter directory path to organize (leave blank for current dir): "
set /p modelName="Enter Ollama model name (leave blank for default gemma:2b): "

if "%targetPath%"=="" (
    set "targetPath=%~dp0"
)
if "%modelName%"=="" (
    set "modelName=gemma:2b"
)

powershell.exe -ExecutionPolicy Bypass -File "%~dp0FileOrganizerAI.ps1" -Path "%targetPath%" -Model "%modelName%"

pause
