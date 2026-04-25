<#
.SYNOPSIS
    Lightweight AI-powered file organizer.

.DESCRIPTION
    Classifies files by keyword and extension rules (primary logic).
    Uses Ollama AI as a fallback only when rules cannot determine a category.
    Detects duplicates via SHA256 hash, logs all actions, and exports metadata to JSON.

.PARAMETER Source
    Directory to scan. Defaults to the current user's Downloads folder.

.PARAMETER Destination
    Root folder where organized files will be placed.
    Defaults to an "Organized" folder inside Source.

.PARAMETER Model
    Ollama model to use when -UseAI is set. Defaults to gemma:2b.

.PARAMETER UseAI
    Enable AI fallback for files that rule-based logic cannot categorize.

.PARAMETER DryRun
    Show all planned actions without moving any files.
#>

param (
    [string]$Source      = (Join-Path $env:USERPROFILE "Downloads"),
    [string]$Destination = "",
    [string]$Model       = "gemma:2b",
    [switch]$UseAI,
    [switch]$DryRun
)

# -- Bootstrap ----------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $Source "Organized"
}

$OllamaBase   = "http://localhost:11434"
$ValidCats    = @("Documents","Images","Videos","Code","Archives","Finance","Others")

# Resolved after Destination is known
$LogFile      = Join-Path $Destination "organizer.log"
$MetadataFile = Join-Path $Destination "organizer-metadata.json"

# -- Classification maps ------------------------------------------------------

$ExtensionMap = @{
    # Documents
    ".pdf"  = "Documents"; ".doc"  = "Documents"; ".docx" = "Documents"; ".rtf"  = "Documents"
    ".xls"  = "Documents"; ".xlsx" = "Documents"; ".csv"  = "Documents"
    ".ppt"  = "Documents"; ".pptx" = "Documents"
    ".txt"  = "Documents"; ".md"   = "Documents"; ".log"  = "Documents"
    ".odt"  = "Documents"; ".ods"  = "Documents"; ".odp"  = "Documents"

    # Images
    ".jpg"  = "Images"; ".jpeg" = "Images"; ".png"  = "Images"; ".gif"  = "Images"
    ".bmp"  = "Images"; ".svg"  = "Images"; ".webp" = "Images"; ".heic" = "Images"
    ".tiff" = "Images"; ".tif"  = "Images"; ".ico"  = "Images"; ".avif" = "Images"
    ".raw"  = "Images"

    # Videos
    ".mp4"  = "Videos"; ".mkv"  = "Videos"; ".avi"  = "Videos"; ".mov"  = "Videos"
    ".wmv"  = "Videos"; ".flv"  = "Videos"; ".webm" = "Videos"; ".m4v"  = "Videos"
    ".mpg"  = "Videos"; ".mpeg" = "Videos"

    # Code
    ".py"   = "Code"; ".js"   = "Code"; ".ts"   = "Code"; ".cs"   = "Code"
    ".java" = "Code"; ".cpp"  = "Code"; ".c"    = "Code"; ".h"    = "Code"
    ".html" = "Code"; ".css"  = "Code"; ".php"  = "Code"; ".rb"   = "Code"
    ".go"   = "Code"; ".rs"   = "Code"; ".ps1"  = "Code"; ".sh"   = "Code"
    ".json" = "Code"; ".xml"  = "Code"; ".yaml" = "Code"; ".yml"  = "Code"; ".sql" = "Code"

    # Archives
    ".zip"  = "Archives"; ".rar"  = "Archives"; ".7z"   = "Archives"
    ".tar"  = "Archives"; ".gz"   = "Archives"; ".bz2"  = "Archives"
    ".xz"   = "Archives"; ".iso"  = "Archives"
}

# Keyword rules checked before extension map (ordered: first match wins)
$KeywordRules = [ordered]@{
    "Finance"   = @("invoice","bill","receipt","payment","tax","salary","payslip",
                    "statement","budget","expense","finance","bank","ledger",
                    "transaction","refund","purchase","order","quote","payroll")
    "Documents" = @("report","resume","cv","letter","contract","agreement","proposal",
                    "memo","manual","guide","notes","summary","minutes","agenda","policy")
}

# -- Helpers ------------------------------------------------------------------

function Write-Rule    { Write-Host ("  " + ("-" * 54)) -ForegroundColor DarkGray }
function Write-Blank   { Write-Host "" }
function Write-Section ([string]$Title) {
    Write-Blank
    Write-Host "  $Title" -ForegroundColor White
    Write-Rule
}

function Write-Log ([string]$Action, [string]$Message) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$($Action.PadRight(9))] $Message"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# -- Core functions -----------------------------------------------------------

function Get-SHA256 ([string]$FilePath) {
    try {
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($FilePath)
        $bytes  = $hasher.ComputeHash($stream)   # reads in chunks internally — memory-safe
        $stream.Close()
        $hasher.Dispose()
        return [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
    } catch { return $null }
}

function Get-Category ([string]$FileName, [string]$Extension) {
    $lower = $FileName.ToLower()
    $ext   = $Extension.ToLower()

    # 1. Keyword rules (highest priority)
    foreach ($cat in $KeywordRules.Keys) {
        foreach ($kw in $KeywordRules[$cat]) {
            if ($lower -like "*$kw*") { return $cat }
        }
    }

    # 2. Extension map
    if ($ExtensionMap.ContainsKey($ext)) { return $ExtensionMap[$ext] }

    return $null  # caller decides: use AI or fall back to Others
}

function Get-Tags ([string]$FileName, [string]$Extension, [string]$Category, [string[]]$AITags) {
    $tags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $tags.Add($Category.ToLower()) | Out-Null
    if ($Extension) { $tags.Add($Extension.TrimStart(".").ToLower()) | Out-Null }

    # Meaningful words from the filename
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base -split "[\s_\-\.\(\)\[\]]" |
        Where-Object { $_.Length -gt 3 -and $_ -match "^[a-zA-Z]" } |
        ForEach-Object { $tags.Add($_.ToLower()) | Out-Null }

    foreach ($t in $AITags) {
        if (-not [string]::IsNullOrWhiteSpace($t)) { $tags.Add($t.Trim().ToLower()) | Out-Null }
    }

    return @($tags)
}

function Invoke-AICategory ([string]$FileName) {
    $prompt = @"
You are a file classifier. Given only the filename, choose the best category and suggest up to 2 short tags.

Valid categories: Documents, Images, Videos, Code, Archives, Finance, Others

Filename: $FileName

Return ONLY valid JSON (no explanation): {"Category":"name","Tags":["tag1","tag2"]}
"@
    $body = @{ model = $Model; prompt = $prompt; stream = $false; format = "json" } | ConvertTo-Json -Depth 2

    try {
        $resp = Invoke-RestMethod -Uri "$OllamaBase/api/generate" -Method Post `
                    -Body $body -ContentType "application/json" -TimeoutSec 30
        $raw  = $resp.response.Trim() -replace '(?s)^\s*```[a-z]*\s*', '' -replace '\s*```\s*$', ''
        $obj  = $raw | ConvertFrom-Json
        $cat  = $ValidCats | Where-Object { $_ -ieq "$($obj.Category)".Trim() } | Select-Object -First 1
        return @{
            Category = if ($cat) { $cat } else { "Others" }
            Tags     = if ($obj.Tags) { @($obj.Tags | ForEach-Object { "$_" }) } else { @() }
        }
    } catch { return $null }
}

function Move-OrganizedFile ([string]$SourcePath, [string]$DestDir, [string]$FileName) {
    $dest = Join-Path $DestDir $FileName
    if (Test-Path $dest) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        $ext  = [System.IO.Path]::GetExtension($FileName)
        $n    = 2
        do { $dest = Join-Path $DestDir "${base}_${n}${ext}"; $n++ } while (Test-Path $dest)
    }
    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    Move-Item -Path $SourcePath -Destination $dest -ErrorAction Stop
    return $dest
}

# -- Ollama validation --------------------------------------------------------

function Test-OllamaReady {
    # 1. Check Ollama CLI is installed
    if (-not (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
        Write-Blank
        Write-Host "  ERROR: Ollama is not installed." -ForegroundColor Red
        Write-Blank
        Write-Host "  Ollama is required for AI-assisted classification." -ForegroundColor White
        Write-Host "  Download : https://ollama.com/download" -ForegroundColor Cyan
        Write-Blank
        Write-Host "  After installing, pull a lightweight model:" -ForegroundColor White
        Write-Host "    ollama pull gemma:2b" -ForegroundColor DarkGray
        Write-Host "    ollama pull llama3.2:1b" -ForegroundColor DarkGray
        Write-Blank
        return $false
    }

    # 2. Fetch installed models (API first, CLI fallback)
    $models = @()
    try {
        $resp   = Invoke-RestMethod -Uri "$OllamaBase/api/tags" -Method Get -TimeoutSec 5
        $models = @($resp.models | ForEach-Object { $_.name } | Where-Object { $_ })
    } catch {
        try {
            $out    = & ollama list 2>&1
            $models = @($out | Select-Object -Skip 1 |
                        ForEach-Object { ($_ -split '\s+')[0] } |
                        Where-Object { $_ -and $_ -notmatch '^-' })
        } catch {
            Write-Host "  ERROR: Ollama is installed but not responding." -ForegroundColor Red
            Write-Host "  Launch the Ollama application and try again." -ForegroundColor Yellow
            return $false
        }
    }

    # 3. No models available
    if ($models.Count -eq 0) {
        Write-Blank
        Write-Host "  No models found in Ollama." -ForegroundColor Yellow
        Write-Blank
        Write-Host "  Pull a lightweight model first:" -ForegroundColor White
        Write-Host "    ollama pull gemma:2b" -ForegroundColor DarkGray
        Write-Host "    ollama pull llama3.2:1b" -ForegroundColor DarkGray
        Write-Blank
        return $false
    }

    # 4. -Model matches an installed model — use it directly
    $exact = $models | Where-Object { $_ -ieq $script:Model } | Select-Object -First 1
    if ($exact) { $script:Model = $exact; return $true }

    # 5. Interactive model selection
    Write-Section "SELECT AI MODEL"
    Write-Host "  Specified model '$($script:Model)' not found. Available models:" -ForegroundColor Yellow
    Write-Blank
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host "  [$($i + 1)]  $($models[$i])"
    }
    Write-Blank
    $choice = Read-Host "  Enter number"

    if ($choice -match "^\d+$") {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $models.Count) {
            $script:Model = $models[$idx]
            Write-Host "  Using: $($script:Model)" -ForegroundColor DarkGreen
            return $true
        }
    }

    Write-Host "  Invalid selection. Exiting." -ForegroundColor Red
    return $false
}

# -- Validate source ----------------------------------------------------------

if (-not (Test-Path -Path $Source -PathType Container)) {
    Write-Host ""
    Write-Host "  ERROR: Source directory not found: $Source" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# -- Ollama check (only when -UseAI) -----------------------------------------

if ($UseAI -and -not (Test-OllamaReady)) { exit 1 }

# -- Setup destination + log --------------------------------------------------

New-Item -Path $Destination -ItemType Directory -Force | Out-Null
Write-Log "START" "Source=$Source | Dest=$Destination | UseAI=$UseAI | DryRun=$DryRun | Model=$Model"

# -- Header -------------------------------------------------------------------

Write-Blank
Write-Host "  File Organizer AI" -ForegroundColor Cyan
Write-Host "  Source      : $Source" -ForegroundColor DarkGray
Write-Host "  Destination : $Destination" -ForegroundColor DarkGray
if ($UseAI) {
    Write-Host "  Model       : $Model" -ForegroundColor DarkGray
}
Write-Host "  AI          : $(if ($UseAI) { "Enabled (fallback only)" } else { "Disabled  (use -UseAI to enable)" })" `
    -ForegroundColor $(if ($UseAI) { "DarkGreen" } else { "DarkGray" })
if ($DryRun) {
    Write-Host "  Mode        : DRY RUN - no files will be moved" -ForegroundColor Yellow
}
Write-Rule

# -- Scan ---------------------------------------------------------------------

Write-Blank
Write-Host "  Scanning..." -ForegroundColor DarkGray
$allFiles = @(Get-ChildItem -Path $Source -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -ne $LogFile -and
                    $_.FullName -ne $MetadataFile
                })
Write-Host "  Found $($allFiles.Count) file(s)" -ForegroundColor DarkGray
Write-Rule
Write-Blank

# -- Process ------------------------------------------------------------------

$seenHashes  = @{}                                               # hash -> first filename seen
$metadata    = [System.Collections.Generic.List[PSObject]]::new()
$catCounts   = @{}                                               # category -> count

$totalCount = 0
$movedCount = 0
$dupCount   = 0
$aiCount    = 0
$errorCount = 0

foreach ($file in $allFiles) {
    $totalCount++

    # Capture metadata
    $entry = [PSCustomObject]@{
        FileName     = $file.Name
        Extension    = $file.Extension.ToLower()
        SizeKB       = [Math]::Round($file.Length / 1KB, 1)
        Created      = $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
        Modified     = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        Category     = ""
        Tags         = @()
        OriginalPath = $file.FullName
        NewPath      = ""
        AIUsed       = $false
        Duplicate    = $false
    }

    # -- Duplicate detection --------------------------------------------------

    $hash = Get-SHA256 $file.FullName

    if ($hash -and $seenHashes.ContainsKey($hash)) {
        $dupCount++
        $entry.Duplicate = $true
        $entry.Category  = "Duplicates"
        $dupDir = Join-Path $Destination "Duplicates"

        Write-Host "  ~  " -ForegroundColor DarkYellow -NoNewline
        Write-Host "$($file.Name.PadRight(40))" -NoNewline
        Write-Host "duplicate of: $($seenHashes[$hash])" -ForegroundColor DarkYellow

        Write-Log "DUPLICATE" "$($file.FullName) | original: $($seenHashes[$hash])"

        if (-not $DryRun) {
            try {
                $newPath        = Move-OrganizedFile $file.FullName $dupDir $file.Name
                $entry.NewPath  = $newPath
            } catch {
                Write-Log "ERROR" "Failed to move duplicate '$($file.Name)': $($_.Exception.Message)"
                $errorCount++
            }
        } else {
            $entry.NewPath = Join-Path $dupDir $file.Name
        }

        $metadata.Add($entry)
        continue
    }
    if ($hash) { $seenHashes[$hash] = $file.Name }

    # -- Classify -------------------------------------------------------------

    $aiTags  = @()
    $category = Get-Category $file.Name $file.Extension
    $aiUsed  = $false

    if (-not $category) {
        if ($UseAI) {
            $aiResult = Invoke-AICategory $file.Name
            if ($aiResult) {
                $category = $aiResult.Category
                $aiTags   = $aiResult.Tags
                $aiUsed   = $true
                $aiCount++
            }
        }
        if (-not $category) { $category = "Others" }
    }

    $entry.Category = $category
    $entry.AIUsed   = $aiUsed
    $entry.Tags     = Get-Tags $file.Name $file.Extension $category $aiTags

    # Track category counts
    if (-not $catCounts.ContainsKey($category)) { $catCounts[$category] = 0 }
    $catCounts[$category]++

    # -- Move -----------------------------------------------------------------

    $destDir = Join-Path $Destination $category
    $aiTag   = if ($aiUsed) { " [AI]" } else { "" }

    if ($DryRun) {
        Write-Host "  o  " -ForegroundColor Cyan -NoNewline
        Write-Host "$($file.Name.PadRight(40))" -NoNewline
        Write-Host "->  $category$aiTag" -ForegroundColor DarkCyan
        $entry.NewPath = Join-Path $destDir $file.Name
        Write-Log "DRY-RUN" "$($file.FullName) -> $destDir"
        $movedCount++
    } else {
        try {
            $newPath       = Move-OrganizedFile $file.FullName $destDir $file.Name
            $entry.NewPath = $newPath
            Write-Host "  +  " -ForegroundColor Green -NoNewline
            Write-Host "$($file.Name.PadRight(40))" -NoNewline
            Write-Host "->  $category$aiTag" -ForegroundColor DarkGreen
            Write-Log "MOVED" "$($file.FullName) -> $newPath"
            $movedCount++
        } catch {
            Write-Host "  x  " -ForegroundColor Red -NoNewline
            Write-Host "$($file.Name)  ($($_.Exception.Message))" -ForegroundColor DarkRed
            Write-Log "ERROR" "$($file.FullName): $($_.Exception.Message)"
            $entry.Category = "Error"
            $errorCount++
        }
    }

    $metadata.Add($entry)
}

# -- Export metadata ----------------------------------------------------------

if ($metadata.Count -gt 0) {
    try {
        $metadata | ConvertTo-Json -Depth 4 |
            Set-Content -Path $MetadataFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "EXPORT" "Metadata written to $MetadataFile"
    } catch {
        Write-Log "ERROR" "Failed to write metadata: $($_.Exception.Message)"
    }
}

Write-Log "END" "Total=$totalCount | Moved=$movedCount | Duplicates=$dupCount | AI=$aiCount | Errors=$errorCount"

# -- Summary ------------------------------------------------------------------

Write-Section "SUMMARY"
$verb = if ($DryRun) { "To move  " } else { "Moved    " }
Write-Host "  Total processed   $totalCount"  -ForegroundColor White
Write-Host "  $verb         $movedCount"  -ForegroundColor $(if ($movedCount -gt 0) { "Green"      } else { "DarkGray" })
Write-Host "  Duplicates found  $dupCount"   -ForegroundColor $(if ($dupCount  -gt 0) { "DarkYellow" } else { "DarkGray" })
Write-Host "  AI assisted       $aiCount"    -ForegroundColor $(if ($aiCount   -gt 0) { "Magenta"    } else { "DarkGray" })
Write-Host "  Errors            $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red"        } else { "DarkGray" })

if ($catCounts.Count -gt 0) {
    Write-Section "BY CATEGORY"
    $catCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $label = $_.Key.PadRight(20)
        $count = $_.Value
        Write-Host "  $label  $count file$(if ($count -ne 1) { 's' })" -ForegroundColor DarkCyan
    }
}

Write-Blank
Write-Host "  Log      : $LogFile" -ForegroundColor DarkGray
Write-Host "  Metadata : $MetadataFile" -ForegroundColor DarkGray
Write-Blank
Write-Rule
Write-Host "  Done." -ForegroundColor Cyan
Write-Blank
