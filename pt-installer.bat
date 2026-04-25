@echo off
:: Bootstraps pt-setup by copying it to a PATH-accessible location.
:: Run this once from the repository root.

set "defaultPath=C:\Tools\PowerToys"
set /p installPath="Install path (press Enter for %defaultPath%): "
if "%installPath%"=="" set "installPath=%defaultPath%"

powershell.exe -ExecutionPolicy Bypass -File "%~dp0Setup\pt-installer.ps1" -InstallPath "%installPath%"
pause
