<#
.SYNOPSIS
    Installs PowerToys utility scripts to the configured PATH location.
    Run pt-installer.bat once first to set this up.
#>

# -- Load config --------------------------------------------------------------

$configFile = Join-Path $PSScriptRoot "scripts.json"

if (-not (Test-Path $configFile)) {
    Write-Host "  ERROR: scripts.json not found at $configFile" -ForegroundColor Red
    exit 1
}

$config      = Get-Content $configFile -Raw | ConvertFrom-Json
$scripts     = @($config.scripts)
$InstallPath = $config.installPath
$repoRoot    = $config.repoRoot

if ([string]::IsNullOrWhiteSpace($repoRoot) -or -not (Test-Path $repoRoot)) {
    Write-Host ""
    Write-Host "  ERROR: Repository root not found: $repoRoot" -ForegroundColor Red
    Write-Host "  Run pt-installer.bat from the PowerToys repository to fix this." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

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
Write-Host "  PowerToys Setup" -ForegroundColor Cyan
Write-Host "  Install path : $InstallPath" -ForegroundColor DarkGray
Write-Host "  Repo         : $repoRoot" -ForegroundColor DarkGray
Write-Rule

# -- Detect installed vs not-installed ----------------------------------------

$installed    = [System.Collections.Generic.List[PSObject]]::new()
$notInstalled = [System.Collections.Generic.List[PSObject]]::new()

foreach ($s in $scripts) {
    if (Test-Path (Join-Path $InstallPath "$($s.id).ps1")) {
        $installed.Add($s)
    } else {
        $notInstalled.Add($s)
    }
}

# -- Show already-installed ---------------------------------------------------

if ($installed.Count -gt 0) {
    Write-Section "ALREADY INSTALLED"
    foreach ($s in $installed) {
        Write-Host "  [ok]  $($s.displayName.PadRight(34)) $($s.description)" -ForegroundColor DarkGray
    }
}

if ($notInstalled.Count -eq 0) {
    Write-Blank
    Write-Host "  All scripts are already installed at $InstallPath" -ForegroundColor Green
    Write-Blank
    Write-Rule
    exit
}

# -- Let user choose ----------------------------------------------------------

Write-Section "SELECT SCRIPTS TO INSTALL"

$i = 1
foreach ($s in $notInstalled) {
    Write-Host "  [$i]  $($s.displayName.PadRight(34)) $($s.description)"
    $i++
}
Write-Host "  [A]  All"
Write-Blank

$choice    = Read-Host "  Enter numbers separated by commas (e.g. 1,2) or A for all"
$toInstall = [System.Collections.Generic.List[PSObject]]::new()

if ($choice -match "^[Aa]$") {
    foreach ($s in $notInstalled) { $toInstall.Add($s) }
} else {
    foreach ($idx in ($choice -split "," | ForEach-Object { $_.Trim() })) {
        if ($idx -match "^\d+$") {
            $num = [int]$idx - 1
            if ($num -ge 0 -and $num -lt $notInstalled.Count) {
                $toInstall.Add($notInstalled[$num])
            }
        }
    }
}

if ($toInstall.Count -eq 0) {
    Write-Blank
    Write-Host "  No valid selection. Exiting." -ForegroundColor Yellow
    Write-Blank
    exit
}

# -- Create install folder ----------------------------------------------------

if (-not (Test-Path $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    Write-Host "  Created folder: $InstallPath" -ForegroundColor Gray
}

# -- Copy PS1 + generate BAT wrapper ------------------------------------------

Write-Section "INSTALLING"

foreach ($s in $toInstall) {
    $sourcePs1 = Join-Path $repoRoot $s.source
    $destPs1   = Join-Path $InstallPath "$($s.id).ps1"
    $destBat   = Join-Path $InstallPath "$($s.id).bat"

    if (-not (Test-Path $sourcePs1)) {
        Write-Host "  SKIP : $($s.id) - source not found: $sourcePs1" -ForegroundColor Yellow
        continue
    }

    Copy-Item -Path $sourcePs1 -Destination $destPs1 -Force
    Write-Host "  Copied : $($s.id).ps1" -ForegroundColor Green

    @"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0$($s.id).ps1" %*
"@ | Set-Content -Path $destBat -Encoding ASCII
    Write-Host "  Created: $($s.id).bat" -ForegroundColor Green
}

# -- Done ---------------------------------------------------------------------

Write-Section "DONE"
Write-Host "  You can now run these commands from any terminal:" -ForegroundColor White
Write-Blank
foreach ($s in $toInstall) {
    Write-Host "    $($s.usage)" -ForegroundColor Cyan
}
Write-Blank
Write-Rule
Write-Blank
