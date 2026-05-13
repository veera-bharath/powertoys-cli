@echo off
set "defaultPath=C:\Tools\PowerToys"
set /p installPath="Install path to remove (Enter for %defaultPath%): "
if "%installPath%"=="" set "installPath=%defaultPath%"
powershell.exe -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -InstallPath "%installPath%"
pause
