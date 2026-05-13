<#
.SYNOPSIS
    Organizes files in a directory into categorized folders based on their extensions.

.DESCRIPTION
    Maps common file extensions to categories (Images, Videos, Documents, etc.).
    Handles filename collisions by appending a numeric suffix instead of overwriting.
    Skips the script and any .bat launchers in its own folder.

.PARAMETER Path
    The directory to organize. Defaults to the current working directory.

.PARAMETER WhatIf
    Preview what would be moved without making any changes.
#>

param (
    [string]$Path = (Get-Location).Path,
    [switch]$WhatIf
)

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Rule  { Write-Host ("  " + ("-" * 52)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }

function Write-Section ([string]$Title) {
    Write-Blank
    Write-Host "  $Title" -ForegroundColor White
    Write-Rule
}

# ── Validation ────────────────────────────────────────────────────────────────

if (-not (Test-Path -Path $Path -PathType Container)) {
    Write-Error "Path does not exist or is not a directory: $Path"
    return
}

# ── Extension Map ─────────────────────────────────────────────────────────────

$ExtensionMap = @{
    # Images
    ".jpg"  = "Images"; ".jpeg" = "Images"; ".png"  = "Images"; ".gif"  = "Images"
    ".bmp"  = "Images"; ".webp" = "Images"; ".svg"  = "Images"; ".avif" = "Images"
    ".heic" = "Images"; ".tiff" = "Images"; ".tif"  = "Images"; ".ico"  = "Images"

    # Videos
    ".mp4"  = "Videos"; ".mkv"  = "Videos"; ".flv"  = "Videos"; ".wmv"  = "Videos"
    ".avi"  = "Videos"; ".mov"  = "Videos"; ".webm" = "Videos"; ".m4v"  = "Videos"

    # Music
    ".mp3"  = "Music"; ".wav"  = "Music"; ".wma"  = "Music"; ".aac"  = "Music"
    ".flac" = "Music"; ".m4a"  = "Music"; ".ogg"  = "Music"

    # Apps
    ".exe"  = "Apps"; ".msi"  = "Apps"; ".msix" = "Apps"; ".bat"  = "Apps"

    # Archives
    ".zip"  = "Archives"; ".rar" = "Archives"; ".7z"  = "Archives"
    ".tar"  = "Archives"; ".gz"  = "Archives"; ".bz2" = "Archives"; ".xz" = "Archives"

    # Documents
    ".pdf"  = "Documents\PDF"
    ".doc"  = "Documents\Word";        ".docx" = "Documents\Word"; ".rtf" = "Documents\Word"
    ".xls"  = "Documents\Excel";       ".xlsx" = "Documents\Excel"; ".csv" = "Documents\Excel"
    ".ppt"  = "Documents\PowerPoint";  ".pptx" = "Documents\PowerPoint"
    ".txt"  = "Documents\Text";        ".md"   = "Documents\Text"; ".log" = "Documents\Text"
    ".eml"  = "Documents\Email"
}

# ── Self-exclusion ────────────────────────────────────────────────────────────

$selfFiles = @($PSCommandPath) + (
    Get-ChildItem -Path $PSScriptRoot -File -Filter "*.bat" |
        ForEach-Object { $_.FullName }
)

# ── Tracking ──────────────────────────────────────────────────────────────────

$moved   = [System.Collections.Generic.List[PSObject]]::new()   # {Name, Category, Renamed}
$failed  = [System.Collections.Generic.List[PSObject]]::new()   # {Name, Category, Reason}
$skipped = [System.Collections.Generic.List[string]]::new()     # Name only

# ── Header ────────────────────────────────────────────────────────────────────

Write-Blank
Write-Host "  File Organizer" -ForegroundColor Cyan
Write-Host "  Path : $Path" -ForegroundColor DarkGray
if ($WhatIf) { Write-Host "  Mode : DRY RUN - no files will be moved" -ForegroundColor Yellow }
Write-Rule

# ── Process Files ─────────────────────────────────────────────────────────────

foreach ($file in Get-ChildItem -Path $Path -File) {
    if ($selfFiles -contains $file.FullName) { continue }

    $ext = $file.Extension.ToLower()

    # No mapping → skipped
    if (-not $ExtensionMap.ContainsKey($ext)) {
        Write-Host "  -  " -ForegroundColor DarkGray -NoNewline
        Write-Host $file.Name -ForegroundColor DarkGray -NoNewline
        Write-Host "  (no mapping)" -ForegroundColor DarkGray
        $skipped.Add($file.Name)
        continue
    }

    $category = $ExtensionMap[$ext]
    $destDir  = Join-Path $Path $category
    $newName  = $file.Name
    $destFile = Join-Path $destDir $newName
    $renamed  = $false

    # Collision → append _2, _3, …
    if (Test-Path $destFile) {
        $base    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $counter = 2
        do {
            $newName  = "${base}_${counter}${ext}"
            $destFile = Join-Path $destDir $newName
            $counter++
        } while (Test-Path $destFile)
        $renamed = $true
    }

    # Dry-run — just log
    if ($WhatIf) {
        Write-Host "  o  " -ForegroundColor Cyan -NoNewline
        Write-Host "$($file.Name)  " -NoNewline
        Write-Host "->  $category" -ForegroundColor DarkCyan -NoNewline
        if ($renamed) { Write-Host "  (would rename: $newName)" -ForegroundColor DarkYellow } else { Write-Host "" }
        $moved.Add([PSCustomObject]@{ Name = $file.Name; Category = $category; Renamed = $renamed })
        continue
    }

    New-Item -Path $destDir -ItemType Directory -Force | Out-Null

    try {
        Move-Item -Path $file.FullName -Destination $destFile -ErrorAction Stop
        Write-Host "  +  " -ForegroundColor Green -NoNewline
        Write-Host "$($file.Name)  " -NoNewline
        Write-Host "->  $category" -ForegroundColor DarkGreen -NoNewline
        if ($renamed) { Write-Host "  (renamed: $newName)" -ForegroundColor DarkYellow } else { Write-Host "" }
        $moved.Add([PSCustomObject]@{ Name = $file.Name; Category = $category; Renamed = $renamed })
    } catch {
        Write-Host "  x  " -ForegroundColor Red -NoNewline
        Write-Host "$($file.Name)  " -NoNewline
        Write-Host "->  $category  " -ForegroundColor DarkGray -NoNewline
        Write-Host "($($_.Exception.Message))" -ForegroundColor DarkRed
        $failed.Add([PSCustomObject]@{ Name = $file.Name; Category = $category; Reason = $_.Exception.Message })
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

$totalFound = $moved.Count + $failed.Count + $skipped.Count

Write-Section "SUMMARY"

$verb = if ($WhatIf) { "To move" } else { "Moved  " }
Write-Host "  Total found    $totalFound" -ForegroundColor White
Write-Host "  $verb      $($moved.Count)" -ForegroundColor $(if ($moved.Count  -gt 0) { "Green"  } else { "DarkGray" })
Write-Host "  Failed         $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { "Red"    } else { "DarkGray" })
Write-Host "  Skipped        $($skipped.Count)" -ForegroundColor $(if ($skipped.Count -gt 0) { "Yellow" } else { "DarkGray" })

# BY CATEGORY
if ($moved.Count -gt 0) {
    Write-Section "BY CATEGORY"
    $moved |
        Group-Object Category |
        Sort-Object Name |
        ForEach-Object {
            $label    = $_.Name.PadRight(26)
            $count    = $_.Count
            $renames  = ($_.Group | Where-Object { $_.Renamed }).Count
            $suffix   = if ($renames -gt 0) { "  ($renames renamed)" } else { "" }
            Write-Host "  $label  $count file$(if ($count -ne 1){'s'})$suffix" -ForegroundColor DarkCyan
        }
}

# FAILED
if ($failed.Count -gt 0) {
    Write-Section "FAILED"
    foreach ($f in $failed) {
        Write-Host "  $($f.Name.PadRight(30))" -ForegroundColor Red -NoNewline
        Write-Host $f.Reason -ForegroundColor DarkRed
    }
}

# SKIPPED
if ($skipped.Count -gt 0) {
    Write-Section "SKIPPED  (no extension mapping)"
    $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

Write-Blank
Write-Rule
Write-Host "  Done." -ForegroundColor Cyan
Write-Blank
