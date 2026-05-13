<#
.SYNOPSIS
    pt -- PowerToys CLI unified entry point.

    pt <command> [arguments]
    pt help [command]
    pt version
#>

$PT_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Rule  { Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray }
function Write-Blank { Write-Host "" }

function Write-Header ([string]$Title) {
    Write-Blank
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Rule
}

# ---------------------------------------------------------------------------
# Load command registry
# ---------------------------------------------------------------------------

$ptRoot  = $PSScriptRoot
$cfgFile = Join-Path $ptRoot "commands.json"

if (-not (Test-Path $cfgFile)) {
    Write-Host "  ERROR: commands.json not found at $cfgFile" -ForegroundColor Red
    exit 1
}

$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json

$commands = [System.Collections.Generic.List[object]]::new()
foreach ($c in $cfg.commands) { $commands.Add($c) }

# ---------------------------------------------------------------------------
# Arg parsing -- consume --debug before forwarding anything
# ---------------------------------------------------------------------------

$rawArgs = @($args)
$ptDebug = $rawArgs -contains "--debug"
$rawArgs = @($rawArgs | Where-Object { $_ -ne "--debug" })

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Find-Command ([string]$Name) {
    foreach ($cmd in $commands) {
        if ($cmd.name -eq $Name) { return $cmd }
        if ($cmd.aliases -and $cmd.aliases -contains $Name) { return $cmd }
    }
    return $null
}

function Get-Suggestions ([string]$Query) {
    $q = $Query.ToLower()
    $commands | Where-Object {
        $_.name.ToLower().Contains($q) -or
        ($_.aliases | Where-Object { $_ -and $_.ToLower().Contains($q) })
    }
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function Show-Help {
    Write-Header "pt v$PT_VERSION  --  PowerToys CLI"
    Write-Blank
    Write-Host "  Usage:" -ForegroundColor White
    Write-Host "    pt <command> [arguments]" -ForegroundColor Gray
    Write-Host "    pt help <command>" -ForegroundColor Gray
    Write-Blank
    Write-Host "  Commands:" -ForegroundColor White
    foreach ($cmd in ($commands | Sort-Object name)) {
        $aliasTag = if ($cmd.aliases) { " [$($cmd.aliases -join ', ')]" } else { "" }
        Write-Host ("    {0,-34} {1}" -f ($cmd.name + $aliasTag), $cmd.description) -ForegroundColor Gray
    }
    Write-Blank
    Write-Host "  Global flags:" -ForegroundColor White
    Write-Host "    --debug       Show routing info before delegating" -ForegroundColor DarkGray
    Write-Host "    --version     Print version" -ForegroundColor DarkGray
    Write-Blank
    Write-Host "  Run 'pt help <command>' for detailed usage." -ForegroundColor DarkGray
    Write-Rule
    Write-Blank
}

function Show-CommandHelp ([string]$Name) {
    $cmd = Find-Command $Name
    if (-not $cmd) {
        Write-Blank
        Write-Host "  pt: no help entry for '$Name'" -ForegroundColor Red
        Write-Blank
        Write-Host "  Run 'pt help' to list all commands." -ForegroundColor DarkGray
        Write-Blank
        exit 1
    }
    Write-Header "pt $($cmd.name)  --  $($cmd.displayName)"
    Write-Blank
    Write-Host "  $($cmd.description)" -ForegroundColor White
    Write-Blank
    Write-Host "  Usage: $($cmd.usage)" -ForegroundColor Cyan
    if ($cmd.help) {
        Write-Blank
        foreach ($line in $cmd.help) { Write-Host "  $line" -ForegroundColor Gray }
    }
    if ($cmd.aliases) {
        Write-Blank
        Write-Host "  Aliases: $($cmd.aliases -join ', ')" -ForegroundColor DarkGray
    }
    Write-Blank
    Write-Rule
    Write-Blank
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($rawArgs.Count -eq 0) { Show-Help ; exit 0 }

$subcommand  = [string]$rawArgs[0]
$passthrough = @($rawArgs | Select-Object -Skip 1)

switch ($subcommand) {
    { $_ -in @('help', '--help', '-h', '/?') } {
        if ($passthrough.Count -gt 0) { Show-CommandHelp $passthrough[0] } else { Show-Help }
        exit 0
    }
    { $_ -in @('version', '--version', '-v') } { Write-Host "pt v$PT_VERSION" ; exit 0 }
    { $_ -in @('list', 'ls', 'commands') }     { Show-Help ; exit 0 }
}

$cmd = Find-Command $subcommand

if (-not $cmd) {
    Write-Blank
    Write-Host "  pt: unknown command '$subcommand'" -ForegroundColor Red
    Write-Blank
    $suggestions = @(Get-Suggestions -Query $subcommand)
    if ($suggestions.Count -gt 0) {
        Write-Host "  Did you mean?" -ForegroundColor Yellow
        foreach ($s in $suggestions) { Write-Host "    pt $($s.name)" -ForegroundColor Cyan }
    } else {
        Write-Host "  Run 'pt help' to see available commands." -ForegroundColor DarkGray
    }
    Write-Blank
    exit 1
}

$scriptPath = Join-Path $ptRoot ($cmd.script -replace '/', '\')

if (-not (Test-Path $scriptPath)) {
    Write-Blank
    Write-Host "  pt: script not found for '$($cmd.name)'" -ForegroundColor Red
    Write-Host "      Expected: $scriptPath" -ForegroundColor DarkGray
    Write-Blank
    exit 1
}

if ($ptDebug) {
    Write-Blank
    Write-Host "  [pt:debug] command : $($cmd.name)" -ForegroundColor DarkMagenta
    Write-Host "  [pt:debug] script  : $scriptPath" -ForegroundColor DarkMagenta
    Write-Host "  [pt:debug] args    : $($passthrough -join ' ')" -ForegroundColor DarkMagenta
    Write-Blank
}

& $scriptPath @passthrough
exit $LASTEXITCODE
