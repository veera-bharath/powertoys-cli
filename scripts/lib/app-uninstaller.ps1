<#
.SYNOPSIS
    Interactive app uninstaller with full keyboard navigation.
    Up/Down: move  Left/Right: page  Space: select  Ctrl+U: uninstall  Ctrl+R: refresh
    F: filter  C: clear filter  S: cycle sort  Q: quit

.PARAMETER IncludeStore
    Also list Microsoft Store (AppX) packages.
#>

param ([switch]$IncludeStore)

# ---------------------------------------------------------------------------
# Auto-elevate to admin -- required to delete HKLM registry keys and uninstall
# system-wide apps (files in Program Files, MSI database, etc.)
# ---------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $relaunchArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($IncludeStore) { $relaunchArgs += " -IncludeStore" }
    Start-Process powershell.exe -ArgumentList $relaunchArgs -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# Layout constants  (all ASCII -- no Unicode/emoji in .ps1)
# ---------------------------------------------------------------------------

$PAGE_SIZE = 18

# Column widths (content only, excluding separators)
$C_SEL  = 3    # [*] or [ ]
$C_NUM  = 4    # [18]
$C_NAME = 28
$C_PUB  = 17
$C_VER  = 11
$C_DATE = 10   # yyyy-MM-dd
$C_SIZE = 9    # 999.9 MB
$C_TYPE = 5    # [MSI]
$C_LAST = 10   # 12d ago

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:AllApps      = @()
$script:Filtered     = @()
$script:SortMode     = 'Name'   # Name | Size | Date | Publisher | Usage
$script:FilterText   = ''
$script:SelKeys      = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:Cursor       = 0
$script:PrefetchMap  = @{}
$script:FirstRender  = $true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:F1} GB" -f ($bytes / 1GB)).PadLeft($C_SIZE) }
    if ($bytes -ge 1MB) { return ("{0:F1} MB" -f ($bytes / 1MB)).PadLeft($C_SIZE) }
    if ($bytes -ge 1KB) { return ("{0:F1} KB" -f ($bytes / 1KB)).PadLeft($C_SIZE) }
    return ("{0} B" -f $bytes).PadLeft($C_SIZE)
}

function Format-LastUsed($dt) {
    if ($null -eq $dt) { return "-".PadRight($C_LAST) }
    $age = (Get-Date) - $dt
    if ($age.TotalMinutes -lt 60) { $s = "$([int]$age.TotalMinutes)m ago" }
    elseif ($age.TotalHours  -lt 24)  { $s = "$([int]$age.TotalHours)h ago" }
    elseif ($age.TotalDays   -lt 30)  { $s = "$([int]$age.TotalDays)d ago" }
    elseif ($age.TotalDays   -lt 365) { $s = "$([int]($age.TotalDays/30))mo ago" }
    else                              { $s = "$([int]($age.TotalDays/365))yr ago" }
    return $s.PadRight($C_LAST)
}

function Clip([string]$s, [int]$w) {
    if (-not $s) { return "".PadRight($w) }
    if ($s.Length -le $w) { return $s.PadRight($w) }
    return $s.Substring(0, $w - 2) + ".."
}

function Get-AppKey($app) { "$($app.Name)|$($app.Version)|$($app.Publisher)" }

# ---------------------------------------------------------------------------
# Prefetch-based last-used detection
# ---------------------------------------------------------------------------

function Build-PrefetchMap {
    $map = @{}
    try {
        Get-ChildItem "C:\Windows\Prefetch" -Filter "*.pf" -ErrorAction Stop | ForEach-Object {
            if ($_.Name -match '^(.+)-[0-9A-F]{8}\.pf$') {
                $base = $Matches[1].ToLower()
                if (-not $map.ContainsKey($base) -or $_.LastWriteTime -gt $map[$base]) {
                    $map[$base] = $_.LastWriteTime
                }
            }
        }
    } catch {}
    return $map
}

function Get-LastUsed($app) {
    if ($script:PrefetchMap.Count -eq 0) { return $null }

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Exes in install location (skip uninstaller-style names)
    if ($app.InstallLocation -and (Test-Path $app.InstallLocation -ErrorAction SilentlyContinue)) {
        try {
            Get-ChildItem -Path $app.InstallLocation -Filter "*.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'uninstall|setup|install|remove|update|crash|helper|repair' } |
            Select-Object -First 4 |
            ForEach-Object { $candidates.Add($_.BaseName.ToLower()) }
        } catch {}
    }

    # Exe from uninstall string
    if ($app.UninstallString -match '\\([^\\/"]+)\.exe' -and
        $Matches[1] -notmatch 'msiexec|uninstall|setup|install|remove|update') {
        $candidates.Add($Matches[1].ToLower())
    }

    # Simplified app name and first word
    $clean = ($app.Name -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($clean.Length -gt 2) { $candidates.Add($clean) }

    $first = (($app.Name -split '\s+')[0] -replace '[^a-z0-9]', '').ToLower()
    if ($first.Length -gt 3) { $candidates.Add($first) }

    foreach ($c in $candidates) {
        if ($script:PrefetchMap.ContainsKey($c)) { return $script:PrefetchMap[$c] }
        $hit = $script:PrefetchMap.Keys |
               Where-Object { $_.Length -gt 3 -and $c.Length -gt 3 -and ($_ -like "$c*" -or $c -like "$_*") } |
               Select-Object -First 1
        if ($hit) { return $script:PrefetchMap[$hit] }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

function Get-RegistryApps {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $apps = [System.Collections.Generic.List[object]]::new()

    foreach ($regPath in $regPaths) {
        try { $keys = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue } catch { continue }
        foreach ($k in $keys) {
            $name = $k.DisplayName
            if (-not $name -or $name -match '^\s*$') { continue }
            if ($k.SystemComponent -eq 1)             { continue }
            if ($name -match 'KB\d{6,}')              { continue }
            if (-not $k.UninstallString)              { continue }
            if (-not $seen.Add("$name|$($k.DisplayVersion)")) { continue }

            $installDate = $null
            if ($k.InstallDate -match '^\d{8}$') {
                try { $installDate = [datetime]::ParseExact($k.InstallDate, 'yyyyMMdd', $null) } catch {}
            }

            $sizeBytes = if ($k.EstimatedSize) { [long]$k.EstimatedSize * 1024 } else { [long]0 }
            $us        = $k.UninstallString
            $isMsi     = ($us -match 'msiexec') -or ($k.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$')

            $apps.Add([PSCustomObject]@{
                Name            = $name
                Publisher       = if ($k.Publisher) { $k.Publisher } else { '' }
                Version         = if ($k.DisplayVersion) { $k.DisplayVersion } else { '' }
                InstallDate     = $installDate
                SizeBytes       = $sizeBytes
                UninstallString = $us
                InstallLocation = if ($k.InstallLocation) { $k.InstallLocation } else { '' }
                IsMsi           = $isMsi
                IsAppX          = $false
                AppXPackage     = $null
                ProductCode     = if ($k.PSChildName -match '^\{') { $k.PSChildName } else { '' }
                LastUsed        = $null
                RegKeyPath      = $k.PSPath
            })
        }
    }
    return $apps
}

function Get-StoreApps {
    $apps = [System.Collections.Generic.List[object]]::new()
    try {
        Get-AppxPackage -ErrorAction Stop |
        Where-Object {
            $_.SignatureKind -eq 'Store' -and
            $_.Name -notmatch '^Microsoft\.(Windows|NET|VCLibs|UI\.Xaml|DesktopAppInstaller|StorePurchaseApp)'
        } | ForEach-Object {
            $apps.Add([PSCustomObject]@{
                Name            = $_.Name
                Publisher       = $_.Publisher
                Version         = $_.Version.ToString()
                InstallDate     = $null
                SizeBytes       = [long]0
                UninstallString = ''
                InstallLocation = $_.InstallLocation
                IsMsi           = $false
                IsAppX          = $true
                AppXPackage     = $_
                ProductCode     = ''
                LastUsed        = $null
            })
        }
    } catch {}
    return $apps
}

function Invoke-Scan {
    [Console]::CursorVisible = $true
    Clear-Host
    $script:FirstRender = $true

    $W = [Console]::WindowWidth - 1
    Write-Host " AppUninstaller  >  Scanning...".PadRight($W) -ForegroundColor Black -BackgroundColor DarkMagenta
    Write-Host ""

    Write-Host "  Loading prefetch index..." -ForegroundColor Cyan
    $script:PrefetchMap = Build-PrefetchMap
    Write-Host "  $($script:PrefetchMap.Count) prefetch entries." -ForegroundColor DarkGray

    Write-Host "  Scanning Win32/MSI apps..." -ForegroundColor Cyan
    $list    = [System.Collections.Generic.List[object]]::new()
    $regApps = Get-RegistryApps
    foreach ($a in $regApps) { $list.Add($a) }
    Write-Host "  $($regApps.Count) apps found." -ForegroundColor DarkGray

    if ($IncludeStore) {
        Write-Host "  Scanning Store apps..." -ForegroundColor Cyan
        $storeApps = Get-StoreApps
        foreach ($a in $storeApps) { $list.Add($a) }
        Write-Host "  $($storeApps.Count) Store apps found." -ForegroundColor DarkGray
    }

    Write-Host "  Resolving last-used times..." -ForegroundColor Cyan
    foreach ($a in $list) { $a.LastUsed = Get-LastUsed $a }
    $resolved = ($list | Where-Object { $_.LastUsed -ne $null }).Count
    Write-Host "  Resolved for $resolved / $($list.Count) apps." -ForegroundColor DarkGray

    $script:AllApps    = $list.ToArray()
    $script:SelKeys    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:Cursor     = 0
    Sync-Filter

    Write-Host ""
    Write-Host ("  Done -- {0} apps loaded." -f $script:AllApps.Count) -ForegroundColor Green
    Start-Sleep -Milliseconds 700
}

function Sync-Filter {
    $sorted = switch ($script:SortMode) {
        'Name'      { $script:AllApps | Sort-Object Name }
        'Size'      { $script:AllApps | Sort-Object SizeBytes -Descending }
        'Date'      { $script:AllApps | Sort-Object { if ($_.InstallDate) { $_.InstallDate } else { [datetime]::MinValue } } -Descending }
        'Publisher' { $script:AllApps | Sort-Object Publisher }
        'Usage'     { $script:AllApps | Sort-Object { if ($_.LastUsed) { $_.LastUsed } else { [datetime]::MinValue } } -Descending }
    }

    if ($script:FilterText) {
        $ft = [regex]::Escape($script:FilterText)
        $script:Filtered = @($sorted | Where-Object { $_.Name -match $ft -or $_.Publisher -match $ft })
    } else {
        $script:Filtered = @($sorted)
    }

    if ($script:Cursor -ge $script:Filtered.Count) {
        $script:Cursor = [Math]::Max(0, $script:Filtered.Count - 1)
    }
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

function Render-Screen {
    [Console]::CursorVisible = $false

    if ($script:FirstRender) {
        Clear-Host
        $script:FirstRender = $false
    } else {
        [Console]::SetCursorPosition(0, 0)
    }

    $total  = $script:Filtered.Count
    $page   = if ($total -gt 0) { [Math]::Floor($script:Cursor / $PAGE_SIZE) } else { 0 }
    $pages  = [Math]::Max(1, [Math]::Ceiling($total / $PAGE_SIZE))
    $start  = $page * $PAGE_SIZE
    $slice  = @($script:Filtered | Select-Object -Skip $start -First $PAGE_SIZE)
    $selCnt = $script:SelKeys.Count
    $W      = [Console]::WindowWidth - 1
    $wide   = $W -ge 108   # show Last Used column only if wide enough

    # Row format: "  [*] [18]  Name..  Publisher..  Version..  yyyy-MM-dd  999.9 MB  [MSI]  12d ago"
    # Widths:      2  3  1  4  2  N  2  P  2  V  2  D  2  S  2  T  (2  L)

    # --- Header (line 1) ---
    $sub = "All Apps ($total)"
    if ($script:FilterText) { $sub += "  [filter: $($script:FilterText)]" }
    if ($selCnt -gt 0)      { $sub += "  [$selCnt selected]" }
    $hdrLine = " AppUninstaller  >  $sub"
    if ($hdrLine.Length -gt $W) { $hdrLine = $hdrLine.Substring(0, $W) }
    Write-Host $hdrLine.PadRight($W) -ForegroundColor Black -BackgroundColor DarkMagenta

    # --- Divider (line 2) ---
    Write-Host ("-" * $W) -ForegroundColor DarkGray

    # --- Blank (line 3) ---
    Write-Host "".PadRight($W)

    # --- Column header (line 4) ---
    $ch  = "".PadRight(2)                           # left margin
    $ch += "   "                                    # sel placeholder (3)
    $ch += " "                                      # gap
    $ch += "#".PadLeft($C_NUM)                      # num (4)
    $ch += "  " + "Name".PadRight($C_NAME)          # name
    $ch += "  " + "Publisher".PadRight($C_PUB)      # publisher
    $ch += "  " + "Version".PadRight($C_VER)        # version
    $ch += "  " + "Installed".PadRight($C_DATE)     # date
    $ch += "  " + "Size".PadLeft($C_SIZE)           # size
    $ch += "  " + "Type".PadRight($C_TYPE)          # type
    if ($wide) { $ch += "  " + "Last Used".PadRight($C_LAST) }
    if ($ch.Length -gt $W) { $ch = $ch.Substring(0, $W) }
    Write-Host $ch.PadRight($W) -ForegroundColor DarkCyan

    # --- App rows (lines 5 .. 5+PAGE_SIZE-1) ---
    for ($i = 0; $i -lt $PAGE_SIZE; $i++) {
        if ($i -lt $slice.Count) {
            $app      = $slice[$i]
            $absIdx   = $start + $i
            $isCursor = ($absIdx -eq $script:Cursor)
            $isSel    = $script:SelKeys.Contains((Get-AppKey $app))

            $selStr  = if ($isSel) { "[*]" } else { "[ ]" }
            $numStr  = "[$(($absIdx + 1))]".PadLeft($C_NUM)
            $nameStr = Clip $app.Name $C_NAME
            $pubStr  = Clip $app.Publisher $C_PUB
            $verStr  = Clip $app.Version $C_VER
            $dateStr = if ($app.InstallDate) { $app.InstallDate.ToString('yyyy-MM-dd') } else { "-" }
            $dateStr = $dateStr.PadRight($C_DATE)
            $sizeStr = if ($app.SizeBytes -gt 0) { Format-Size $app.SizeBytes } else { "-".PadLeft($C_SIZE) }
            $typeStr = if ($app.IsAppX) { "[Str]" } elseif ($app.IsMsi) { "[MSI]" } else { "[EXE]" }
            $lastStr = if ($wide) { "  " + (Format-LastUsed $app.LastUsed) } else { "" }

            $row  = "  $selStr $numStr  $nameStr  $pubStr  $verStr  $dateStr  $sizeStr  $typeStr$lastStr"
            if ($row.Length -gt $W) { $row = $row.Substring(0, $W) }
            $row  = $row.PadRight($W)

            if ($isCursor -and $isSel) {
                Write-Host $row -ForegroundColor Black -BackgroundColor Yellow
            } elseif ($isCursor) {
                Write-Host $row -ForegroundColor Black -BackgroundColor Cyan
            } elseif ($isSel) {
                Write-Host $row -ForegroundColor Yellow
            } else {
                Write-Host $row
            }
        } else {
            Write-Host "".PadRight($W)   # blank row -- keeps screen height fixed
        }
    }

    # --- Footer divider ---
    Write-Host ("-" * $W) -ForegroundColor DarkGray

    # --- Hint line 1 ---
    $h1 = "  Up/Down:move  Left/Right:page  Space:select  Ctrl+U:uninstall  Ctrl+R:refresh  Q:quit"
    Write-Host $h1.PadRight($W) -ForegroundColor DarkGray

    # --- Hint line 2 ---
    $sortLabel = "Sort:$($script:SortMode)"
    $h2 = "  F:filter  C:clear filter  S:$sortLabel  |  Page $($page+1)/$pages"
    if ($selCnt -gt 0) { $h2 += "  |  $selCnt app(s) selected -- press Ctrl+U to uninstall" }
    Write-Host $h2.PadRight($W) -ForegroundColor DarkGray

    [Console]::CursorVisible = $true
}

# ---------------------------------------------------------------------------
# Filter input (inline text entry -- no Read-Host)
# ---------------------------------------------------------------------------

function Show-FilterPrompt {
    Clear-Host
    $script:FirstRender = $true

    $W = [Console]::WindowWidth - 1
    Write-Host " AppUninstaller  >  Filter".PadRight($W) -ForegroundColor Black -BackgroundColor DarkMagenta
    Write-Host ("-" * $W) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Filter by app name or publisher." -ForegroundColor Cyan
    Write-Host "  Enter to apply  |  Escape to cancel  |  Backspace to erase" -ForegroundColor DarkGray
    if ($script:FilterText) {
        Write-Host "  Current: `"$($script:FilterText)`"" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Search: " -NoNewline -ForegroundColor Yellow

    $buf = ''
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) {
            $script:FilterText = $buf.Trim()
            Sync-Filter
            $script:Cursor = 0
            return
        }
        if ($k.Key -eq [ConsoleKey]::Escape) { return }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($buf.Length -gt 0) {
                $buf = $buf.Substring(0, $buf.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
        } elseif ($k.KeyChar -ge ' ') {
            $buf += $k.KeyChar
            Write-Host $k.KeyChar -NoNewline
        }
    }
}

# ---------------------------------------------------------------------------
# Uninstall confirmation screen
# ---------------------------------------------------------------------------

function Show-UninstallConfirm {
    $toUninstall = @($script:AllApps | Where-Object { $script:SelKeys.Contains((Get-AppKey $_)) })
    if ($toUninstall.Count -eq 0) { return }

    [Console]::CursorVisible = $true
    Clear-Host
    $script:FirstRender = $true

    $W = [Console]::WindowWidth - 1
    Write-Host " AppUninstaller  >  Confirm Uninstall".PadRight($W) -ForegroundColor Black -BackgroundColor DarkRed
    Write-Host ("-" * $W) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  The following $($toUninstall.Count) app(s) will be uninstalled:" -ForegroundColor Yellow
    Write-Host ""

    foreach ($app in $toUninstall) {
        $tag     = if ($app.IsAppX) { "[Store]" } elseif ($app.IsMsi) { "[MSI]  " } else { "[EXE]  " }
        $sizeStr = if ($app.SizeBytes -gt 0) { "  (" + (Format-Size $app.SizeBytes).Trim() + ")" } else { "" }
        Write-Host "    $tag  $($app.Name)$sizeStr" -ForegroundColor White
        if ($app.Publisher) { Write-Host "           by $($app.Publisher)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host ("-" * $W) -ForegroundColor DarkGray
    Write-Host "  Type YES and press Enter to uninstall.  Press Escape to cancel." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Confirm: " -NoNewline -ForegroundColor Yellow

    $buf = ''
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Escape) { return }
        if ($k.Key -eq [ConsoleKey]::Enter) {
            if ($buf -eq 'YES') { break }
            Write-Host ""
            Write-Host "  Type YES (uppercase) to confirm, or press Escape." -ForegroundColor Red
            Write-Host "  Confirm: " -NoNewline -ForegroundColor Yellow
            $buf = ''
            continue
        }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1); Write-Host "`b `b" -NoNewline }
        } elseif ($k.KeyChar -ge ' ') {
            $buf += $k.KeyChar
            Write-Host $k.KeyChar -NoNewline
        }
    }

    Write-Host ""
    Write-Host ""

    foreach ($app in $toUninstall) {
        Write-Host "  Uninstalling $($app.Name)..." -ForegroundColor Cyan
        if ($app.IsAppX)    { Do-UninstallAppX $app }
        elseif ($app.IsMsi) { Do-UninstallMsi  $app }
        else                { Do-UninstallExe  $app }
    }

    Write-Host ""
    Write-Host "  Finished. Press any key to continue..." -ForegroundColor Green
    $null = [Console]::ReadKey($true)

    Sync-Filter
}

# ---------------------------------------------------------------------------
# Uninstall implementations
# ---------------------------------------------------------------------------

function Do-UninstallAppX($app) {
    try {
        $app.AppXPackage | Remove-AppxPackage -ErrorAction Stop
        Write-Host "    Removed." -ForegroundColor Green
        $script:AllApps = @($script:AllApps | Where-Object { $_ -ne $app })
        $null = $script:SelKeys.Remove((Get-AppKey $app))
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
    }
}

function Do-UninstallMsi($app) {
    $guid = $app.ProductCode
    if (-not $guid -and $app.UninstallString -match '(\{[0-9A-Fa-f\-]{36}\})') {
        $guid = $Matches[1]
    }
    if (-not $guid) { Do-UninstallExe $app; return }

    $proc = Start-Process 'msiexec.exe' -ArgumentList "/X `"$guid`" /passive" -Wait -PassThru
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        $suffix = if ($proc.ExitCode -eq 3010) { " (reboot required to complete)" } else { "" }
        Write-Host "    Removed$suffix." -ForegroundColor Green
        $script:AllApps = @($script:AllApps | Where-Object { $_ -ne $app })
        $null = $script:SelKeys.Remove((Get-AppKey $app))
    } else {
        Write-Host "    msiexec exited $($proc.ExitCode) -- may not be fully removed." -ForegroundColor Red
    }
}

function Resolve-UninstallString($us) {
    # 1. Quoted path: "C:\path with spaces\uninst.exe" [args]
    if ($us -match '^"([^"]+)"\s*(.*)$') {
        return @{ Exe = $Matches[1]; Args = $Matches[2].Trim(); Raw = $null }
    }

    # 2. Unquoted path possibly containing spaces -- walk tokens longest-first
    $tokens = $us -split '\s+'
    for ($i = $tokens.Count; $i -ge 1; $i--) {
        $candidate = ($tokens[0..($i - 1)]) -join ' '
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $rest = if ($i -lt $tokens.Count) { ($tokens[$i..($tokens.Count - 1)]) -join ' ' } else { '' }
            return @{ Exe = $candidate; Args = $rest.Trim(); Raw = $null }
        }
    }

    # 3. Nothing matched -- hand the whole string to cmd /c and let Windows parse it
    return @{ Exe = $null; Args = $null; Raw = $us }
}

function Do-UninstallExe($app) {
    $us = $app.UninstallString
    if (-not $us) { Write-Host "    No uninstall string found." -ForegroundColor Red; return }

    $parsed = Resolve-UninstallString $us

    # Check whether the uninstaller exe actually exists on disk
    $exeMissing = (-not $parsed.Raw) -and (-not (Test-Path -LiteralPath $parsed.Exe -PathType Leaf))

    if ($exeMissing) {
        Write-Host "    Uninstaller exe not found -- app appears already removed." -ForegroundColor Yellow
        Write-Host "    Cleaning up orphaned registry entry..." -ForegroundColor Cyan
        try {
            if ($app.RegKeyPath) {
                Remove-Item -LiteralPath $app.RegKeyPath -Recurse -ErrorAction Stop
                Write-Host "    Registry entry removed." -ForegroundColor Green
            } else {
                Write-Host "    No registry path stored -- skipping cleanup." -ForegroundColor DarkGray
            }
            $script:AllApps = @($script:AllApps | Where-Object { $_ -ne $app })
            $null = $script:SelKeys.Remove((Get-AppKey $app))
        } catch {
            Write-Host "    Could not remove registry entry: $_" -ForegroundColor Red
        }
        return
    }

    try {
        if ($parsed.Raw) {
            # Unrecognised format -- let cmd.exe handle it
            Write-Host "    Running via cmd: $($parsed.Raw)" -ForegroundColor DarkGray
            $proc = Start-Process 'cmd.exe' -ArgumentList "/c `"$($parsed.Raw)`"" -Wait -PassThru -ErrorAction Stop
        } elseif ($parsed.Args) {
            $proc = Start-Process $parsed.Exe -ArgumentList $parsed.Args -Wait -PassThru -ErrorAction Stop
        } else {
            $proc = Start-Process $parsed.Exe -Wait -PassThru -ErrorAction Stop
        }
        Write-Host "    Uninstaller finished (exit $($proc.ExitCode))." -ForegroundColor Green
        $script:AllApps = @($script:AllApps | Where-Object { $_ -ne $app })
        $null = $script:SelKeys.Remove((Get-AppKey $app))
    } catch {
        Write-Host "    Error: $_" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Show-AppList {
    while ($true) {
        Render-Screen

        $k    = [Console]::ReadKey($true)
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0

        $total = $script:Filtered.Count
        $pages = [Math]::Max(1, [Math]::Ceiling($total / $PAGE_SIZE))
        $page  = if ($total -gt 0) { [Math]::Floor($script:Cursor / $PAGE_SIZE) } else { 0 }

        switch ($k.Key) {

            ([ConsoleKey]::UpArrow) {
                if ($script:Cursor -gt 0) { $script:Cursor-- }
            }

            ([ConsoleKey]::DownArrow) {
                if ($script:Cursor -lt ($total - 1)) { $script:Cursor++ }
            }

            ([ConsoleKey]::LeftArrow) {
                if ($page -gt 0) { $script:Cursor = ($page - 1) * $PAGE_SIZE }
            }

            ([ConsoleKey]::RightArrow) {
                if ($page -lt $pages - 1) { $script:Cursor = ($page + 1) * $PAGE_SIZE }
            }

            ([ConsoleKey]::Spacebar) {
                if ($total -gt 0) {
                    $app = $script:Filtered[$script:Cursor]
                    $key = Get-AppKey $app
                    if ($script:SelKeys.Contains($key)) { $null = $script:SelKeys.Remove($key) }
                    else                                { $null = $script:SelKeys.Add($key) }
                    # Advance cursor after toggling
                    if ($script:Cursor -lt $total - 1) { $script:Cursor++ }
                }
            }

            ([ConsoleKey]::U) {
                if ($ctrl -and $script:SelKeys.Count -gt 0) {
                    Show-UninstallConfirm
                }
            }

            ([ConsoleKey]::R) {
                if ($ctrl) { Invoke-Scan }
            }

            ([ConsoleKey]::F) {
                Show-FilterPrompt
            }

            ([ConsoleKey]::C) {
                $script:FilterText = ''
                Sync-Filter
                $script:Cursor = 0
            }

            ([ConsoleKey]::S) {
                $script:SortMode = switch ($script:SortMode) {
                    'Name'      { 'Size' }
                    'Size'      { 'Date' }
                    'Date'      { 'Publisher' }
                    'Publisher' { 'Usage' }
                    'Usage'     { 'Name' }
                }
                Sync-Filter
            }

            ([ConsoleKey]::Q) { return }
        }
    }
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

try { $Host.UI.RawUI.WindowTitle = "AppUninstaller" } catch {}

Invoke-Scan
Show-AppList

[Console]::CursorVisible = $true
Clear-Host
Write-Host ""
Write-Host "  Goodbye." -ForegroundColor DarkGray
Write-Host ""
