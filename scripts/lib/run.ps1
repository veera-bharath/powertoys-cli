<#
.SYNOPSIS
    Run -- execute predefined workflow scripts from run.config.json or pt.config.json.

    run <workflow>                              execute a named workflow
    run <workflow> --dry                        preview steps without executing
    run <workflow> --continue                   continue even if a step fails
    run <workflow> --env <name>                 apply environment profile first
    run <workflow> --list                       show all steps in the workflow
    run <workflow> --edit                       interactively edit or remove steps
    run <workflow> --remove <n>                 remove step number n (1-indexed)
    run --list                                  list all available workflows
    run --list --jsonout                        list workflows as JSON
    run --create <name>                         create a new workflow in run.config.json
    run <workflow> --add --cmd "..."            add a step
    run <workflow> --add --cmd "..." --cond "node_modules missing" --timeout 30 --retry 2
    run <workflow> --add --parallel "cmd1,cmd2,cmd3"

    Config files: run.config.json (project) or pt.config.json (global install dir)
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$ScriptName = '',

    # Execution
    [switch]$Dry,
    [switch]$Continue,
    [string]$Env = '',

    # List / inspect
    [switch]$List,
    [switch]$Jsonout,

    # Workflow creation
    [switch]$Create,

    # Step addition
    [switch]$Add,
    [string]$Cmd            = '',
    [string]$Cond           = '',
    [int]$Timeout           = 0,
    [int]$Retry             = 0,
    [string]$Parallel       = '',

    # Step editing
    [switch]$Edit,
    [int]$Remove            = 0
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
# Config loading and saving
# ---------------------------------------------------------------------------

function Load-Config {
    # Priority 1: run.config.json in the current working directory
    $localPath = Join-Path (Get-Location).Path 'run.config.json'
    if (Test-Path $localPath) {
        try {
            $obj = Get-Content $localPath -Raw | ConvertFrom-Json
            if ($obj.scripts) {
                return [PSCustomObject]@{ Source = $localPath; Data = $obj }
            }
        } catch {
            Write-Err "Failed to parse run.config.json: $_"
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

function Save-Config ([PSCustomObject]$cfg) {
    $cfg.Data | ConvertTo-Json -Depth 10 | Set-Content $cfg.Source -Encoding utf8
}

function New-LocalConfig {
    $path = Join-Path (Get-Location).Path 'run.config.json'
    $obj  = [PSCustomObject]@{ scripts = [PSCustomObject]@{} }
    $obj  | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding utf8
    return [PSCustomObject]@{ Source = $path; Data = $obj }
}

# ---------------------------------------------------------------------------
# Step normalization
# ---------------------------------------------------------------------------

function Resolve-Step ([object]$raw) {
    if ($raw -is [string]) {
        return [PSCustomObject]@{ Kind = 'single'; Cmd = $raw; Condition = $null; Timeout = 0; Retry = 0 }
    }

    # Parallel block: { "parallel": ["cmd1", "cmd2"] }
    if ($null -ne $raw.parallel) {
        return [PSCustomObject]@{
            Kind     = 'parallel'
            Commands = @($raw.parallel)
            Timeout  = if ($null -ne $raw.timeout) { [int]$raw.timeout } else { 0 }
            Retry    = 0
        }
    }

    # Object step: { "cmd": "...", "if": "...", "timeout": 30, "retry": 3 }
    if ($null -ne $raw.cmd) {
        $cond = $raw.PSObject.Properties['if']
        return [PSCustomObject]@{
            Kind      = 'single'
            Cmd       = [string]$raw.cmd
            Condition = if ($null -ne $cond) { [string]$cond.Value } else { $null }
            Timeout   = if ($null -ne $raw.timeout) { [int]$raw.timeout } else { 0 }
            Retry     = if ($null -ne $raw.retry)   { [int]$raw.retry   } else { 0 }
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

    if ($c -ieq 'node_modules missing') {
        return -not (Test-Path 'node_modules' -PathType Container)
    }
    if ($c -imatch '^dir missing:\s*(.+)$') {
        return -not (Test-Path $Matches[1].Trim() -PathType Container)
    }
    if ($c -imatch '^file missing:\s*(.+)$') {
        return -not (Test-Path $Matches[1].Trim() -PathType Leaf)
    }
    if ($c -imatch '^env:\s*(.+)$') {
        return ($null -ne [System.Environment]::GetEnvironmentVariable($Matches[1].Trim()))
    }
    if ($c -imatch '^env missing:\s*(.+)$') {
        return ($null -eq [System.Environment]::GetEnvironmentVariable($Matches[1].Trim()))
    }

    Write-Warn "Unknown condition '$condition' -- step will run."
    return $true
}

function Test-ConditionSyntax ([string]$condition) {
    if (-not $condition) { return $true }
    $c = $condition.Trim()
    return ($c -ieq 'node_modules missing') -or
           ($c -imatch '^dir missing:\s*(.+)$') -or
           ($c -imatch '^file missing:\s*(.+)$') -or
           ($c -imatch '^env:\s*(.+)$') -or
           ($c -imatch '^env missing:\s*(.+)$')
}

# ---------------------------------------------------------------------------
# Single step execution
# ---------------------------------------------------------------------------

function Invoke-Step {
    param(
        [string]$Cmd,
        [int]$StepTimeout = 0,
        [bool]$IsDry      = $false
    )

    Write-Step "Running: $Cmd"

    if ($IsDry) {
        Write-Skip "(dry run -- not executed)"
        return 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($StepTimeout -gt 0) {
        $cwd = (Get-Location).Path
        $job = Start-Job -ScriptBlock {
            param($cmd, $dir)
            Set-Location $dir
            Invoke-Expression $cmd
            $LASTEXITCODE
        } -ArgumentList $Cmd, $cwd

        $done = Wait-Job $job -Timeout $StepTimeout
        if (-not $done) {
            Stop-Job  $job | Out-Null
            Remove-Job $job | Out-Null
            $sw.Stop()
            Write-Err "Timed out after ${StepTimeout}s: $Cmd"
            return 1
        }

        $output = Receive-Job $job
        Remove-Job $job | Out-Null

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
    # Reset LASTEXITCODE first -- cmdlets do not update it, so stale values bleed through.
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
        [int]$StepTimeout = 0,
        [bool]$IsDry      = $false
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
        $remaining = if ($StepTimeout -gt 0) { $StepTimeout - [int]$sw.Elapsed.TotalSeconds } else { -1 }

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
            $code = Invoke-Parallel -Commands $step.Commands -StepTimeout $step.Timeout -IsDry $IsDry
        } else {
            if (-not (Test-Condition $step.Condition)) {
                Write-Skip "Condition not met, skipping: $($step.Cmd)"
                continue
            }

            $maxAttempts = 1 + [math]::Max(0, $step.Retry)
            $attempt     = 0
            $code        = 1

            while ($attempt -lt $maxAttempts -and $code -ne 0) {
                if ($attempt -gt 0) {
                    Write-Warn "Retry $attempt / $($step.Retry): $($step.Cmd)"
                }
                $code = Invoke-Step -Cmd $step.Cmd -StepTimeout $step.Timeout -IsDry $IsDry
                $attempt++
            }
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
# Workflow listing (all workflows)
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
# Workflow detail (steps in one workflow)
# ---------------------------------------------------------------------------

function Format-StepDetail {
    param([object]$raw, [int]$Idx)

    $step = Resolve-Step $raw
    if ($null -eq $step) {
        Write-Host "  [$Idx]  (unrecognized step)" -ForegroundColor DarkGray
        return
    }

    if ($step.Kind -eq 'parallel') {
        Write-Host "  [$Idx]  [parallel]" -ForegroundColor White
        foreach ($c in $step.Commands) {
            Write-Host "         $c" -ForegroundColor DarkCyan
        }
        if ($step.Timeout -gt 0) {
            Write-Host "       timeout: $($step.Timeout)s" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [$Idx]  $($step.Cmd)" -ForegroundColor White
        if ($step.Condition) {
            Write-Host "       if:      $($step.Condition)" -ForegroundColor DarkGray
        }
        if ($step.Timeout -gt 0) {
            Write-Host "       timeout: $($step.Timeout)s" -ForegroundColor DarkGray
        }
        if ($step.Retry -gt 0) {
            Write-Host "       retry:   $($step.Retry)" -ForegroundColor DarkGray
        }
    }
}

function Show-WorkflowDetail {
    param([PSCustomObject]$cfg, [string]$Name, [bool]$AsJson)

    $steps = @($cfg.Data.scripts.$Name)

    if ($AsJson) {
        $out = @($steps | ForEach-Object { $_ })
        Write-Output ($out | ConvertTo-Json -Depth 10)
        return
    }

    Write-Blank
    Write-Host "  Workflow: $Name  ($($steps.Count) step(s))  [config: $($cfg.Source)]" -ForegroundColor Cyan
    Write-Rule

    if ($steps.Count -eq 0) {
        Write-Warn "No steps defined. Add one with: pt run $Name --add --cmd `"...`""
        Write-Blank
        return
    }

    $idx = 0
    foreach ($raw in $steps) {
        $idx++
        Write-Blank
        Format-StepDetail -raw $raw -Idx $idx
    }

    Write-Blank
    Write-Rule
    Write-Blank
}

# ---------------------------------------------------------------------------
# Workflow creation
# ---------------------------------------------------------------------------

function Invoke-Create {
    param([string]$Name)

    # Validate name
    if (-not $Name) {
        Write-Blank
        Write-Err "Provide a workflow name: pt run --create <name>"
        Write-Blank
        exit 1
    }
    if ($Name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') {
        Write-Blank
        Write-Err "Invalid workflow name '$Name'. Use letters, numbers, hyphens, and underscores only. Must start with a letter."
        Write-Blank
        exit 1
    }

    # Load or create config
    $cfg = Load-Config
    if (-not $cfg) {
        Write-Info "No run.config.json found -- creating one in the current directory."
        $cfg = New-LocalConfig
    }

    # Check for duplicates
    $existing = $cfg.Data.scripts | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    if ($existing -contains $Name) {
        Write-Blank
        Write-Err "Workflow '$Name' already exists."
        Write-Blank
        Write-Host "  Use 'pt run $Name --add --cmd `"...`"' to add steps." -ForegroundColor DarkGray
        Write-Blank
        exit 1
    }

    $cfg.Data.scripts | Add-Member -NotePropertyName $Name -NotePropertyValue @()
    Save-Config $cfg

    Write-Blank
    Write-Ok "Workflow '$Name' created in $($cfg.Source)"
    Write-Blank
    Write-Host "  Add steps with:" -ForegroundColor DarkGray
    Write-Host "    pt run $Name --add --cmd `"npm install`"" -ForegroundColor Cyan
    Write-Host "    pt run $Name --add --cmd `"npm run dev`"" -ForegroundColor Cyan
    Write-Blank
}

# ---------------------------------------------------------------------------
# Add step
# ---------------------------------------------------------------------------

function Invoke-AddStep {
    param([PSCustomObject]$cfg, [string]$WorkflowName)

    # Parse comma-separated --parallel into an array
    $parallelCmds = if ($Parallel) {
        @($Parallel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    } else { @() }

    # Validate: --cmd and --parallel are mutually exclusive
    $hasCmd      = ($Cmd.Trim() -ne '')
    $hasParallel = ($parallelCmds.Count -gt 0)

    if ($hasCmd -and $hasParallel) {
        Write-Blank
        Write-Err "--cmd and --parallel cannot be used together."
        Write-Blank
        exit 1
    }
    if (-not $hasCmd -and -not $hasParallel) {
        Write-Blank
        Write-Err "Provide --cmd `"...`" or --parallel `"cmd1`" `"cmd2`" ..."
        Write-Blank
        exit 1
    }

    # Validate --parallel count
    if ($hasParallel -and $parallelCmds.Count -lt 2) {
        Write-Blank
        Write-Err "--parallel requires at least 2 commands."
        Write-Blank
        exit 1
    }

    # Validate --timeout
    if ($Timeout -lt 0) {
        Write-Blank
        Write-Err "--timeout must be a positive number of seconds."
        Write-Blank
        exit 1
    }

    # Validate --retry
    if ($Retry -lt 0) {
        Write-Blank
        Write-Err "--retry must be a positive number."
        Write-Blank
        exit 1
    }

    # Validate --cond syntax (warn only -- does not block)
    if ($Cond -and -not (Test-ConditionSyntax $Cond)) {
        Write-Warn "Unrecognized condition '$Cond'."
        Write-Warn "Known patterns: 'node_modules missing', 'dir missing: <path>', 'file missing: <path>', 'env: <VAR>', 'env missing: <VAR>'"
    }

    # Build the step object
    if ($hasParallel) {
        $step = [PSCustomObject]@{ parallel = $parallelCmds }
        if ($Timeout -gt 0) { $step | Add-Member -NotePropertyName 'timeout' -NotePropertyValue $Timeout }
    } elseif (-not $Cond -and $Timeout -eq 0 -and $Retry -eq 0) {
        # Plain string step
        $step = $Cmd.Trim()
    } else {
        $step = [PSCustomObject]@{ cmd = $Cmd.Trim() }
        if ($Cond)          { $step | Add-Member -NotePropertyName 'if'      -NotePropertyValue $Cond    }
        if ($Timeout -gt 0) { $step | Add-Member -NotePropertyName 'timeout' -NotePropertyValue $Timeout }
        if ($Retry -gt 0)   { $step | Add-Member -NotePropertyName 'retry'   -NotePropertyValue $Retry   }
    }

    # Append and save
    $current = @($cfg.Data.scripts.$WorkflowName)
    $updated = $current + $step
    $cfg.Data.scripts.PSObject.Properties[$WorkflowName].Value = $updated
    Save-Config $cfg

    $newIdx = $updated.Count
    Write-Blank
    Write-Ok "Step $newIdx added to '$WorkflowName'."
    Write-Blank
    Write-Host "  Workflow '$WorkflowName' now has $newIdx step(s). Preview with:" -ForegroundColor DarkGray
    Write-Host "    pt run $WorkflowName --list" -ForegroundColor Cyan
    Write-Blank
}

# ---------------------------------------------------------------------------
# Remove step (non-interactive)
# ---------------------------------------------------------------------------

function Invoke-RemoveStep {
    param([PSCustomObject]$cfg, [string]$WorkflowName, [int]$StepNum)

    $steps = @($cfg.Data.scripts.$WorkflowName)

    if ($StepNum -lt 1 -or $StepNum -gt $steps.Count) {
        Write-Blank
        Write-Err "Step $StepNum does not exist. '$WorkflowName' has $($steps.Count) step(s)."
        Write-Blank
        exit 1
    }

    $removeIdx = $StepNum - 1
    $newSteps  = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($i -ne $removeIdx) { $steps[$i] } })

    $cfg.Data.scripts.PSObject.Properties[$WorkflowName].Value = $newSteps
    Save-Config $cfg

    Write-Blank
    Write-Ok "Step $StepNum removed from '$WorkflowName'. $($newSteps.Count) step(s) remaining."
    Write-Blank
}

# ---------------------------------------------------------------------------
# Edit workflow (interactive)
# ---------------------------------------------------------------------------

function Invoke-EditWorkflow {
    param([PSCustomObject]$cfg, [string]$WorkflowName)

    while ($true) {
        Show-WorkflowDetail -cfg $cfg -Name $WorkflowName -AsJson $false

        $steps = @($cfg.Data.scripts.$WorkflowName)
        if ($steps.Count -eq 0) {
            Write-Warn "No steps to edit. Add one first: pt run $WorkflowName --add --cmd `"...`""
            break
        }

        $pick = Read-Host "  Step number to edit or remove (Q to quit)"
        if ($pick -ieq 'q') { break }

        $n = 0
        if (-not [int]::TryParse($pick.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $steps.Count) {
            Write-Warn "Enter a number between 1 and $($steps.Count)."
            continue
        }

        $raw  = $steps[$n - 1]
        $step = Resolve-Step $raw

        Write-Blank
        Write-Host "  Selected:" -ForegroundColor DarkGray
        Format-StepDetail -raw $raw -Idx $n
        Write-Blank

        $action = Read-Host "  (E) Edit   (D) Delete   (Q) Back"
        if ($action -ieq 'q') { continue }

        # --- Delete ---
        if ($action -ieq 'd') {
            $confirm = Read-Host "  Delete step $n from '$WorkflowName'? (Y to confirm)"
            if ($confirm -ieq 'y') {
                $idx      = $n - 1
                $newSteps = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($i -ne $idx) { $steps[$i] } })
                $cfg.Data.scripts.PSObject.Properties[$WorkflowName].Value = $newSteps
                Save-Config $cfg
                Write-Ok "Step $n deleted."
            } else {
                Write-Info "Cancelled."
            }
            continue
        }

        # --- Edit ---
        if ($action -ieq 'e') {
            if ($step.Kind -eq 'parallel') {
                Write-Warn "Editing parallel steps is not supported. Delete and re-add instead."
                continue
            }

            Write-Blank
            $newCmd = (Read-Host "  New command (leave blank to keep current)").Trim()
            if (-not $newCmd) { $newCmd = $step.Cmd }

            $newCond = (Read-Host "  Condition --if (leave blank to keep: '$($step.Condition)')").Trim()
            if (-not $newCond -and $step.Condition) { $newCond = $step.Condition }

            $newTimeoutStr = (Read-Host "  Timeout in seconds (leave blank to keep: $($step.Timeout))").Trim()
            $newTimeout = $step.Timeout
            if ($newTimeoutStr -ne '') {
                $parsed = 0
                if ([int]::TryParse($newTimeoutStr, [ref]$parsed) -and $parsed -ge 0) {
                    $newTimeout = $parsed
                } else {
                    Write-Warn "Invalid timeout -- keeping current value."
                }
            }

            $newRetryStr = (Read-Host "  Retry count (leave blank to keep: $($step.Retry))").Trim()
            $newRetry = $step.Retry
            if ($newRetryStr -ne '') {
                $parsed = 0
                if ([int]::TryParse($newRetryStr, [ref]$parsed) -and $parsed -ge 0) {
                    $newRetry = $parsed
                } else {
                    Write-Warn "Invalid retry count -- keeping current value."
                }
            }

            # Validate condition syntax if changed
            if ($newCond -and -not (Test-ConditionSyntax $newCond)) {
                Write-Warn "Unrecognized condition '$newCond' -- saved anyway."
            }

            # Build updated step
            if (-not $newCond -and $newTimeout -eq 0 -and $newRetry -eq 0) {
                $updatedStep = $newCmd
            } else {
                $updatedStep = [PSCustomObject]@{ cmd = $newCmd }
                if ($newCond)         { $updatedStep | Add-Member -NotePropertyName 'if'      -NotePropertyValue $newCond    }
                if ($newTimeout -gt 0){ $updatedStep | Add-Member -NotePropertyName 'timeout' -NotePropertyValue $newTimeout }
                if ($newRetry -gt 0)  { $updatedStep | Add-Member -NotePropertyName 'retry'   -NotePropertyValue $newRetry   }
            }

            $steps[$n - 1] = $updatedStep
            $cfg.Data.scripts.PSObject.Properties[$WorkflowName].Value = $steps
            Save-Config $cfg
            Write-Ok "Step $n updated."
            continue
        }

        Write-Warn "Unknown action. Type E, D, or Q."
    }

    Write-Blank
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# --create: does not require config to exist
if ($Create) {
    Invoke-Create -Name $ScriptName
    exit 0
}

$cfg = Load-Config

# --list with no workflow name: list all workflows
if ($List -and -not $ScriptName) {
    if (-not $cfg) {
        Write-Blank
        Write-Warn "No config found. Create one with: pt run --create <workflow>"
        Write-Blank
        exit 0
    }
    Show-Workflows -Data $cfg.Data -Source $cfg.Source -AsJson $Jsonout.IsPresent
    exit 0
}

# All remaining commands require a workflow name
if (-not $ScriptName) {
    Write-Blank
    Write-Err "Usage: pt run <workflow> [--dry] [--continue] [--env <profile>]"
    Write-Blank
    Write-Host "  pt run --list              list all workflows" -ForegroundColor DarkGray
    Write-Host "  pt run --create <name>     create a new workflow" -ForegroundColor DarkGray
    Write-Blank
    exit 1
}

# --list with workflow name: show steps in that workflow
if ($List) {
    if (-not $cfg) {
        Write-Blank
        Write-Err "No config found."
        Write-Blank
        exit 1
    }
    if ($null -eq $cfg.Data.scripts.$ScriptName) {
        Write-Blank
        Write-Err "Workflow '$ScriptName' not found."
        Write-Blank
        exit 1
    }
    Show-WorkflowDetail -cfg $cfg -Name $ScriptName -AsJson $Jsonout.IsPresent
    exit 0
}

# --add: add a step to a workflow (creates config if missing, requires workflow to exist)
if ($Add) {
    if (-not $cfg) {
        Write-Blank
        Write-Err "No config found. Create the workflow first: pt run --create $ScriptName"
        Write-Blank
        exit 1
    }
    if ($null -eq $cfg.Data.scripts.$ScriptName) {
        Write-Blank
        Write-Err "Workflow '$ScriptName' not found. Create it first: pt run --create $ScriptName"
        Write-Blank
        exit 1
    }
    Invoke-AddStep -cfg $cfg -WorkflowName $ScriptName
    exit 0
}

# --remove: delete a step by number (non-interactive)
if ($Remove -gt 0) {
    if (-not $cfg) {
        Write-Blank; Write-Err "No config found."; Write-Blank; exit 1
    }
    if ($null -eq $cfg.Data.scripts.$ScriptName) {
        Write-Blank; Write-Err "Workflow '$ScriptName' not found."; Write-Blank; exit 1
    }
    Invoke-RemoveStep -cfg $cfg -WorkflowName $ScriptName -StepNum $Remove
    exit 0
}

# --edit: interactive step editor
if ($Edit) {
    if (-not $cfg) {
        Write-Blank; Write-Err "No config found."; Write-Blank; exit 1
    }
    if ($null -eq $cfg.Data.scripts.$ScriptName) {
        Write-Blank; Write-Err "Workflow '$ScriptName' not found."; Write-Blank; exit 1
    }
    Invoke-EditWorkflow -cfg $cfg -WorkflowName $ScriptName
    exit 0
}

# Default: execute the workflow
if (-not $cfg) {
    Write-Blank
    Write-Err "No config found. Create one with: pt run --create <workflow>"
    Write-Blank
    Write-Host "  Example:" -ForegroundColor DarkGray
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
