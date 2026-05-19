<#
.SYNOPSIS
    EnvManager -- manage environment variables, PATH, .env files, and profiles.

    env --list [--user | --system] [--json]
    env --get <NAME>
    env --set NAME=VALUE [--system]
    env --delete <NAME> [--system]
    env --temp NAME=VALUE
    env --path --list | --add <dir> [<dir>...] | --remove <dir> [<dir>...]
    env --load <file.env>
    env --export <file.env>
    env --profile <name>
    env --generate node | python | dotnet
#>

[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Get,
    [switch]$Set,
    [switch]$Delete,
    [switch]$Temp,
    [switch]$Path,
    [switch]$Load,
    [switch]$Export,
    [switch]$Profile,
    [switch]$Generate,

    [switch]$User,
    [switch]$System,
    [switch]$Add,
    [switch]$Remove,
    [switch]$Json,

    [Parameter(Position=0, ValueFromRemainingArguments)]
    [string[]]$Values = @()
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

$SENSITIVE_PATTERNS = @('KEY', 'SECRET', 'TOKEN', 'PASSWORD', 'PASS', 'PWD', 'CREDENTIAL', 'AUTH')

function Mask-Value ([string]$name, [string]$value) {
    foreach ($p in $SENSITIVE_PATTERNS) {
        if ($name.ToUpper().Contains($p)) {
            if ($value.Length -le 4) { return '****' }
            return $value.Substring(0, 4) + ('*' * [Math]::Min(8, $value.Length - 4))
        }
    }
    return $value
}

function Is-ValidVarName ([string]$name) {
    return $name -match '^[A-Za-z_][A-Za-z0-9_]*$'
}

function Get-ProfileDir {
    return Join-Path $PSScriptRoot '..\env-profiles'
}

# ---------------------------------------------------------------------------
# Action: --list
# ---------------------------------------------------------------------------

function Invoke-List {
    param([string]$Scope, [bool]$AsJson)

    $scopes = if ($Scope -eq 'User') { @('User') }
              elseif ($Scope -eq 'Machine') { @('Machine') }
              else { @('User', 'Machine') }

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($sc in $scopes) {
        $label = if ($sc -eq 'Machine') { 'System' } else { 'User' }
        $vars  = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::$sc)
        foreach ($key in ($vars.Keys | Sort-Object)) {
            $val = [string]$vars[$key]
            $rows.Add([PSCustomObject]@{
                Name  = $key
                Value = Mask-Value $key $val
                Scope = $label
            })
        }
    }

    if ($AsJson) { $rows | ConvertTo-Json -Depth 5; return }

    $C_NAME  = 30
    $C_SCOPE = 8
    $C_VAL   = 55

    Write-Host ''
    $hdr = '  ' + (Clip 'NAME' $C_NAME) + '  ' + (Clip 'SCOPE' $C_SCOPE) + '  VALUE'
    $sep = '  ' + ('-' * $C_NAME) + '  ' + ('-' * $C_SCOPE) + '  ' + ('-' * $C_VAL)
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkGray

    foreach ($r in $rows) {
        $color = if ($r.Scope -eq 'System') { 'Yellow' } else { 'Gray' }
        $line  = '  ' + (Clip $r.Name $C_NAME) + '  ' + (Clip $r.Scope $C_SCOPE) + '  ' + $r.Value
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ''
    Write-Host "  $($rows.Count) variable(s)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: --get
# ---------------------------------------------------------------------------

function Invoke-Get {
    param([string]$Name)

    if (-not $Name) { Write-Err '--get requires a variable name.  Example: env --get PATH'; return }

    $userVal   = [System.Environment]::GetEnvironmentVariable($Name, 'User')
    $sysVal    = [System.Environment]::GetEnvironmentVariable($Name, 'Machine')
    $sessionVal = [System.Environment]::GetEnvironmentVariable($Name)

    if ($null -eq $userVal -and $null -eq $sysVal) {
        Write-Warn "Variable '$Name' not found in User or System scope."
        return
    }

    Write-Host ''
    Write-Host "  Variable : $Name" -ForegroundColor White

    if ($null -ne $userVal) {
        Write-Host "  User     : $(Mask-Value $Name $userVal)" -ForegroundColor Gray
    }
    if ($null -ne $sysVal) {
        Write-Host "  System   : $(Mask-Value $Name $sysVal)" -ForegroundColor Yellow
    }
    if ($null -ne $sessionVal -and $sessionVal -ne $userVal -and $sessionVal -ne $sysVal) {
        Write-Host "  Session  : $(Mask-Value $Name $sessionVal)" -ForegroundColor Cyan
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Action: --set
# ---------------------------------------------------------------------------

function Invoke-Set {
    param([string]$Assignment, [bool]$IsSystem)

    if ($Assignment -notmatch '^([^=]+)=(.*)$') {
        Write-Err '--set requires NAME=VALUE format.  Example: env --set MY_VAR=hello'
        return
    }

    $varName  = $Matches[1].Trim()
    $varValue = $Matches[2]
    $target   = if ($IsSystem) { 'Machine' } else { 'User' }
    $label    = if ($IsSystem) { 'System'  } else { 'User' }

    if (-not (Is-ValidVarName $varName)) {
        Write-Err "Invalid variable name '$varName'. Must start with a letter or underscore."
        return
    }

    $existing = [System.Environment]::GetEnvironmentVariable($varName, $target)

    if ($null -ne $existing) {
        Write-Host ''
        Write-Warn "Variable '$varName' already exists in $label scope."
        Write-Host "  Current  : $(Mask-Value $varName $existing)" -ForegroundColor DarkGray
        Write-Host "  New      : $(Mask-Value $varName $varValue)"  -ForegroundColor White
        Write-Host ''
        Write-Host '  Type YES to overwrite: ' -NoNewline -ForegroundColor Yellow
        $confirm = Read-Host
        if ($confirm -cne 'YES') {
            Write-Warn 'Set cancelled.'
            return
        }
    }

    try {
        [System.Environment]::SetEnvironmentVariable($varName, $varValue, $target)
        Write-Ok "Set $varName in $label scope."
    } catch {
        Write-Err "Failed to set variable: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Action: --delete
# ---------------------------------------------------------------------------

function Invoke-Delete {
    param([string]$Name, [bool]$IsSystem)

    if (-not $Name) { Write-Err '--delete requires a variable name.  Example: env --delete MY_VAR'; return }

    $target   = if ($IsSystem) { 'Machine' } else { 'User' }
    $label    = if ($IsSystem) { 'System'  } else { 'User' }
    $existing = [System.Environment]::GetEnvironmentVariable($Name, $target)

    if ($null -eq $existing) {
        Write-Warn "Variable '$Name' not found in $label scope."
        return
    }

    Write-Host ''
    Write-Warn "About to delete '$Name' from $label scope."
    Write-Host "  Value    : $(Mask-Value $Name $existing)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Type YES to confirm: ' -NoNewline -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -cne 'YES') { Write-Warn 'Delete cancelled.'; return }

    try {
        [System.Environment]::SetEnvironmentVariable($Name, $null, $target)
        Write-Ok "Deleted '$Name' from $label scope."
    } catch {
        Write-Err "Failed to delete variable: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Action: --temp
# ---------------------------------------------------------------------------

function Invoke-Temp {
    param([string]$Assignment)

    if ($Assignment -notmatch '^([^=]+)=(.*)$') {
        Write-Err '--temp requires NAME=VALUE format.  Example: env --temp MY_VAR=hello'
        return
    }

    $varName  = $Matches[1].Trim()
    $varValue = $Matches[2]

    if (-not (Is-ValidVarName $varName)) {
        Write-Err "Invalid variable name '$varName'."
        return
    }

    [System.Environment]::SetEnvironmentVariable($varName, $varValue)
    $env:_TEMP_PLACEHOLDER = $varValue   # forces the current session env block to refresh

    Write-Ok "Session variable set: $varName = $(Mask-Value $varName $varValue)"
    Write-Host "  (only affects this PowerShell session)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: --path
# ---------------------------------------------------------------------------

function Get-PathEntries ([string]$Target) {
    $raw = [System.Environment]::GetEnvironmentVariable('PATH', $Target)
    if (-not $raw) { return @() }
    return @($raw -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { $_.TrimEnd('\') })
}

function Set-PathEntries ([string[]]$Entries, [string]$Target) {
    $joined = ($Entries | Where-Object { $_ -ne '' }) -join ';'
    [System.Environment]::SetEnvironmentVariable('PATH', $joined, $Target)
}

function Write-PathEntries ([string[]]$Entries, [string]$Color, [System.Collections.Generic.HashSet[string]]$Seen) {
    foreach ($e in $Entries) {
        $isDup  = -not $Seen.Add($e)
        $exists = Test-Path $e
        if ($isDup) {
            Write-Host "    [DUP]      $e" -ForegroundColor Red
        } elseif (-not $exists) {
            Write-Host "    [MISSING]  $e" -ForegroundColor Yellow
        } else {
            Write-Host "    [OK]       $e" -ForegroundColor $Color
        }
    }
}

function Invoke-PathList {
    param([string]$Target = 'User')

    $showUser   = $Target -ne 'Machine'
    $showSystem = $Target -ne 'User'

    $userEntries   = if ($showUser)   { Get-PathEntries 'User'    } else { @() }
    $systemEntries = if ($showSystem) { Get-PathEntries 'Machine' } else { @() }

    $scopeLabel = if ($Target -eq 'User') { 'User' } elseif ($Target -eq 'Machine') { 'System' } else { 'All' }
    $total      = $userEntries.Count + $systemEntries.Count

    Write-Host ''
    Write-Host "  PATH entries  [$scopeLabel]" -ForegroundColor Cyan
    Write-Host '  ----------------------------------------------------' -ForegroundColor DarkGray

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($showUser) {
        Write-Host '  [User]' -ForegroundColor White
        Write-PathEntries $userEntries 'Green' $seen
    }
    if ($showSystem) {
        Write-Host '  [System]' -ForegroundColor White
        Write-PathEntries $systemEntries 'Gray' $seen
    }

    Write-Host ''
    Write-Host "  $total entries" -ForegroundColor DarkGray
}

function Invoke-PathGet {
    param([string]$Query, [string]$Target = 'User')

    if (-not $Query) { Write-Err '--path --get requires a search term.  Example: env --path --get Tools'; return }

    $showUser   = $Target -ne 'Machine'
    $showSystem = $Target -ne 'User'
    $found      = 0

    Write-Host ''
    Write-Host "  PATH search: '$Query'  [$( if ($Target -eq 'User') { 'User' } elseif ($Target -eq 'Machine') { 'System' } else { 'All' })]" -ForegroundColor Cyan
    Write-Host '  ----------------------------------------------------' -ForegroundColor DarkGray

    if ($showUser) {
        $hits = @(Get-PathEntries 'User' | Where-Object { $_ -like "*$Query*" })
        if ($hits.Count -gt 0) {
            Write-Host '  [User]' -ForegroundColor White
            foreach ($e in $hits) {
                $exists = Test-Path $e
                $color  = if ($exists) { 'Green' } else { 'Yellow' }
                Write-Host "    $e" -ForegroundColor $color
                $found++
            }
        }
    }
    if ($showSystem) {
        $hits = @(Get-PathEntries 'Machine' | Where-Object { $_ -like "*$Query*" })
        if ($hits.Count -gt 0) {
            Write-Host '  [System]' -ForegroundColor White
            foreach ($e in $hits) {
                $exists = Test-Path $e
                $color  = if ($exists) { 'Gray' } else { 'Yellow' }
                Write-Host "    $e" -ForegroundColor $color
                $found++
            }
        }
    }

    Write-Host ''
    if ($found -eq 0) {
        Write-Warn "No PATH entries matching '$Query' found."
    } else {
        Write-Host "  $found match(es)" -ForegroundColor DarkGray
    }
}

function Invoke-PathAdd {
    param([string[]]$Dirs, [string]$Target = 'User')

    if (-not $Dirs -or $Dirs.Count -eq 0) {
        Write-Err '--path --add requires at least one directory.  Example: env --path --add "C:\Tools"'
        return
    }

    $label   = if ($Target -eq 'Machine') { 'System' } else { 'User' }
    $entries = Get-PathEntries $Target
    $added   = 0

    foreach ($Dir in $Dirs) {
        $Dir = $Dir.TrimEnd('\')

        if (-not (Test-Path $Dir)) {
            Write-Warn "Directory does not exist: $Dir"
            Write-Host "  Add '$Dir' anyway? Type YES to confirm: " -NoNewline -ForegroundColor Yellow
            if ((Read-Host) -cne 'YES') { Write-Warn "Skipped: $Dir"; continue }
        }

        if ($entries | Where-Object { $_.TrimEnd('\') -ieq $Dir }) {
            Write-Warn "'$Dir' is already in the $label PATH."
            continue
        }

        $entries += $Dir
        Write-Ok "Added to $label PATH: $Dir"
        $added++
    }

    if ($added -gt 0) { Set-PathEntries $entries $Target }
}

function Invoke-PathRemove {
    param([string[]]$Dirs, [string]$Target = 'User')

    if (-not $Dirs -or $Dirs.Count -eq 0) {
        Write-Err '--path --remove requires at least one directory.  Example: env --path --remove "C:\Tools"'
        return
    }

    $label   = if ($Target -eq 'Machine') { 'System' } else { 'User' }
    $entries = Get-PathEntries $Target
    $removed = 0

    foreach ($Dir in $Dirs) {
        $Dir    = $Dir.TrimEnd('\')
        $before = $entries.Count
        $entries = @($entries | Where-Object { $_.TrimEnd('\') -ine $Dir })

        if ($entries.Count -eq $before) {
            Write-Warn "'$Dir' not found in the $label PATH."
        } else {
            Write-Ok "Removed from $label PATH: $Dir"
            $removed++
        }
    }

    if ($removed -gt 0) { Set-PathEntries $entries $Target }
}

# ---------------------------------------------------------------------------
# Action: --load
# ---------------------------------------------------------------------------

function Invoke-Load {
    param([string]$FilePath)

    if (-not $FilePath) { Write-Err '--load requires a file path.  Example: env --load .env'; return }

    if (-not (Test-Path $FilePath)) {
        Write-Err "File not found: $FilePath"
        return
    }

    $lines = Get-Content $FilePath
    $count = 0
    $skipped = 0

    Write-Host ''

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        if ($trimmed -notmatch '^([^=]+)=(.*)$') {
            Write-Warn "Skipping invalid line: $trimmed"
            $skipped++
            continue
        }

        $varName  = $Matches[1].Trim()
        $varValue = $Matches[2].Trim().Trim('"').Trim("'")

        if (-not (Is-ValidVarName $varName)) {
            Write-Warn "Skipping invalid name: $varName"
            $skipped++
            continue
        }

        $existing = [System.Environment]::GetEnvironmentVariable($varName, 'User')
        if ($null -ne $existing) {
            Write-Warn "Overwriting: $varName"
        }

        [System.Environment]::SetEnvironmentVariable($varName, $varValue, 'User')
        Write-Host "  [SET]  $varName = $(Mask-Value $varName $varValue)" -ForegroundColor Green
        $count++
    }

    Write-Host ''
    Write-Ok "Loaded $count variable(s) from '$FilePath'$(if ($skipped -gt 0) { " ($skipped skipped)" })."
}

# ---------------------------------------------------------------------------
# Action: --export
# ---------------------------------------------------------------------------

function Invoke-Export {
    param([string]$FilePath)

    if (-not $FilePath) { Write-Err '--export requires a file path.  Example: env --export .env'; return }

    if (Test-Path $FilePath) {
        Write-Warn "File already exists: $FilePath"
        Write-Host '  Overwrite? Type YES to confirm: ' -NoNewline -ForegroundColor Yellow
        if ((Read-Host) -cne 'YES') { Write-Warn 'Export cancelled.'; return }
    }

    $vars  = [System.Environment]::GetEnvironmentVariables('User')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Exported by pt env -- User scope')
    $lines.Add("# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')

    foreach ($key in ($vars.Keys | Sort-Object)) {
        $lines.Add("$key=$($vars[$key])")
    }

    $lines | Set-Content -Path $FilePath -Encoding UTF8
    Write-Ok "Exported $($vars.Count) variable(s) to '$FilePath'."
}

# ---------------------------------------------------------------------------
# Action: --profile
# ---------------------------------------------------------------------------

function Invoke-Profile {
    param([string]$ProfileName)

    if (-not $ProfileName) {
        # List available profiles
        $dir = Get-ProfileDir
        if (-not (Test-Path $dir)) {
            Write-Info 'No profiles directory found.'
            Write-Host "  Expected: $dir" -ForegroundColor DarkGray
            Write-Host "  Create a profile with a JSON file in that directory." -ForegroundColor DarkGray
            return
        }

        $files = @(Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            Write-Info 'No profiles found.'
            Write-Host "  Add JSON files to: $dir" -ForegroundColor DarkGray
            return
        }

        Write-Host ''
        Write-Host '  Available profiles:' -ForegroundColor Cyan
        foreach ($f in $files) {
            Write-Host "    $($f.BaseName)   ($($f.FullName))" -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host "  Usage: env --profile <name>" -ForegroundColor DarkGray
        return
    }

    $dir  = Get-ProfileDir
    $file = Join-Path $dir "$ProfileName.json"

    if (-not (Test-Path $file)) {
        Write-Err "Profile '$ProfileName' not found."
        Write-Host "  Expected: $file" -ForegroundColor DarkGray

        $available = @(Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        if ($available.Count -gt 0) {
            Write-Host '  Available: ' -NoNewline -ForegroundColor DarkGray
            Write-Host ($available.BaseName -join ', ') -ForegroundColor Cyan
        }
        return
    }

    try {
        $profileData = Get-Content $file -Raw | ConvertFrom-Json
    } catch {
        Write-Err "Failed to parse profile '$ProfileName': $($_.Exception.Message)"
        return
    }

    $props = $profileData.PSObject.Properties
    if ($props.Count -eq 0) {
        Write-Warn "Profile '$ProfileName' is empty."
        return
    }

    Write-Host ''
    Write-Host "  Applying profile: $ProfileName" -ForegroundColor Cyan
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray

    $count = 0
    foreach ($prop in $props) {
        $varName  = $prop.Name
        $varValue = [string]$prop.Value

        if (-not (Is-ValidVarName $varName)) {
            Write-Warn "Skipping invalid name: $varName"
            continue
        }

        [System.Environment]::SetEnvironmentVariable($varName, $varValue, 'User')
        Write-Host "  [SET]  $varName = $(Mask-Value $varName $varValue)" -ForegroundColor Green
        $count++
    }

    Write-Host ''
    Write-Ok "Applied $count variable(s) from profile '$ProfileName'."
}

# ---------------------------------------------------------------------------
# Action: --generate
# ---------------------------------------------------------------------------

$ENV_TEMPLATES = @{
    node   = @(
        '# Node.js environment',
        'NODE_ENV=development',
        'PORT=3000',
        'HOST=localhost',
        '',
        '# Database',
        'DATABASE_URL=postgresql://user:password@localhost:5432/mydb',
        '',
        '# Auth',
        'JWT_SECRET=changeme',
        'SESSION_SECRET=changeme',
        '',
        '# API Keys',
        'API_KEY=',
        'API_URL=https://api.example.com'
    )
    python = @(
        '# Python environment',
        'FLASK_ENV=development',
        'FLASK_APP=app.py',
        'DEBUG=true',
        'PORT=5000',
        '',
        '# Database',
        'DATABASE_URL=postgresql://user:password@localhost:5432/mydb',
        '',
        '# Auth',
        'SECRET_KEY=changeme',
        '',
        '# API Keys',
        'API_KEY=',
        'API_URL=https://api.example.com'
    )
    dotnet = @(
        '# .NET environment',
        'ASPNETCORE_ENVIRONMENT=Development',
        'ASPNETCORE_URLS=https://localhost:5001;http://localhost:5000',
        '',
        '# Database',
        'ConnectionStrings__Default=Server=localhost;Database=mydb;User Id=sa;Password=changeme;',
        '',
        '# Auth',
        'Jwt__Key=changeme',
        'Jwt__Issuer=https://localhost:5001',
        '',
        '# Logging',
        'Logging__LogLevel__Default=Information'
    )
}

function Invoke-Generate {
    param([string]$Template)

    $known = $ENV_TEMPLATES.Keys -join ', '

    if (-not $Template) {
        Write-Err "--generate requires a template name.  Known: $known"
        return
    }

    if (-not $ENV_TEMPLATES.ContainsKey($Template.ToLower())) {
        Write-Err "Unknown template '$Template'.  Known: $known"
        return
    }

    $outFile = '.env'
    if (Test-Path $outFile) {
        Write-Warn "'.env' already exists in the current directory."
        Write-Host '  Overwrite? Type YES to confirm: ' -NoNewline -ForegroundColor Yellow
        if ((Read-Host) -cne 'YES') { Write-Warn 'Generate cancelled.'; return }
    }

    $ENV_TEMPLATES[$Template.ToLower()] | Set-Content -Path $outFile -Encoding UTF8
    Write-Ok "Generated '$outFile' from template '$Template'."
    Write-Host "  Edit the file and run 'pt env --load .env' to apply." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

function Show-Usage {
    Write-Host ''
    Write-Host '  EnvManager -- environment variable manager' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  USAGE' -ForegroundColor White
    Write-Host '    env --list [--user | --system] [--json]    list all variables' -ForegroundColor Gray
    Write-Host '    env --get <NAME>                           show a variable'     -ForegroundColor Gray
    Write-Host '    env --set NAME=VALUE [--system]            set a variable'      -ForegroundColor Gray
    Write-Host '    env --delete <NAME> [--system]             delete a variable'   -ForegroundColor Gray
    Write-Host '    env --temp NAME=VALUE                      set session-only variable' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    env --path --list [--user | --system]      show PATH entries (default: user)'     -ForegroundColor Gray
    Write-Host '    env --path --get <term> [--user|--system]  search PATH entries by name'          -ForegroundColor Gray
    Write-Host '    env --path --add "C:\A" "C:\B" [--system]   add directories to PATH (default: user)' -ForegroundColor Gray
    Write-Host '    env --path --remove "C:\A" "C:\B" [--system] remove directories from PATH'       -ForegroundColor Gray
    Write-Host ''
    Write-Host '    env --load <file.env>                      load variables from .env file'      -ForegroundColor Gray
    Write-Host '    env --export <file.env>                    export User variables to .env file' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    env --profile                              list available profiles'  -ForegroundColor Gray
    Write-Host '    env --profile <name>                       apply a named profile'    -ForegroundColor Gray
    Write-Host ''
    Write-Host '    env --generate node | python | dotnet      generate a starter .env'  -ForegroundColor Gray
    Write-Host ''
    Write-Host '  SENSITIVE MASKING' -ForegroundColor White
    Write-Host '    Values are masked when name contains: KEY, SECRET, TOKEN, PASSWORD' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  PROFILES' -ForegroundColor White
    Write-Host "    Store JSON files in: <install-dir>\env-profiles\<name>.json" -ForegroundColor DarkGray
    Write-Host '    Format: { "VAR_NAME": "value", ... }' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

if ($Path) {
    # $Path is checked first so --path --list / --path --get don't fall into the
    # top-level $List / $Get branches.
    $pathTarget = if ($System) { 'Machine' } else { 'User' }
    if     ($Get)    { Invoke-PathGet    -Query $Values[0] -Target $pathTarget }
    elseif ($Add)    { Invoke-PathAdd    -Dirs  $Values    -Target $pathTarget }
    elseif ($Remove) { Invoke-PathRemove -Dirs  $Values    -Target $pathTarget }
    else             { Invoke-PathList   -Target $pathTarget }
}
elseif ($List) {
    $scope = if ($User) { 'User' } elseif ($System) { 'Machine' } else { '' }
    Invoke-List -Scope $scope -AsJson ([bool]$Json)
}
elseif ($Get) {
    Invoke-Get -Name $Values[0]
}
elseif ($Set) {
    Invoke-Set -Assignment $Values[0] -IsSystem ([bool]$System)
}
elseif ($Delete) {
    Invoke-Delete -Name $Values[0] -IsSystem ([bool]$System)
}
elseif ($Temp) {
    Invoke-Temp -Assignment $Values[0]
}
elseif ($Load) {
    Invoke-Load -FilePath $Values[0]
}
elseif ($Export) {
    Invoke-Export -FilePath $Values[0]
}
elseif ($Profile) {
    Invoke-Profile -ProfileName $Values[0]
}
elseif ($Generate) {
    Invoke-Generate -Template $Values[0]
}
else {
    Show-Usage
}
