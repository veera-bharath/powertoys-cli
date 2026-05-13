@echo off
set "defaultPath=C:\Tools\PowerToys"
set /p installPath="Install path (Enter for %defaultPath%): "
if "%installPath%"=="" set "installPath=%defaultPath%"
powershell.exe -ExecutionPolicy Bypass -File "%~dp0install.ps1" -InstallPath "%installPath%"
pause
