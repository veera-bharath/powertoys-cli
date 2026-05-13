<#
.SYNOPSIS
    Disk cleaner and analyzer. Categorizes files, finds duplicates and large files,
    and lets you delete or organize them interactively.

.PARAMETER Path
    Directory to analyze. Defaults to the current working directory.
#>

param (
    [string]$Path = (Get-Location).Path
)

Add-Type -AssemblyName Microsoft.VisualBasic   # for Recycle Bin support

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$PAGE_SIZE = 18

$CAT_MAP = @{
    '.mp4'=  'Videos';  '.mkv'=  'Videos';  '.avi'=  'Videos';  '.mov'=  'Videos'
    '.wmv'=  'Videos';  '.flv'=  'Videos';  '.webm'= 'Videos';  '.m4v'=  'Videos'
    '.mp3'=  'Audio';   '.wav'=  'Audio';   '.flac'= 'Audio';   '.aac'=  'Audio'
    '.ogg'=  'Audio';   '.wma'=  'Audio';   '.m4a'=  'Audio'
    '.jpg'=  'Images';  '.jpeg'= 'Images';  '.png'=  'Images';  '.gif'=  'Images'
    '.bmp'=  'Images';  '.webp'= 'Images';  '.svg'=  'Images';  '.ico'=  'Images'
    '.tif'=  'Images';  '.tiff'= 'Images';  '.raw'=  'Images';  '.heic'= 'Images'
    '.pdf'=  'Documents'; '.doc'= 'Documents'; '.docx'= 'Documents'
    '.xls'=  'Documents'; '.xlsx'='Documents'; '.ppt'= 'Documents'
    '.pptx'= 'Documents'; '.txt'= 'Documents'; '.csv'= 'Documents'
    '.zip'=  'Archives'; '.rar'= 'Archives'; '.7z'=  'Archives'; '.tar'= 'Archives'
    '.gz'=   'Archives'; '.bz2'= 'Archives'; '.xz'=  'Archives'; '.iso'= 'Archives'
    '.ps1'=  'Code'; '.py'= 'Code'; '.js'= 'Code'; '.ts'= 'Code'; '.html'= 'Code'
    '.css'=  'Code'; '.json'='Code'; '.xml'='Code'; '.cs'='Code'; '.cpp'='Code'
    '.java'= 'Code'; '.go'='Code';  '.rs'='Code';  '.sh'='Code'; '.bat'='Code'
    '.yaml'= 'Code'; '.yml'='Code'; '.toml'='Code'; '.ini'='Code'; '.md'='Code'
    '.exe'=  'Executables'; '.msi'='Executables'; '.dll'='Executables'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:F1} GB" -f ($bytes / 1GB)).PadLeft(9) }
    if ($bytes -ge 1MB) { return ("{0:F1} MB" -f ($bytes / 1MB)).PadLeft(9) }
    if ($bytes -ge 1KB) { return ("{0:F1} KB" -f ($bytes / 1KB)).PadLeft(9) }
    return ("{0} B"    -f $bytes).PadLeft(9)
}

function Get-Category($ext) {
    $e = $ext.ToLower()
    if ($CAT_MAP.ContainsKey($e)) { return $CAT_MAP[$e] }
    return 'Others'
}

function Show-Header($subtitle) {
    Clear-Host
    $W    = [Console]::WindowWidth - 1
    $line = " DiskCleaner  $Path"
    if ($subtitle) { $line += "  >  $subtitle" }
    if ($line.Length -gt $W) { $line = $line.Substring(0, $W) }
    Write-Host $line.PadRight($W) -ForegroundColor Black -BackgroundColor DarkCyan
    Write-Host ("-" * $W) -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Footer($hint) {
    $W = [Console]::WindowWidth - 1
    Write-Host ""
    Write-Host ("-" * $W) -ForegroundColor DarkGray
    Write-Host "  $hint" -ForegroundColor DarkGray
}

function Send-ToRecycleBin($fullPath) {
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $fullPath,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        return $true
    } catch {
        Write-Host "  Error: $_" -ForegroundColor Red
        return $false
    }
}

function Open-InExplorer($fullPath) {
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        Start-Process explorer.exe "/select,`"$fullPath`""
    } elseif (Test-Path -LiteralPath $fullPath -PathType Container) {
        Start-Process explorer.exe "`"$fullPath`""
    }
}

function Pause-ForKey($msg) {
    if (-not $msg) { $msg = "Press any key to continue..." }
    Write-Host "  $msg" -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

$script:AllFiles   = @()
$script:ByCategory = @{}
$script:Duplicates = @()
$script:LargeFiles = @()
$script:TotalSize  = [long]0
$script:TotalCount = 0

function Invoke-Scan {
    Show-Header "Scanning"
    Write-Host "  Collecting files..." -ForegroundColor Cyan

    $all = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $script:AllFiles   = $all
    $script:TotalCount = $all.Count
    $sz = ($all | Measure-Object -Property Length -Sum).Sum
    $script:TotalSize  = if ($null -eq $sz) { [long]0 } else { [long]$sz }

    # -- Categorize --
    Write-Host "  Categorizing by file type..." -ForegroundColor Cyan
    $script:ByCategory = @{}
    $all | Group-Object { Get-Category $_.Extension } | ForEach-Object {
        $catSz = ($_.Group | Measure-Object -Property Length -Sum).Sum
        $script:ByCategory[$_.Name] = [PSCustomObject]@{
            Name  = $_.Name
            Files = [System.Collections.Generic.List[object]] ($_.Group | Sort-Object Length -Descending)
            Count = $_.Count
            Size  = if ($null -eq $catSz) { [long]0 } else { [long]$catSz }
        }
    }

    # -- Large files --
    Write-Host "  Finding large files..." -ForegroundColor Cyan
    $script:LargeFiles = [System.Collections.Generic.List[object]] (
        $all | Sort-Object Length -Descending | Select-Object -First 20
    )

    # -- Duplicates --
    Write-Host "  Detecting duplicates (hashing files with matching sizes)..." -ForegroundColor Cyan
    $script:Duplicates = Find-Duplicates $all
}

function Find-Duplicates($files) {
    $groups = [System.Collections.Generic.List[object]]::new()

    $candidates = $files |
        Where-Object { $_.Length -gt 0 } |
        Group-Object Length |
        Where-Object { $_.Count -gt 1 }

    $total = $candidates.Count
    $done  = 0

    foreach ($szGroup in $candidates) {
        $done++
        Write-Host "`r  Hashing... $done / $total size groups" -NoNewline -ForegroundColor Cyan

        $byHash = @{}
        foreach ($f in $szGroup.Group) {
            try {
                $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch { continue }
            if (-not $byHash.ContainsKey($hash)) {
                $byHash[$hash] = [System.Collections.Generic.List[object]]::new()
            }
            $byHash[$hash].Add($f)
        }

        foreach ($h in $byHash.Keys) {
            if ($byHash[$h].Count -gt 1) {
                $groups.Add($byHash[$h])
            }
        }
    }

    Write-Host ""
    return $groups
}

# ---------------------------------------------------------------------------
# File list view  (shared by Types and Large Files)
# ---------------------------------------------------------------------------

function Show-FileList($title, [System.Collections.Generic.List[object]]$files) {
    $page = 0

    while ($true) {
        $count = $files.Count
        $pages = [Math]::Max(1, [Math]::Ceiling($count / $PAGE_SIZE))
        $start = $page * $PAGE_SIZE
        $end   = [Math]::Min($start + $PAGE_SIZE, $count) - 1

        Show-Header $title
        Write-Host ("  {0,-4}  {1,-42}  {2}  {3}" -f "#", "Name", "     Size", "Relative path") -ForegroundColor White
        Write-Host ("  " + "-" * 78) -ForegroundColor DarkGray

        for ($i = $start; $i -le $end; $i++) {
            $f    = $files[$i]
            $name = $f.Name
            if ($name.Length -gt 40) { $name = $name.Substring(0, 39) + "~" }
            $sz   = Format-Size $f.Length
            $rel  = $f.FullName
            if ($rel.StartsWith($Path)) { $rel = "." + $rel.Substring($Path.Length) }
            if ($rel.Length -gt 36) { $rel = "..." + $rel.Substring($rel.Length - 33) }

            Write-Host ("  {0,-4}  {1,-42}  {2}  {3}" -f ($i + 1), $name, $sz, $rel) -ForegroundColor Gray
        }

        Show-Footer "#:recycle  O <#>:open in Explorer  N:next page  P:prev page  B:back"
        Write-Host ("  Page {0}/{1}   {2} files total" -f ($page + 1), $pages, $count) -ForegroundColor DarkGray
        Write-Host ""
        $choice = (Read-Host "  Choice").Trim()

        if ($choice -eq 'B' -or $choice -eq 'b') { return }

        if ($choice -eq 'N' -or $choice -eq 'n') {
            if ($page -lt $pages - 1) { $page++ }
            continue
        }
        if ($choice -eq 'P' -or $choice -eq 'p') {
            if ($page -gt 0) { $page-- }
            continue
        }

        # Open in Explorer: O <number>
        if ($choice -match '^[Oo]\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -ge 0 -and $idx -lt $count) {
                Open-InExplorer $files[$idx].FullName
            }
            continue
        }

        # Delete by number
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $count) {
                $f = $files[$idx]
                Write-Host ""
                Write-Host "  Send to Recycle Bin: $($f.FullName)" -ForegroundColor Yellow
                Write-Host "  Size: $(Format-Size $f.Length)" -ForegroundColor Yellow
                $ans = (Read-Host "  Confirm? [Y/N]").Trim()
                if ($ans -eq 'Y' -or $ans -eq 'y') {
                    if (Send-ToRecycleBin $f.FullName) {
                        Write-Host "  Sent to Recycle Bin." -ForegroundColor Green
                        $files.RemoveAt($idx)
                        $count = $files.Count
                        if ($start -ge $count -and $page -gt 0) { $page-- }
                    }
                }
                Pause-ForKey
            }
            continue
        }
    }
}

# ---------------------------------------------------------------------------
# File Types menu
# ---------------------------------------------------------------------------

function Show-TypesMenu {
    while ($true) {
        $cats = $script:ByCategory.Values | Sort-Object Size -Descending
        Show-Header "File Types"

        $i = 1
        foreach ($cat in $cats) {
            $bar   = "#" * [Math]::Min(30, [int]($cat.Size / [Math]::Max(1, $script:TotalSize) * 30))
            $pct   = "{0:F1}%" -f ($cat.Size / [Math]::Max(1, $script:TotalSize) * 100)
            Write-Host ("  {0,-3}  {1,-14}  {2}  {3,-7}  {4,-5}  {5} files" -f `
                $i, $cat.Name, (Format-Size $cat.Size), $pct, "", $cat.Count) -ForegroundColor Yellow
            Write-Host ("       [{0,-30}]" -f $bar) -ForegroundColor DarkGreen
            $i++
        }

        Show-Footer "#:view files in category  B:back"
        Write-Host ""
        $choice = (Read-Host "  Choice").Trim()

        if ($choice -eq 'B' -or $choice -eq 'b') { return }

        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            $cat = @($cats)[$idx]
            if ($null -ne $cat) {
                Show-FileList "File Types > $($cat.Name)" $cat.Files
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Duplicates menu
# ---------------------------------------------------------------------------

function Show-DuplicatesMenu {
    while ($true) {
        $groups = $script:Duplicates
        Show-Header "Duplicate Files"

        if ($groups.Count -eq 0) {
            Write-Host "  No duplicate files found." -ForegroundColor Green
            Show-Footer "B:back"
            Write-Host ""
            $null = Read-Host "  Choice"
            return
        }

        $totalWaste = [long]0
        for ($g = 0; $g -lt $groups.Count; $g++) {
            $grp    = $groups[$g]
            $copies = $grp.Count - 1
            $waste  = $grp[0].Length * $copies
            $totalWaste += $waste
            Write-Host ("  {0,-3}  {1} copies   waste {2}   sample: {3}" -f `
                ($g + 1), $grp.Count, (Format-Size $waste).Trim(), $grp[0].Name) -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host ("  Total reclaimable: {0}  across {1} groups" -f `
            (Format-Size $totalWaste).Trim(), $groups.Count) -ForegroundColor Cyan

        Show-Footer "#:inspect group  D <#>:keep newest, delete rest  B:back"
        Write-Host ""
        $choice = (Read-Host "  Choice").Trim()

        if ($choice -eq 'B' -or $choice -eq 'b') { return }

        # Keep newest, delete rest
        if ($choice -match '^[Dd]\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -ge 0 -and $idx -lt $groups.Count) {
                $grp     = $groups[$idx]
                $newest  = $grp | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $toDelete = $grp | Where-Object { $_.FullName -ne $newest.FullName }

                Write-Host ""
                Write-Host "  Keeping (newest): $($newest.FullName)" -ForegroundColor Green
                foreach ($f in $toDelete) {
                    Write-Host "  Recycle: $($f.FullName)" -ForegroundColor Yellow
                }
                $ans = (Read-Host "  Confirm send to Recycle Bin? [Y/N]").Trim()
                if ($ans -eq 'Y' -or $ans -eq 'y') {
                    $ok = $true
                    foreach ($f in $toDelete) {
                        if (-not (Send-ToRecycleBin $f.FullName)) { $ok = $false }
                    }
                    if ($ok) {
                        Write-Host "  Done." -ForegroundColor Green
                        $script:Duplicates = [System.Collections.Generic.List[object]] (
                            $groups | Where-Object { $_ -ne $grp }
                        )
                    }
                }
                Pause-ForKey
            }
            continue
        }

        # Inspect group
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $groups.Count) {
                $grp = $groups[$idx]
                Show-Header "Duplicates > Group $($idx + 1)"
                Write-Host "  Hash match: $($grp.Count) identical files`n" -ForegroundColor Cyan
                for ($f = 0; $f -lt $grp.Count; $f++) {
                    $file = $grp[$f]
                    $age  = $file.LastWriteTime.ToString("yyyy-MM-dd")
                    Write-Host ("  {0}  {1}  modified {2}  {3}" -f `
                        ($f + 1), (Format-Size $file.Length).Trim(), $age, $file.FullName) -ForegroundColor Gray
                }
                Show-Footer "#:recycle that copy  O <#>:open in Explorer  B:back"
                Write-Host ""
                $inner = (Read-Host "  Choice").Trim()

                if ($inner -match '^[Oo]\s+(\d+)$') {
                    $fi = [int]$Matches[1] - 1
                    if ($fi -ge 0 -and $fi -lt $grp.Count) { Open-InExplorer $grp[$fi].FullName }
                } elseif ($inner -match '^\d+$') {
                    $fi = [int]$inner - 1
                    if ($fi -ge 0 -and $fi -lt $grp.Count) {
                        $f = $grp[$fi]
                        Write-Host "  Recycle: $($f.FullName)" -ForegroundColor Yellow
                        $ans = (Read-Host "  Confirm? [Y/N]").Trim()
                        if ($ans -eq 'Y' -or $ans -eq 'y') {
                            if (Send-ToRecycleBin $f.FullName) {
                                Write-Host "  Sent to Recycle Bin." -ForegroundColor Green
                            }
                        }
                        Pause-ForKey
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Organize integration
# ---------------------------------------------------------------------------

function Invoke-Organize {
    Show-Header "Organize with FileOrganizer"

    # Look for FileOrganizer in PATH, then default install location, then sibling folder
    $fo = Get-Command FileOrganizer -ErrorAction SilentlyContinue
    if (-not $fo) {
        $candidates = @(
            "C:\Tools\PowerToys\FileOrganizer.bat",
            (Join-Path (Split-Path $PSScriptRoot -Parent) "FileOrganizer\FileOrganizer.ps1")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $fo = $c; break }
        }
    } else {
        $fo = $fo.Source
    }

    if (-not $fo) {
        Write-Host "  FileOrganizer is not installed." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Install it by running Setup\Setup.bat from the PowerToys repo" -ForegroundColor White
        Write-Host "  and selecting FileOrganizer from the menu." -ForegroundColor White
        Write-Host ""
        Write-Host "  After installing, FileOrganizer will be available as a command" -ForegroundColor DarkGray
        Write-Host "  and DiskCleaner will detect it automatically." -ForegroundColor DarkGray
        Pause-ForKey
        return
    }

    Write-Host "  Found: $fo" -ForegroundColor Green
    Write-Host ""
    Write-Host "  This will organize files in:" -ForegroundColor White
    Write-Host "  $Path" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Run with -WhatIf first to preview (no files will be moved)." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1. Preview (WhatIf)" -ForegroundColor White
    Write-Host "  2. Run for real" -ForegroundColor White
    Write-Host "  B. Back" -ForegroundColor White
    Write-Host ""
    $choice = (Read-Host "  Choice").Trim()

    if ($choice -eq '1') {
        if ($fo -like "*.ps1") {
            powershell.exe -ExecutionPolicy Bypass -File $fo -Path $Path -WhatIf
        } else {
            & $fo -Path $Path -WhatIf
        }
        Pause-ForKey
    } elseif ($choice -eq '2') {
        if ($fo -like "*.ps1") {
            powershell.exe -ExecutionPolicy Bypass -File $fo -Path $Path
        } else {
            & $fo -Path $Path
        }
        Pause-ForKey
    }
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

function Show-MainMenu {
    while ($true) {
        $dupGroups  = $script:Duplicates.Count
        $dupWaste   = [long]0
        foreach ($g in $script:Duplicates) { $dupWaste += $g[0].Length * ($g.Count - 1) }

        Show-Header ""
        Write-Host ("  Analyzed: {0} files   Total size: {1}" -f `
            $script:TotalCount, (Format-Size $script:TotalSize).Trim()) -ForegroundColor Cyan
        Write-Host ""

        # Quick wins
        if ($dupGroups -gt 0) {
            Write-Host ("  [!] {0} duplicate groups found - {1} reclaimable" -f `
                $dupGroups, (Format-Size $dupWaste).Trim()) -ForegroundColor Yellow
        }
        if ($script:LargeFiles.Count -gt 0) {
            $top = $script:LargeFiles[0]
            Write-Host ("  [!] Largest file: {0} ({1})" -f `
                $top.Name, (Format-Size $top.Length).Trim()) -ForegroundColor Yellow
        }
        Write-Host ""

        Write-Host "  1.  File Types        - breakdown by category" -ForegroundColor White
        Write-Host ("  2.  Duplicate Files   - {0} groups, {1} reclaimable" -f `
            $dupGroups, (Format-Size $dupWaste).Trim()) -ForegroundColor White
        Write-Host "  3.  Large Files       - top 20 by size" -ForegroundColor White
        Write-Host "  4.  Organize          - run FileOrganizer on this path" -ForegroundColor White
        Write-Host ""
        Write-Host "  R.  Re-scan" -ForegroundColor DarkGray
        Write-Host "  Q.  Quit" -ForegroundColor DarkGray

        Show-Footer ""
        Write-Host ""
        $choice = (Read-Host "  Choice").Trim()

        switch ($choice.ToUpper()) {
            '1' { Show-TypesMenu }
            '2' { Show-DuplicatesMenu }
            '3' { Show-FileList "Large Files (Top 20)" $script:LargeFiles }
            '4' { Invoke-Organize }
            'R' { Invoke-Scan }
            'Q' { return }
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Not a valid directory: $Path"
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path

Invoke-Scan
Show-MainMenu

Clear-Host
