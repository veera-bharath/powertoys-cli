<#
.SYNOPSIS
    JSON -- format, minify, validate, query, and patch JSON files.

    json format   <file.json>
    json minify   <file.json>
    json validate <file.json>
    json query    <file.json> <key.path>
    json set      <file.json> <key.path> <value>
    cat file.json | json query <key.path>
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$Operation = '',
    [Parameter(Position=1)] [string]$Arg1 = '',
    [Parameter(Position=2)] [string]$Arg2 = '',
    [Parameter(Position=3)] [string]$Arg3 = ''
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Ok   ([string]$m) { Write-Host "  [OK]  $m" -ForegroundColor Green  }
function Write-Err  ([string]$m) { Write-Host "  [ERR] $m" -ForegroundColor Red    }
function Write-Info ([string]$m) { Write-Host "  [..]  $m" -ForegroundColor Cyan   }
function Write-Warn ([string]$m) { Write-Host "  [!!]  $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Stdin detection
#
# [Console]::IsInputRedirected is true in any non-interactive spawned shell
# (not just real pipes), so we guard the blocking ReadToEnd() call with a
# file-presence check: if Arg1 looks like a JSON file or resolves to an
# existing path, we use it as a file and skip stdin entirely.
# ---------------------------------------------------------------------------

$looksLikeFile = $Arg1 -and (
    $Arg1 -match '\.(json|jsonc|json5)$' -or
    [System.IO.File]::Exists([System.IO.Path]::GetFullPath($Arg1))
)

$isStdin  = [Console]::IsInputRedirected -and -not $looksLikeFile
$stdinRaw = ''
if ($isStdin) { $stdinRaw = [Console]::In.ReadToEnd() }

# Positional arg meaning shifts when stdin is active
if ($isStdin) {
    $FilePath = ''
    $QueryKey = $Arg1
    $SetValue = $Arg2
} else {
    $FilePath = $Arg1
    $QueryKey = $Arg2
    $SetValue = $Arg3
}

# ---------------------------------------------------------------------------
# Read-Json -- parse JSON from file or stdin; exits on any error
# ---------------------------------------------------------------------------

function Read-Json {
    param([string]$Path, [string]$Stdin)

    [string]$raw = ''
    if ($Stdin) {
        $raw = $Stdin
    } else {
        if (-not $Path) {
            Write-Err "No file specified. Usage: pt json <op> <file.json>"
            exit 1
        }
        $full = [System.IO.Path]::GetFullPath($Path)
        if (-not [System.IO.File]::Exists($full)) {
            Write-Err "File not found: $full"
            exit 1
        }
        $raw = [System.IO.File]::ReadAllText($full)
    }

    if (-not $raw.Trim()) {
        Write-Err "Input is empty."
        exit 1
    }

    try {
        $obj = $raw | ConvertFrom-Json
        return $obj
    } catch {
        Write-Err "Invalid JSON -- $($_.Exception.Message)"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Write-Json -- serialise and overwrite a file
# ---------------------------------------------------------------------------

function Write-Json {
    param([object]$Data, [string]$Path, [switch]$Compress)

    $output = if ($Compress) {
        $Data | ConvertTo-Json -Depth 20 -Compress
    } else {
        $Data | ConvertTo-Json -Depth 20
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $output | Set-Content -Path $full -Encoding utf8
}

# ---------------------------------------------------------------------------
# Query-Json -- dot-notation traversal; returns {Found, Value}
# ---------------------------------------------------------------------------

function Query-Json {
    param([object]$Data, [string]$Path)

    $parts   = $Path -split '\.'
    $current = $Data

    foreach ($part in $parts) {
        if ($null -eq $current) {
            return [PSCustomObject]@{ Found = $false; Value = $null }
        }

        if ($part -match '^\d+$') {
            $idx = [int]$part
            $len = try {
                if ($current -is [System.Array]) { $current.Length } else { $current.Count }
            } catch { 0 }

            if ($idx -ge $len) {
                return [PSCustomObject]@{ Found = $false; Value = $null }
            }
            $current = $current[$idx]
        } else {
            $prop = $current.PSObject.Properties[$part]
            if ($null -eq $prop) {
                return [PSCustomObject]@{ Found = $false; Value = $null }
            }
            $current = $prop.Value
        }
    }

    return [PSCustomObject]@{ Found = $true; Value = $current }
}

# ---------------------------------------------------------------------------
# Set-JsonValue -- dot-notation write; modifies $Data in place
# ---------------------------------------------------------------------------

function Set-JsonValue {
    param([object]$Data, [string]$Path, [string]$RawValue)

    # Coerce to the most specific type that fits the raw string.
    # JSON arrays/objects are handled before the switch because PS5.1 enumerates
    # ConvertFrom-Json output through the pipeline -- @() captures it correctly,
    # and we distinguish array vs object by the leading character.
    $trimmed = $RawValue.Trim()
    $typed   = $null
    $handled = $false

    if ($trimmed -match '^\[' -or $trimmed -match '^\{') {
        try {
            $parsed = $RawValue | ConvertFrom-Json
            # ConvertFrom-Json returns a PS-decorated Object[] that ConvertTo-Json
            # misserializes as {value,Count}. Casting to [object[]] strips the extra
            # members. Assignment must be a statement (not an if-expression) so that
            # an empty array is not lost in the PS pipeline before capture.
            if ($trimmed[0] -eq '[') { $typed = [object[]]$parsed } else { $typed = $parsed }
            $handled = $true
        } catch {}
    }

    if (-not $handled) {
        $typed = switch -Regex ($RawValue) {
            '^true$'       { $true;             break }
            '^false$'      { $false;            break }
            '^null$'       { $null;             break }
            '^-?\d+$'      { [long]$RawValue;   break }
            '^-?\d+\.\d+$' { [double]$RawValue; break }
            default        { $RawValue }
        }
    }

    $parts   = $Path -split '\.'
    $current = $Data

    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $part = $parts[$i]
        if ($part -match '^\d+$') {
            $idx = [int]$part
            try { $current = $current[$idx] } catch {
                Write-Err "Cannot traverse array index $idx in path '$Path'."
                exit 1
            }
        } else {
            $prop = $current.PSObject.Properties[$part]
            if ($null -eq $prop) {
                # Create intermediate node
                $node = [PSCustomObject]@{}
                $current | Add-Member -NotePropertyName $part -NotePropertyValue $node -Force
                $current = $node
            } else {
                $current = $prop.Value
            }
        }
    }

    $leaf = $parts[-1]
    if ($leaf -match '^\d+$') {
        $idx = [int]$leaf
        try { $current[$idx] = $typed } catch {
            Write-Err "Cannot set array index $idx -- out of bounds or read-only."
            exit 1
        }
    } else {
        $current | Add-Member -NotePropertyName $leaf -NotePropertyValue $typed -Force
    }
}

# ---------------------------------------------------------------------------
# Format-Value -- render a query result to stdout
# ---------------------------------------------------------------------------

function Format-Value {
    param([object]$Val)

    if ($null -eq $Val)         { Write-Output 'null';                            return }
    if ($Val -is [string])      { Write-Output $Val;                              return }
    if ($Val -is [bool])        { Write-Output $Val.ToString().ToLower();         return }
    if ($Val -is [ValueType])   { Write-Output "$Val";                            return }
    Write-Output ($Val | ConvertTo-Json -Depth 20)
}

# ---------------------------------------------------------------------------
# Operation handlers
# ---------------------------------------------------------------------------

function Invoke-Format {
    $data = Read-Json -Path $FilePath -Stdin $stdinRaw
    Write-Output ($data | ConvertTo-Json -Depth 20)
}

function Invoke-Minify {
    $data = Read-Json -Path $FilePath -Stdin $stdinRaw
    Write-Output ($data | ConvertTo-Json -Depth 20 -Compress)
}

function Invoke-Validate {
    $raw = ''
    if ($isStdin) {
        $raw = $stdinRaw
    } else {
        if (-not $FilePath) {
            Write-Err "No file specified."
            exit 1
        }
        $full = [System.IO.Path]::GetFullPath($FilePath)
        if (-not [System.IO.File]::Exists($full)) {
            Write-Err "File not found: $full"
            exit 1
        }
        $raw = [System.IO.File]::ReadAllText($full)
    }

    if (-not $raw.Trim()) {
        Write-Err "Input is empty."
        exit 1
    }

    try {
        $raw | ConvertFrom-Json | Out-Null
        $label = if ($isStdin) { 'stdin' } else { [System.IO.Path]::GetFileName($FilePath) }
        Write-Ok "Valid JSON  ($label)"
    } catch {
        Write-Err "Invalid JSON -- $($_.Exception.Message)"
        exit 1
    }
}

function Invoke-Query {
    if (-not $QueryKey) {
        Write-Err "No key path specified. Usage: pt json query <file.json> <key.path>"
        exit 1
    }

    $data = Read-Json -Path $FilePath -Stdin $stdinRaw
    $qr   = Query-Json -Data $data -Path $QueryKey

    if (-not $qr.Found) {
        Write-Warn "Key not found: $QueryKey"
        exit 1
    }

    Format-Value -Val $qr.Value
}

function Invoke-Set {
    if (-not $QueryKey) {
        Write-Err "No key path specified. Usage: pt json set <file.json> <key.path> <value>"
        exit 1
    }

    if ($isStdin) {
        $data = Read-Json -Path '' -Stdin $stdinRaw
        Set-JsonValue -Data $data -Path $QueryKey -RawValue $SetValue
        Write-Output ($data | ConvertTo-Json -Depth 20)
    } else {
        if (-not $FilePath) {
            Write-Err "No file specified."
            exit 1
        }
        $data = Read-Json -Path $FilePath -Stdin ''
        Set-JsonValue -Data $data -Path $QueryKey -RawValue $SetValue
        Write-Json -Data $data -Path $FilePath
        $label = [System.IO.Path]::GetFileName($FilePath)
        Write-Ok "Saved $label  -- set $QueryKey = $SetValue"
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "  JSON utility -- format, minify, validate, query, and patch JSON." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  pt json format   <file.json>                     pretty-print"
    Write-Host "  pt json minify   <file.json>                     compact single line"
    Write-Host "  pt json validate <file.json>                     check syntax"
    Write-Host "  pt json query    <file.json> <key.path>          extract a value"
    Write-Host "  pt json set      <file.json> <key.path> <value>  update a value in place"
    Write-Host ""
    Write-Host "  Pipe support (stdin replaces the file argument):"
    Write-Host "    cat file.json | pt json format"
    Write-Host "    cat file.json | pt json query user.address.city"
    Write-Host "    cat file.json | pt json set user.name John"
    Write-Host ""
    Write-Host "  Dot-path examples:"
    Write-Host "    user.name           string or object property"
    Write-Host "    items.0.title       first element of an array"
    Write-Host "    config.flags.2      third element of a nested array"
    Write-Host ""
    Write-Host "  Value coercion for 'set':"
    Write-Host "    true / false        boolean"
    Write-Host "    null                JSON null"
    Write-Host "    42 / 3.14           number"
    Write-Host "    anything else       string"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

switch ($Operation.ToLower()) {
    'format'   { Invoke-Format   }
    'minify'   { Invoke-Minify   }
    'validate' { Invoke-Validate }
    'query'    { Invoke-Query    }
    'set'      { Invoke-Set      }
    ''         { Show-Usage; exit 0 }
    default    {
        Write-Err "Unknown operation: '$Operation'. Valid: format, minify, validate, query, set"
        Show-Usage
        exit 1
    }
}
