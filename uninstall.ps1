<#
.SYNOPSIS
    Removes pt from the install path and from user PATH.

.PARAMETER InstallPath
    Where pt was installed. Default: C:\Tools\PowerToys
#>

param (
    [string]$InstallPath = "C:\Tools\PowerToys"
)

function Write-Rule  { Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }
function Write-Section ([string]$Title) {
    Write-Blank ; Write-Host "  $Title" -ForegroundColor White ; Write-Rule
}

Write-Blank
Write-Host "  pt Uninstaller" -ForegroundColor Cyan
Write-Host "  Removing    : $InstallPath" -ForegroundColor DarkGray
Write-Rule

if (-not (Test-Path $InstallPath)) {
    Write-Blank
    Write-Host "  Nothing to remove -- $InstallPath does not exist." -ForegroundColor DarkGray
    Write-Blank
    exit 0
}

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

Write-Blank
Write-Host "  This will delete $InstallPath and remove it from PATH." -ForegroundColor Yellow
$confirm = Read-Host "  Type YES to continue"
if ($confirm -ne "YES") {
    Write-Blank
    Write-Host "  Aborted." -ForegroundColor DarkGray
    Write-Blank
    exit 0
}

# ---------------------------------------------------------------------------
# Remove from PATH
# ---------------------------------------------------------------------------

Write-Section "PATH"

$userPath  = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathParts = $userPath -split ";" | Where-Object { $_.TrimEnd("\") -ine $InstallPath.TrimEnd("\") }
[Environment]::SetEnvironmentVariable("PATH", ($pathParts -join ";"), "User")
Write-Host "  Removed from PATH: $InstallPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Delete install directory
# ---------------------------------------------------------------------------

Write-Section "FILES"

Remove-Item $InstallPath -Recurse -Force
Write-Host "  Deleted: $InstallPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Section "DONE"
Write-Host "  pt has been uninstalled." -ForegroundColor White
Write-Host "  Open a new terminal for PATH changes to take effect." -ForegroundColor DarkGray
Write-Blank
Write-Rule
Write-Blank
