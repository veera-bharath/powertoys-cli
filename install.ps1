<#
.SYNOPSIS
    Installs pt to a PATH-accessible location.
    Re-running is safe: scripts are skipped if already at the current version,
    updated if the version changed, and added if new.

.PARAMETER InstallPath
    Where to install. Default: C:\Tools\PowerToys
#>

param (
    [string]$InstallPath = "C:\Tools\PowerToys"
)

$repoRoot   = $PSScriptRoot
$scriptsDir = Join-Path $repoRoot "scripts"
$libDir     = Join-Path $scriptsDir "lib"
$srcCfg     = Join-Path $scriptsDir "commands.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Rule  { Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }
function Write-Section ([string]$Title) {
    Write-Blank ; Write-Host "  $Title" -ForegroundColor White ; Write-Rule
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Blank
Write-Host "  pt Installer" -ForegroundColor Cyan
Write-Host "  Install to : $InstallPath" -ForegroundColor DarkGray
Write-Rule

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if (-not (Test-Path $srcCfg)) {
    Write-Host "  ERROR: scripts\commands.json not found. Run from the repo root." -ForegroundColor Red
    exit 1
}

$srcJson = Get-Content $srcCfg -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Create directories
# ---------------------------------------------------------------------------

foreach ($dir in @($InstallPath, (Join-Path $InstallPath "lib"))) {
    if (-not (Test-Path $dir)) {
        New-Item $dir -ItemType Directory -Force | Out-Null
        Write-Host "  Created : $dir" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Copy pt.ps1 and pt.bat (always overwrite -- they are the launcher)
# ---------------------------------------------------------------------------

Write-Section "LAUNCHER"

Copy-Item (Join-Path $scriptsDir "pt.ps1") (Join-Path $InstallPath "pt.ps1") -Force
Write-Host "  Copied : pt.ps1" -ForegroundColor Green

Copy-Item (Join-Path $scriptsDir "pt.bat") (Join-Path $InstallPath "pt.bat") -Force
Write-Host "  Copied : pt.bat" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Copy lib scripts -- skip / update / add based on version
# ---------------------------------------------------------------------------

Write-Section "SCRIPTS"

# Load installed commands.json if it exists (for version comparison)
$installedJson = $null
$destCfg = Join-Path $InstallPath "commands.json"
if (Test-Path $destCfg) {
    try { $installedJson = Get-Content $destCfg -Raw | ConvertFrom-Json } catch {}
}

foreach ($cmd in $srcJson.commands) {
    $srcScript  = Join-Path $libDir     ([System.IO.Path]::GetFileName($cmd.script))
    $destScript = Join-Path $InstallPath ($cmd.script -replace '/', '\')

    if (-not (Test-Path $srcScript)) {
        Write-Host ("  SKIP  {0,-28} source not found" -f $cmd.name) -ForegroundColor Yellow
        continue
    }

    if (Test-Path $destScript) {
        $installedCmd = $installedJson.commands | Where-Object { $_.name -eq $cmd.name }
        if ($installedCmd -and $installedCmd.version -eq $cmd.version) {
            Write-Host ("  ok    {0,-28} v{1} (up to date)" -f $cmd.name, $cmd.version) -ForegroundColor DarkGray
            continue
        }
        $oldVer = if ($installedCmd) { $installedCmd.version } else { "?" }
        Write-Host ("  UPDATE {0,-27} v{1} -> v{2}" -f $cmd.name, $oldVer, $cmd.version) -ForegroundColor Cyan
    } else {
        Write-Host ("  ADD   {0,-28} v{1}" -f $cmd.name, $cmd.version) -ForegroundColor Green
    }

    Copy-Item $srcScript $destScript -Force
}

# Write commands.json last so it only reflects what was actually copied
Copy-Item $srcCfg $destCfg -Force
Write-Host ""
Write-Host "  Written: commands.json" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Add to user PATH
# ---------------------------------------------------------------------------

Write-Section "PATH"

$userPath  = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathParts = $userPath -split ";" | ForEach-Object { $_.TrimEnd("\") }

if ($pathParts -icontains $InstallPath.TrimEnd("\")) {
    Write-Host "  Already on PATH: $InstallPath" -ForegroundColor DarkGray
} else {
    [Environment]::SetEnvironmentVariable("PATH", "$userPath;$InstallPath", "User")
    Write-Host "  Added to PATH: $InstallPath" -ForegroundColor Cyan
    Write-Host "  Open a new terminal for PATH changes to take effect." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Section "DONE"
Write-Host "  pt v$($srcJson.version) installed at $InstallPath" -ForegroundColor White
Write-Blank
Write-Host "    pt help" -ForegroundColor Cyan
Write-Host "    pt list" -ForegroundColor Cyan
Write-Blank
Write-Rule
Write-Blank
