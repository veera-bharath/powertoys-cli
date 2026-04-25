<#
.SYNOPSIS
    Bootstraps pt-setup by copying it to a PATH-accessible install location.

.PARAMETER InstallPath
    Where to install pt-setup. Passed from pt-installer.bat.
#>

param (
    [string]$InstallPath = "C:\Tools\PowerToys"
)

$setupDir   = $PSScriptRoot
$repoRoot   = Split-Path $PSScriptRoot
$configFile = Join-Path $setupDir "scripts.json"

# -- Helpers ------------------------------------------------------------------

function Write-Rule  { Write-Host ("  " + ("-" * 52)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }
function Write-Section ([string]$Title) {
    Write-Blank
    Write-Host "  $Title" -ForegroundColor White
    Write-Rule
}

# -- Header -------------------------------------------------------------------

Write-Blank
Write-Host "  PowerToys Installer" -ForegroundColor Cyan
Write-Host "  Repo       : $repoRoot" -ForegroundColor DarkGray
Write-Host "  Install to : $InstallPath" -ForegroundColor DarkGray
Write-Rule

# -- Bake repoRoot + installPath into scripts.json ---------------------------

$config             = Get-Content $configFile -Raw | ConvertFrom-Json
$config.repoRoot    = $repoRoot
$config.installPath = $InstallPath
$config | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8

# -- Create install folder ----------------------------------------------------

if (-not (Test-Path $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    Write-Host "  Created : $InstallPath" -ForegroundColor Gray
}

# -- Copy setup files ---------------------------------------------------------

Write-Section "INSTALLING PT-SETUP"

$filesToCopy = @("pt-setup.ps1", "pt-setup.bat", "scripts.json")
$allOk = $true

foreach ($f in $filesToCopy) {
    $src  = Join-Path $setupDir $f
    $dest = Join-Path $InstallPath $f
    if (Test-Path $src) {
        Copy-Item $src $dest -Force
        Write-Host "  Copied : $f" -ForegroundColor Green
    } else {
        Write-Host "  MISSING: $f - not found at $src" -ForegroundColor Red
        $allOk = $false
    }
}

if (-not $allOk) {
    Write-Blank
    Write-Host "  Some files could not be copied. Check errors above." -ForegroundColor Red
    Write-Blank
    exit 1
}

# -- Add install folder to user PATH ------------------------------------------

Write-Section "ENVIRONMENT"

$userPath  = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathParts = $userPath -split ";" | ForEach-Object { $_.TrimEnd("\") }

if ($pathParts -icontains $InstallPath.TrimEnd("\")) {
    Write-Host "  PATH already contains: $InstallPath" -ForegroundColor DarkGray
} else {
    [Environment]::SetEnvironmentVariable("PATH", "$userPath;$InstallPath", "User")
    Write-Host "  Added to user PATH: $InstallPath" -ForegroundColor Cyan
    Write-Host "  Restart your terminal for PATH changes to take effect." -ForegroundColor Yellow
}

# -- Done ---------------------------------------------------------------------

Write-Section "DONE"
Write-Host "  pt-setup is installed at: $InstallPath" -ForegroundColor White
Write-Blank
Write-Host "  Open a new terminal and run:" -ForegroundColor White
Write-Host "    pt-setup" -ForegroundColor Cyan
Write-Host "  to install your scripts." -ForegroundColor White
Write-Blank
Write-Rule
Write-Blank
