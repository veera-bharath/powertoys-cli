<#
.SYNOPSIS
    Run -- execute predefined workflow scripts from .pt.json or pt.config.json.

    run <workflow>                 execute a named workflow
    run <workflow> --dry           preview steps without executing
    run <workflow> --continue      continue even if a step fails
    run <workflow> --env <name>    apply environment profile first
    run --list                     list available workflows
    run --list --jsonout           list workflows as JSON
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$ScriptName = '',

    [switch]$Dry,
    [switch]$Continue,

    [string]$Env = '',

    [switch]$List,
    [switch]$Jsonout
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Ok   ([string]$m) { Write-Host "  [OK]  $m" -ForegroundColor Green    }
function Write-Err  ([string]$m) { Write-Host "  [ERR] $m" -ForegroundColor Red      }
function Write-Info ([string]$m) { Write-Host "  [..]  $m" -ForegroundColor Cyan     }
function Write-Warn ([string]$m) { Write-Host "  [!!]  $m" -ForegroundColor Yellow   }
function Write-Step ([string]$m) { Write-Host "  [>>]  $m" -ForegroundColor Yellow   }
function Write-Skip ([string]$m) { Write-Host "  [--]  $m" -ForegroundColor DarkGray }
function Write-Para ([string]$m) { Write-Host "  [||]  $m" -ForegroundColor Cyan     }
function Write-Rule  { Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }

function Clip([string]$s, [int]$w) {
    if ($null -eq $s -or $s.Length -eq 0) { return ''.PadRight($w) }
    if ($s.Length -gt $w) { return $s.Substring(0, $w - 2) + '..' }
    return $s.PadRight($w)
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

function Load-Config {
    # Priority 1: .pt.json in the current working directory
    $localPath = Join-Path (Get-Location).Path '.pt.json'
    if (Test-Path $localPath) {
        try {
            $obj = Get-Content $localPath -Raw | ConvertFrom-Json
            if ($obj.scripts) {
                return [PSCustomObject]@{ Source = $localPath; Data = $obj }
            }
        } catch {
            Write-Err "Failed to parse .pt.json: $_"
            exit 1
        }
    }

    # Priority 2: pt.config.json in the install directory (alongside pt.ps1)
    $globalPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\pt.config.json'))
    if (Test-Path $globalPath) {
        try {
            $obj = Get-Content $globalPath -Raw | ConvertFrom-Json
            if ($obj.scripts) {
                return [PSCustomObject]@{ Source = $globalPath; Data = $obj }
            }
        } catch {
            Write-Err "Failed to parse pt.config.json: $_"
            exit 1
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Step normalization
# ---------------------------------------------------------------------------

function Resolve-Step ([object]$raw) {
    if ($raw -is [string]) {
        return [PSCustomObject]@{ Kind = 'single'; Cmd = $raw; Condition = $null; Timeout = 0 }
    }

    # Parallel block: { "parallel": ["cmd1", "cmd2"] }
    if ($null -ne $raw.parallel) {
        return [PSCustomObject]@{
            Kind     = 'parallel'
            Commands = @($raw.parallel)
            Timeout  = if ($null -ne $raw.timeout) { [int]$raw.timeout } else { 0 }
        }
    }

    # Object step: { "cmd": "...", "if": "...", "timeout": 30 }
    if ($null -ne $raw.cmd) {
        $cond = $raw.PSObject.Properties['if']
        return [PSCustomObject]@{
            Kind      = 'single'
            Cmd       = [string]$raw.cmd
            Condition = if ($null -ne $cond) { [string]$cond.Value } else { $null }
            Timeout   = if ($null -ne $raw.timeout) { [int]$raw.timeout } else { 0 }
        }
    }

    Write-Warn "Unrecognized step format -- skipping."
    return $null
}

# ---------------------------------------------------------------------------
# Condition evaluation
# ---------------------------------------------------------------------------

function Test-Condition ([string]$condition) {
    if (-not $condition) { return $true }

    $c = $condition.Trim()

    # "node_modules missing" shorthand
    if ($c -ieq 'node_modules missing') {
        return -not (Test-Path 'node_modules' -PathType Container)
    }

    # "dir missing: <path>"
    if ($c -imatch '^dir missing:\s*(.+)$') {
        return -not (Test-Path $Matches[1].Trim() -PathType Container)
    }

    # "file missing: <path>"
    if ($c -imatch '^file missing:\s*(.+)$') {
        return -not (Test-Path $Matches[1].Trim() -PathType Leaf)
    }

    # "env: <VAR>" -- true when the variable IS set
    if ($c -imatch '^env:\s*(.+)$') {
        return ($null -ne [System.Environment]::GetEnvironmentVariable($Matches[1].Trim()))
    }

    # "env missing: <VAR>" -- true when the variable is NOT set
    if ($c -imatch '^env missing:\s*(.+)$') {
        return ($null -eq [System.Environment]::GetEnvironmentVariable($Matches[1].Trim()))
    }

    Write-Warn "Unknown condition '$condition' -- step will run."
    return $true
}

# ---------------------------------------------------------------------------
# Single step execution
# ---------------------------------------------------------------------------

function Invoke-Step {
    param(
        [string]$Cmd,
        [int]$Timeout = 0,
        [bool]$IsDry  = $false
    )

    Write-Step "Running: $Cmd"

    if ($IsDry) {
        Write-Skip "(dry run -- not executed)"
        return 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Timeout -gt 0) {
        $cwd = (Get-Location).Path
        $job = Start-Job -ScriptBlock {
            param($cmd, $dir)
            Set-Location $dir
            Invoke-Expression $cmd
            $LASTEXITCODE
        } -ArgumentList $Cmd, $cwd

        $done = Wait-Job $job -Timeout $Timeout
        if (-not $done) {
            Stop-Job  $job | Out-Null
            Remove-Job $job | Out-Null
            $sw.Stop()
            Write-Err "Timed out after ${Timeout}s: $Cmd"
            return 1
        }

        $output = Receive-Job $job
        Remove-Job $job | Out-Null

        # Last item in output is the exit code integer
        $exitCode = 0
        if ($output -is [System.Array] -and $output.Count -gt 0) {
            $last = $output[-1]
            if ($last -is [int]) { $exitCode = $last }
            $output[0..($output.Count - 2)] | ForEach-Object { Write-Host $_ }
        } elseif ($output -is [int]) {
            $exitCode = $output
        }

        $sw.Stop()
        $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

        if ($exitCode -eq 0) { Write-Ok "Success (${elapsed}s)" }
        else                  { Write-Err "Failed with exit $exitCode (${elapsed}s)" }
        return $exitCode
    }

    # No timeout: run inline so stdout/stderr stream in real-time.
    # Pipe to Out-Host to prevent stdout leaking into the function's return stream.
    # Reset LASTEXITCODE first -- cmdlets don't update it, so stale values bleed through.
    $global:LASTEXITCODE = 0
    Invoke-Expression $Cmd | Out-Host
    $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 0 }

    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($exitCode -eq 0) { Write-Ok "Success (${elapsed}s)" }
    else                  { Write-Err "Failed with exit $exitCode (${elapsed}s)" }

    return $exitCode
}

# ---------------------------------------------------------------------------
# Parallel step execution
# ---------------------------------------------------------------------------

function Invoke-Parallel {
    param(
        [string[]]$Commands,
        [int]$Timeout = 0,
        [bool]$IsDry  = $false
    )

    Write-Para "Parallel group ($($Commands.Count) commands):"
    foreach ($c in $Commands) {
        Write-Host "         $c" -ForegroundColor DarkCyan
    }

    if ($IsDry) {
        Write-Skip "(dry run -- not executed)"
        return 0
    }

    $cwd  = (Get-Location).Path
    $jobs = [System.Collections.Generic.List[object]]::new()

    foreach ($c in $Commands) {
        $j = Start-Job -ScriptBlock {
            param($cmd, $dir)
            Set-Location $dir
            $out = Invoke-Expression $cmd 2>&1 | Out-String
            [PSCustomObject]@{ Cmd = $cmd; Output = $out.Trim(); ExitCode = $LASTEXITCODE }
        } -ArgumentList $c, $cwd
        $jobs.Add([PSCustomObject]@{ Job = $j; Cmd = $c })
    }

    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $allGood = $true

    foreach ($entry in $jobs) {
        $remaining = if ($Timeout -gt 0) { $Timeout - [int]$sw.Elapsed.TotalSeconds } else { -1 }

        if ($remaining -eq 0) {
            Stop-Job  $entry.Job | Out-Null
            Remove-Job $entry.Job | Out-Null
            Write-Err "Timed out: $($entry.Cmd)"
            $allGood = $false
            continue
        }

        $done = if ($remaining -gt 0) { Wait-Job $entry.Job -Timeout $remaining }
                else                   { Wait-Job $entry.Job }

        if (-not $done) {
            Stop-Job  $entry.Job | Out-Null
            Remove-Job $entry.Job | Out-Null
            Write-Err "Timed out: $($entry.Cmd)"
            $allGood = $false
            continue
        }

        $result = Receive-Job $entry.Job
        Remove-Job $entry.Job | Out-Null

        if ($result -and $result.Output) {
            Write-Host ""
            Write-Host "  --- $($result.Cmd) ---" -ForegroundColor DarkGray
            Write-Host $result.Output -ForegroundColor DarkGray
        }

        if ($result -and $result.ExitCode -eq 0) {
            Write-Ok "Done: $($entry.Cmd)"
        } else {
            $code = if ($result) { $result.ExitCode } else { 1 }
            Write-Err "Failed (exit $code): $($entry.Cmd)"
            $allGood = $false
        }
    }

    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($allGood) { Write-Ok  "Parallel group complete (${elapsed}s)" }
    else          { Write-Err "Parallel group had failures (${elapsed}s)" }

    return $(if ($allGood) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# Workflow runner
# ---------------------------------------------------------------------------

function Invoke-Workflow {
    param(
        [string]$Name,
        [object[]]$Steps,
        [bool]$IsDry,
        [bool]$KeepGoing
    )

    Write-Blank
    Write-Host "  Workflow: $Name" -ForegroundColor Cyan
    if ($IsDry) { Write-Host "  (dry run)" -ForegroundColor DarkYellow }
    Write-Rule

    $total     = $Steps.Count
    $idx       = 0
    $failCount = 0

    foreach ($raw in $Steps) {
        $idx++
        $step = Resolve-Step $raw
        if ($null -eq $step) { continue }

        Write-Blank
        Write-Host "  Step $idx / $total" -ForegroundColor DarkGray

        if ($step.Kind -eq 'parallel') {
            $code = Invoke-Parallel -Commands $step.Commands -Timeout $step.Timeout -IsDry $IsDry
        } else {
            if (-not (Test-Condition $step.Condition)) {
                Write-Skip "Condition not met, skipping: $($step.Cmd)"
                continue
            }
            $code = Invoke-Step -Cmd $step.Cmd -Timeout $step.Timeout -IsDry $IsDry
        }

        if ($code -ne 0) {
            $failCount++
            if (-not $KeepGoing) {
                Write-Blank
                Write-Err "Workflow '$Name' stopped at step $idx. Use --continue to ignore failures."
                Write-Blank
                return $false
            }
        }
    }

    Write-Blank
    Write-Rule

    if ($failCount -eq 0) {
        Write-Ok "Workflow '$Name' completed successfully ($total step(s))."
    } else {
        Write-Warn "Workflow '$Name' finished with $failCount failure(s) out of $total step(s)."
    }

    Write-Blank
    return ($failCount -eq 0)
}

# ---------------------------------------------------------------------------
# Workflow listing
# ---------------------------------------------------------------------------

function Show-Workflows {
    param([object]$Data, [string]$Source, [bool]$AsJson)

    $names = @($Data.scripts | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object)

    if ($AsJson) {
        $out = @($names | ForEach-Object {
            $steps = @($Data.scripts.$_)
            [PSCustomObject]@{ name = $_; stepCount = $steps.Count }
        })
        Write-Output ($out | ConvertTo-Json -Depth 2)
        return
    }

    Write-Blank
    Write-Host "  Workflows  [config: $Source]" -ForegroundColor Cyan
    Write-Rule

    if ($names.Count -eq 0) {
        Write-Warn "No workflows defined."
        Write-Blank
        return
    }

    foreach ($n in $names) {
        $steps = @($Data.scripts.$n)
        Write-Host ("    {0,-28} {1} step(s)" -f $n, $steps.Count) -ForegroundColor Gray
    }

    Write-Blank
    Write-Host "  Run with: pt run <workflow>" -ForegroundColor DarkGray
    Write-Blank
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$cfg = Load-Config

if ($List) {
    if (-not $cfg) {
        Write-Blank
        Write-Warn "No config found. Create .pt.json in your project or pt.config.json in the install directory."
        Write-Blank
        exit 0
    }
    Show-Workflows -Data $cfg.Data -Source $cfg.Source -AsJson $Jsonout.IsPresent
    exit 0
}

if (-not $ScriptName) {
    Write-Blank
    Write-Err "Usage: pt run <workflow> [--dry] [--continue] [--env <profile>]"
    Write-Blank
    Write-Host "  pt run --list    show available workflows" -ForegroundColor DarkGray
    Write-Blank
    exit 1
}

if (-not $cfg) {
    Write-Blank
    Write-Err "No config found. Create .pt.json in your project or pt.config.json in the install directory."
    Write-Blank
    Write-Host "  Example .pt.json:" -ForegroundColor DarkGray
    Write-Host '  { "scripts": { "dev": ["npm install", "npm run dev"] } }' -ForegroundColor DarkGray
    Write-Blank
    exit 1
}

$workflow = $cfg.Data.scripts.$ScriptName

if ($null -eq $workflow) {
    Write-Blank
    Write-Err "Workflow '$ScriptName' not found in $($cfg.Source)"
    Write-Blank
    $available = @($cfg.Data.scripts | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object)
    if ($available.Count -gt 0) {
        Write-Host "  Available workflows:" -ForegroundColor Yellow
        foreach ($n in $available) { Write-Host "    pt run $n" -ForegroundColor Cyan }
    }
    Write-Blank
    exit 1
}

# Apply environment profile before running
if ($Env) {
    $ptScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\pt.ps1'))
    if (Test-Path $ptScript) {
        Write-Info "Applying environment profile: $Env"
        & $ptScript env --profile $Env
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to apply environment profile '$Env'."
            exit 1
        }
    } else {
        Write-Warn "pt.ps1 not found -- cannot apply environment profile '$Env'."
    }
}

$steps = @($workflow)
$ok    = Invoke-Workflow -Name $ScriptName -Steps $steps -IsDry $Dry.IsPresent -KeepGoing $Continue.IsPresent

exit $(if ($ok) { 0 } else { 1 })
