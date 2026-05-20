<#
.SYNOPSIS
    Search -- fast file and content search.

    search <query>                          search filenames recursively
    search <query> --content                search inside files
    search <query> --logs                   limit to .log, .txt
    search <query> --json                   limit to .json
    search <query> --code                   limit to .js, .ts, .cs, .ps1
    search <query> --path <dir>             set root directory
    search <query> --limit <n>              cap results
    search <query> --open <n>               open result number n
    search <query> --jsonout                 output as JSON
    search <query> --excl node_modules,dist  exclude dirs or filename patterns (comma-separated)
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Query = '',

    [switch]$Content,
    [switch]$Logs,
    [Alias('json')]
    [switch]$JsonFiles,
    [switch]$Code,

    [string]$Path = '',

    [int]$Limit = 50,

    [int]$Open = 0,

    [switch]$Jsonout,

    [string]$Excl = ''
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Ok   ([string]$m) { Write-Host "  [OK]  $m" -ForegroundColor Green  }
function Write-Err  ([string]$m) { Write-Host "  [ERR] $m" -ForegroundColor Red    }
function Write-Info ([string]$m) { Write-Host "  [..]  $m" -ForegroundColor Cyan   }
function Write-Warn ([string]$m) { Write-Host "  [!!]  $m" -ForegroundColor Yellow }

function Clip([string]$s, [int]$w) {
    if ($null -eq $s -or $s.Length -eq 0) { return ''.PadRight($w) }
    if ($s.Length -gt $w) { return $s.Substring(0, $w - 2) + '..' }
    return $s.PadRight($w)
}

# ---------------------------------------------------------------------------
# Extension filter resolution
# ---------------------------------------------------------------------------

$EXT_LOGS = @('*.log', '*.txt')
$EXT_JSON = @('*.json')
$EXT_CODE = @('*.js', '*.ts', '*.cs', '*.ps1')

function Get-IncludePatterns {
    if ($Logs)      { return $EXT_LOGS }
    if ($JsonFiles) { return $EXT_JSON }
    if ($Code)      { return $EXT_CODE }
    return @('*')
}

# Directories never worth scanning
$SKIP_DIRS = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('node_modules','.git','.svn','.vs','.idea','bin','obj',
                 'dist','out','build','.next','.nuget','packages',
                 'vendor','__pycache__','.cache'),
    [System.StringComparer]::OrdinalIgnoreCase
)

# ---------------------------------------------------------------------------
# Core search functions
# ---------------------------------------------------------------------------

function Search-ByName {
    param([string]$Root, [string]$Pattern, [string[]]$Include, [int]$Cap)

    $list     = [System.Collections.Generic.List[object]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $noFilter = ($Include.Count -eq 1 -and $Include[0] -eq '*')
    $queue    = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root)

    while ($queue.Count -gt 0 -and $list.Count -lt $Cap) {
        $dir = $queue.Dequeue()

        try {
            if ($noFilter) {
                foreach ($path in [System.IO.Directory]::EnumerateFiles($dir, "*$Pattern*")) {
                    if ($list.Count -ge $Cap) { break }
                    if (-not $seen.Add($path)) { continue }
                    $fi = [System.IO.FileInfo]::new($path)
                    $list.Add([PSCustomObject]@{
                        File = $path; Name = $fi.Name
                        Modified = $fi.LastWriteTime; MatchCount = 0; Lines = @()
                    })
                }
            } else {
                foreach ($inc in $Include) {
                    if ($list.Count -ge $Cap) { break }
                    foreach ($path in [System.IO.Directory]::EnumerateFiles($dir, $inc)) {
                        if ($list.Count -ge $Cap) { break }
                        if ([System.IO.Path]::GetFileName($path) -notlike "*$Pattern*") { continue }
                        if (-not $seen.Add($path)) { continue }
                        $fi = [System.IO.FileInfo]::new($path)
                        $list.Add([PSCustomObject]@{
                            File = $path; Name = $fi.Name
                            Modified = $fi.LastWriteTime; MatchCount = 0; Lines = @()
                        })
                    }
                }
            }
        } catch {}

        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if (-not $SKIP_DIRS.Contains([System.IO.Path]::GetFileName($sub))) {
                    $queue.Enqueue($sub)
                }
            }
        } catch {}
    }

    return ,$list.ToArray()
}

function Search-ByContent {
    param([string]$Root, [string]$Pattern, [string[]]$Include, [int]$Cap)

    $list  = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root)

    while ($queue.Count -gt 0 -and $list.Count -lt $Cap) {
        $dir = $queue.Dequeue()

        try {
            foreach ($inc in $Include) {
                if ($list.Count -ge $Cap) { break }
                foreach ($path in [System.IO.Directory]::EnumerateFiles($dir, $inc)) {
                    if ($list.Count -ge $Cap) { break }
                    $hits = Select-String -Path $path -Pattern $Pattern -ErrorAction SilentlyContinue
                    if (-not $hits) { continue }
                    $lines = @($hits | ForEach-Object { "  Line $($_.LineNumber): $($_.Line.Trim())" })
                    $fi = [System.IO.FileInfo]::new($path)
                    $list.Add([PSCustomObject]@{
                        File = $path; Name = $fi.Name
                        Modified = $fi.LastWriteTime; MatchCount = $lines.Count; Lines = $lines
                    })
                }
            }
        } catch {}

        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if (-not $SKIP_DIRS.Contains([System.IO.Path]::GetFileName($sub))) {
                    $queue.Enqueue($sub)
                }
            }
        } catch {}
    }

    return ,@($list | Sort-Object @{E='MatchCount'; D=$true}, @{E='Modified'; D=$true})
}

# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

function Format-Results {
    param([object[]]$Results, [bool]$IsContent)

    if ($Results.Count -eq 0) {
        Write-Warn "No results found."
        return
    }

    $mode = if ($IsContent) { 'content' } else { 'filename' }
    Write-Host ""
    Write-Host "  Found $($Results.Count) result(s)  [mode: $mode]" -ForegroundColor Cyan
    Write-Host ""

    $idx = 1
    foreach ($r in $Results) {
        $relPath = $r.File
        try {
            $relPath = [System.IO.Path]::GetRelativePath($RootDir, $r.File)
        } catch {}

        $modStr = $r.Modified.ToString('yyyy-MM-dd HH:mm')
        $countStr = if ($IsContent) { "  $($r.MatchCount) match(es)" } else { '' }

        Write-Host "  [$idx] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$relPath" -ForegroundColor White -NoNewline
        Write-Host "  $modStr$countStr" -ForegroundColor DarkGray

        foreach ($line in $r.Lines) {
            Write-Host $line -ForegroundColor Yellow
        }

        $idx++
    }

    Write-Host ""
}

function Format-ResultsJson {
    param([object[]]$Results)

    $out = @($Results | ForEach-Object {
        $mod = if ($_.Modified) { $_.Modified.ToString('o') } else { $null }
        [PSCustomObject]@{
            file       = $_.File
            name       = $_.Name
            modified   = $mod
            matchCount = $_.MatchCount
            lines      = $_.Lines
        }
    })
    Write-Output ($out | ConvertTo-Json -Depth 4)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $Query) {
    Write-Err "Usage: pt search <query> [--content] [--logs|--json|--code] [--path <dir>] [--limit <n>] [--open <n>] [--json-out]"
    exit 1
}

$RootDir = if ($Path) { $Path } else { (Get-Location).Path }
$RootDir = [System.IO.Path]::GetFullPath($RootDir)

if (-not [System.IO.Directory]::Exists($RootDir)) {
    Write-Err "Path not found: $RootDir"
    exit 1
}

if ($Excl) {
    $Excl -split ',' | ForEach-Object {
        $t = $_.Trim()
        if ($t) { $SKIP_DIRS.Add($t) | Out-Null }
    }
}

$includePatterns = Get-IncludePatterns

if ($Content) {
    $results = Search-ByContent -Root $RootDir -Pattern $Query -Include $includePatterns -Cap $Limit
} else {
    $results = Search-ByName -Root $RootDir -Pattern $Query -Include $includePatterns -Cap $Limit
}

# --open: launch file by result number
if ($Open -gt 0) {
    if ($Open -gt $results.Count) {
        Write-Err "Result $Open does not exist (only $($results.Count) result(s))."
        exit 1
    }
    $target = $results[$Open - 1].File
    Write-Info "Opening: $target"
    Start-Process $target
    exit 0
}

if ($Jsonout) {
    Format-ResultsJson -Results $results
} else {
    Format-Results -Results $results -IsContent $Content.IsPresent
}
