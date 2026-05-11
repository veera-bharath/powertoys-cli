<#
.SYNOPSIS
    PortManager -- inspect, kill, list, watch, and find free ports.

    port --get <port>                      show all connections on a port
    port --get --pid <id>                  show connections by PID
    port --get --name <name>               show connections by process name
    port --kill <port>                     kill process using a port (confirms first)
    port --kill --pid <id>                 kill by PID
    port --kill --name <name>              kill by process name
    port --kill <port> --force             skip confirmation
    port --fix <port>                      detect + prompt + kill (same as --kill)
    port --list                            list all active TCP connections
    port --list --range <n>                list first N results
    port --list --s <start> --e <end>          list ports between start and end (inclusive)
    port --watch <port>                       watch port in real-time  (Ctrl+C exits)
    port --free                               find a free port (scans 1024-65535)
    port --free --s <start> --e <end>         find a free port in range
    port --json                            JSON output (combine with any command)
#>

[CmdletBinding()]
param(
    [switch]$Get,
    [switch]$Kill,
    [switch]$Fix,
    [switch]$List,
    [switch]$Watch,
    [switch]$Free,

    [Parameter(Position=0)]
    [int]$Port = 0,

    [Alias('pid')]
    [int]$ProcessId = 0,

    [string]$Name = '',
    [switch]$Force,
    [int]$Range = 0,
    [int]$S = 0,
    [int]$E = 0,
    [switch]$Json
)

# ---------------------------------------------------------------------------
# Global flags
# ---------------------------------------------------------------------------

$script:Quiet = [bool]$Json    # suppress all Write-Host when outputting JSON

# ---------------------------------------------------------------------------
# Column widths
# ---------------------------------------------------------------------------

$C_PID   = 7
$C_PORT  = 6
$C_PROC  = 22
$C_STATE = 13
$C_ADDR  = 22

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Clip([string]$s, [int]$w) {
    if ($null -eq $s -or $s.Length -eq 0) { return ''.PadRight($w) }
    if ($s.Length -gt $w) { return $s.Substring(0, $w - 2) + '..' }
    return $s.PadRight($w)
}

function Get-StateColor([string]$state) {
    switch ($state) {
        'Listen'      { return 'Green'   }
        'Established' { return 'Red'     }
        'TimeWait'    { return 'Yellow'  }
        'CloseWait'   { return 'Yellow'  }
        'FinWait1'    { return 'Yellow'  }
        'FinWait2'    { return 'Yellow'  }
        'Bound'       { return 'Cyan'    }
        default       { return 'Gray'    }
    }
}

function Write-Ok   ([string]$m) { if (-not $script:Quiet) { Write-Host "  [OK]  $m" -ForegroundColor Green  } }
function Write-Err  ([string]$m) { if (-not $script:Quiet) { Write-Host "  [ERR] $m" -ForegroundColor Red    } else { [Console]::Error.WriteLine("ERR: $m") } }
function Write-Info ([string]$m) { if (-not $script:Quiet) { Write-Host "  [..]  $m" -ForegroundColor Cyan   } }
function Write-Warn ([string]$m) { if (-not $script:Quiet) { Write-Host "  [!!]  $m" -ForegroundColor Yellow } }

# ---------------------------------------------------------------------------
# Spinner (runs block in background job while animating)
# ---------------------------------------------------------------------------

function Invoke-WithSpinner {
    param([string]$Message, [scriptblock]$Block)

    # In JSON mode, run synchronously -- no console output to avoid polluting the JSON pipe
    if ($script:Quiet) { return (& $Block) }

    $job   = Start-Job -ScriptBlock $Block
    $chars = @('|', '/', '-', '\')
    $i     = 0

    while ($job.State -eq 'Running') {
        Write-Host ("`r  " + $chars[$i % 4] + "  " + $Message) -NoNewline -ForegroundColor DarkGray
        $i++
        Start-Sleep -Milliseconds 80
    }
    Write-Host "`r                                              `r" -NoNewline

    $result = Receive-Job $job -Wait -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $result
}

# ---------------------------------------------------------------------------
# Core data collection
# ---------------------------------------------------------------------------

function Get-PortData {
    param(
        [int]$FilterPort    = 0,
        [int]$FilterPid     = 0,
        [string]$FilterName = ''
    )

    $raw = Invoke-WithSpinner -Message 'Fetching connections...' -Block {
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort,
                          @{ Name = 'State'; Expression = { "$($_.State)" } },
                          OwningProcess
    }

    if (-not $raw) { return @() }

    # Apply cheap filters before the per-PID process lookup
    if ($FilterPort -gt 0) {
        $raw = @($raw | Where-Object { $_.LocalPort -eq $FilterPort })
    }
    if ($FilterPid -gt 0) {
        $raw = @($raw | Where-Object { $_.OwningProcess -eq $FilterPid })
    }

    if ($raw.Count -eq 0) { return @() }

    # Enrich with process names -- one Get-Process per unique PID
    $pidCache = @{}
    $result   = foreach ($c in $raw) {
        $ownerPid = $c.OwningProcess
        if (-not $pidCache.ContainsKey($ownerPid)) {
            $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            $pidCache[$ownerPid] = if ($proc) { $proc.Name } else { '<unknown>' }
        }
        [PSCustomObject]@{
            ConnPid     = $ownerPid
            ProcessName = $pidCache[$ownerPid]
            LocalAddr   = "$($c.LocalAddress)"
            LocalPort   = $c.LocalPort
            RemoteAddr  = "$($c.RemoteAddress)"
            RemotePort  = $c.RemotePort
            State       = "$($c.State)"
        }
    }

    if ($FilterName -and $FilterName -ne '') {
        $result = @($result | Where-Object { $_.ProcessName -like "*$FilterName*" })
    }

    return @($result)
}

# ---------------------------------------------------------------------------
# Table display (used by --list)
# ---------------------------------------------------------------------------

function Write-TableHeader {
    Write-Host ''
    $hdr = '  ' + (Clip 'PID'     $C_PID)   + '  ' +
                  (Clip 'PORT'    $C_PORT)  + '  ' +
                  (Clip 'PROCESS' $C_PROC)  + '  ' +
                  (Clip 'STATE'   $C_STATE) + '  LOCAL ADDRESS'
    $sep = '  ' + ('-' * $C_PID)   + '  ' +
                  ('-' * $C_PORT)  + '  ' +
                  ('-' * $C_PROC)  + '  ' +
                  ('-' * $C_STATE) + '  ' + ('-' * $C_ADDR)
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkGray
}

function Write-TableRow($conn) {
    $color = Get-StateColor $conn.State
    $line  = '  ' + (Clip "$($conn.ConnPid)"    $C_PID)   + '  ' +
                    (Clip "$($conn.LocalPort)"   $C_PORT)  + '  ' +
                    (Clip $conn.ProcessName      $C_PROC)  + '  ' +
                    (Clip $conn.State            $C_STATE) + '  ' +
                    "$($conn.LocalAddr):$($conn.LocalPort)"
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Detail card (used by --get and --kill)
# ---------------------------------------------------------------------------

function Write-ConnDetail($conn) {
    $color  = Get-StateColor $conn.State
    $remote = if ($conn.RemotePort -eq 0) { '-' } else { "$($conn.RemoteAddr):$($conn.RemotePort)" }
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "  PID       : $($conn.ConnPid)"              -ForegroundColor White
    Write-Host "  Process   : $($conn.ProcessName)"          -ForegroundColor White
    Write-Host "  Local     : $($conn.LocalAddr):$($conn.LocalPort)" -ForegroundColor White
    Write-Host "  Remote    : $remote"                        -ForegroundColor White
    Write-Host "  State     : $($conn.State)"                 -ForegroundColor $color
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: --get
# ---------------------------------------------------------------------------

function Invoke-Get {
    param([int]$FilterPort, [int]$FilterPid, [string]$FilterName)

    $data = Get-PortData -FilterPort $FilterPort -FilterPid $FilterPid -FilterName $FilterName

    if (-not $data -or $data.Count -eq 0) {
        if     ($FilterPort -gt 0)           { Write-Info "No connections found on port $FilterPort -- port is free" }
        elseif ($FilterPid  -gt 0)           { Write-Info "No connections found for PID $FilterPid" }
        elseif ($FilterName -and $FilterName -ne '') { Write-Info "No connections found for process '$FilterName'" }
        else                                 { Write-Err  'Specify --get <port>, --get --pid <id>, or --get --name <name>' }
        return
    }

    if ($Json) { $data | ConvertTo-Json -Depth 5; return }

    Write-Host ''
    foreach ($conn in $data) { Write-ConnDetail $conn }
    Write-Host "  $($data.Count) connection(s)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: --kill / --fix
# ---------------------------------------------------------------------------

function Invoke-Kill {
    param([int]$FilterPort, [int]$FilterPid, [string]$FilterName, [bool]$SkipConfirm)

    if ($FilterPort -eq 0 -and $FilterPid -eq 0 -and ($null -eq $FilterName -or $FilterName -eq '')) {
        Write-Err 'Specify --kill <port>, --kill --pid <id>, or --kill --name <name>'
        return
    }

    $data = Get-PortData -FilterPort $FilterPort -FilterPid $FilterPid -FilterName $FilterName

    if (-not $data -or $data.Count -eq 0) {
        if     ($FilterPort -gt 0)                   { Write-Err "Nothing found on port $FilterPort -- port may already be free" }
        elseif ($FilterPid  -gt 0)                   { Write-Err "No connections found for PID $FilterPid" }
        else                                          { Write-Err "No connections found for process '$FilterName'" }
        return
    }

    Write-Host ''
    Write-Host '  Processes to terminate:' -ForegroundColor White
    Write-Host ''

    # One detail card per unique PID
    $seenPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($conn in ($data | Sort-Object ConnPid)) {
        if ($seenPids.Add($conn.ConnPid)) { Write-ConnDetail $conn }
    }

    $uniquePids = @($data | Select-Object -ExpandProperty ConnPid -Unique)

    if (-not $SkipConfirm) {
        Write-Host ''
        Write-Host "  This will terminate $($uniquePids.Count) process(es)." -ForegroundColor Yellow
        Write-Host '  Type YES to confirm: ' -NoNewline -ForegroundColor Yellow
        $confirm = Read-Host
        if ($confirm -cne 'YES') {
            Write-Host ''
            Write-Warn 'Kill cancelled.'
            return
        }
    }

    Write-Host ''
    $killed = 0
    $errCnt = 0

    foreach ($procId in $uniquePids) {
        $entry = $data | Where-Object { $_.ConnPid -eq $procId } | Select-Object -First 1
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Write-Ok "Killed PID $procId ($($entry.ProcessName))"
            $killed++
        } catch {
            $msg = $_.Exception.Message
            if ($msg -like '*Access*' -or $msg -like '*privilege*' -or $msg -like '*denied*') {
                Write-Err "Access denied for PID $procId ($($entry.ProcessName)) -- try running as Administrator"
            } else {
                Write-Err "Failed to kill PID $procId : $msg"
            }
            $errCnt++
        }
    }

    Write-Host ''
    if ($killed -gt 0) { Write-Ok   "$killed process(es) terminated" }
    if ($errCnt -gt 0) { Write-Warn "$errCnt process(es) could not be killed" }
}

# ---------------------------------------------------------------------------
# Action: --list
# ---------------------------------------------------------------------------

function Invoke-List {
    param([int]$ResultRange, [int]$Lo = 0, [int]$Hi = 0)

    $data = Get-PortData

    if (-not $data -or $data.Count -eq 0) {
        Write-Info 'No active TCP connections found.'
        return
    }

    $data = @($data | Sort-Object LocalPort)

    # Port range filter
    if ($Lo -gt 0 -and $Hi -gt 0) {
        $data = @($data | Where-Object { $_.LocalPort -ge $Lo -and $_.LocalPort -le $Hi })
        if ($data.Count -eq 0) {
            Write-Info "No connections in port range $Lo-$Hi"
            return
        }
    }

    $total = $data.Count

    if ($ResultRange -gt 0) {
        $data = @($data | Select-Object -First $ResultRange)
    }

    if ($Json) { $data | ConvertTo-Json -Depth 5; return }

    Write-TableHeader
    foreach ($conn in $data) { Write-TableRow $conn }
    Write-Host ''

    if ($ResultRange -gt 0 -and $data.Count -lt $total) {
        Write-Host "  Showing $($data.Count) of $total  (use --range $total to see all)" -ForegroundColor DarkGray
    } else {
        Write-Host "  $total connection(s)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Action: --watch
# ---------------------------------------------------------------------------

function Invoke-Watch {
    param([int]$WatchPort)

    if ($WatchPort -le 0) {
        Write-Err '--watch requires a port number.  Example: port --watch 3000'
        return
    }

    Write-Info "Watching port $WatchPort -- Ctrl+C to stop"
    Write-Host ''

    $prevLine = ''

    while ($true) {
        $conns = Get-NetTCPConnection -LocalPort $WatchPort -ErrorAction SilentlyContinue
        $ts    = Get-Date -Format 'HH:mm:ss'

        if ($conns) {
            $stateStr = ($conns | ForEach-Object { "$($_.State)" } | Select-Object -Unique) -join ', '
            $pidStr   = ($conns | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
            $nameMap  = @{}
            foreach ($c in $conns) {
                if (-not $nameMap.ContainsKey($c.OwningProcess)) {
                    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                    $nameMap[$c.OwningProcess] = if ($p) { $p.Name } else { '<unknown>' }
                }
            }
            $nameStr = ($nameMap.Values | Select-Object -Unique) -join ', '
            $line    = "  [$ts]  port $WatchPort  |  $stateStr  |  PID $pidStr  |  $nameStr"
            $color   = if ($stateStr -like '*Established*') { 'Red'    }
                       elseif ($stateStr -like '*TimeWait*')  { 'Yellow' }
                       else                                   { 'Green'  }
        } else {
            $line  = "  [$ts]  port $WatchPort  |  FREE  |  no process"
            $color = 'Green'
        }

        Write-Host $line -ForegroundColor $color
        Start-Sleep -Seconds 1
    }
}

# ---------------------------------------------------------------------------
# Action: --free
# ---------------------------------------------------------------------------

function Invoke-Free {
    param([int]$Lo = 0, [int]$Hi = 0)

    if ($Lo -le 0) { $Lo = 1024  }
    if ($Hi -le 0) { $Hi = 65535 }

    if (-not $script:Quiet) { Write-Info "Scanning $Lo-$Hi for a free port..." }

    $usedSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
                      Select-Object -ExpandProperty LocalPort -Unique)) {
        [void]$usedSet.Add($p)
    }

    $freePort = $null
    for ($p = $Lo; $p -le $Hi; $p++) {
        if (-not $usedSet.Contains($p)) { $freePort = $p; break }
    }

    if ($null -eq $freePort) {
        Write-Err "No free ports found in range $Lo-$Hi"
        return
    }

    if ($Json) {
        [PSCustomObject]@{ FreePort = $freePort; Range = "$Lo-$Hi" } | ConvertTo-Json
        return
    }

    Write-Host ''
    Write-Host '  Free port: ' -NoNewline -ForegroundColor White
    Write-Host "$freePort"     -ForegroundColor Green
    Write-Host ''
    Write-Host "  (scanned $Lo-$Hi)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

function Show-Usage {
    Write-Host ''
    Write-Host '  PortManager -- Windows port inspector and manager' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  USAGE' -ForegroundColor White
    Write-Host '    port --get <port>                    show connections on a port'            -ForegroundColor Gray
    Write-Host '    port --get --pid <id>                show connections by PID'               -ForegroundColor Gray
    Write-Host '    port --get --name <name>             show connections by process name'      -ForegroundColor Gray
    Write-Host '    port --kill <port>                   kill process on port (confirms first)' -ForegroundColor Gray
    Write-Host '    port --kill --pid <id>               kill by PID'                           -ForegroundColor Gray
    Write-Host '    port --kill --name <name>            kill by process name'                  -ForegroundColor Gray
    Write-Host '    port --kill <port> --force           skip confirmation'                     -ForegroundColor Gray
    Write-Host '    port --fix <port>                    detect conflict + prompt + kill'        -ForegroundColor Gray
    Write-Host '    port --list                          list all active connections'            -ForegroundColor Gray
    Write-Host '    port --list --range <n>              list first N results'                -ForegroundColor Gray
    Write-Host '    port --list --s <start> --e <end>    list ports between start and end'   -ForegroundColor Gray
    Write-Host '    port --watch <port>                  watch port in real-time (Ctrl+C exits)' -ForegroundColor Gray
    Write-Host '    port --free                          find a free port (1024-65535)'       -ForegroundColor Gray
    Write-Host '    port --free --s <start> --e <end>    find a free port in range'           -ForegroundColor Gray
    Write-Host '    port --json                          JSON output for any command'            -ForegroundColor Gray
    Write-Host ''
    Write-Host '  COLOR KEY' -ForegroundColor White
    Write-Host '    Green    LISTEN / free port'              -ForegroundColor Green
    Write-Host '    Red      ESTABLISHED (active connection)' -ForegroundColor Red
    Write-Host '    Yellow   TIME_WAIT / CLOSE_WAIT (closing)' -ForegroundColor Yellow
    Write-Host '    Gray     other states'                    -ForegroundColor Gray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

if     ($Get)          { Invoke-Get   -FilterPort $Port -FilterPid $ProcessId -FilterName $Name }
elseif ($Kill -or $Fix){ Invoke-Kill  -FilterPort $Port -FilterPid $ProcessId -FilterName $Name -SkipConfirm ([bool]$Force) }
elseif ($List)         { Invoke-List  -ResultRange $Range -Lo $S -Hi $E }
elseif ($Watch)        { Invoke-Watch -WatchPort $Port }
elseif ($Free)         { Invoke-Free  -Lo $S -Hi $E }
else                   { Show-Usage }
