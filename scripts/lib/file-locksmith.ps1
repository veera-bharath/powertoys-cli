<#
.SYNOPSIS
    FileLocksmith -- show and unlock processes holding a file open.

    file-locksmith <path>                  show processes locking the file
    file-locksmith <path> --kill           terminate locking process(es) (confirms first)
    file-locksmith <path> --kill --force   skip confirmation
    file-locksmith <path> --json           JSON output
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Path = '',

    [switch]$Kill,
    [switch]$Force,
    [switch]$Json
)

# ---------------------------------------------------------------------------
# Global flags
# ---------------------------------------------------------------------------

$script:Quiet = [bool]$Json    # suppress all Write-Host when outputting JSON

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Ok   ([string]$m) { if (-not $script:Quiet) { Write-Host "  [OK]  $m" -ForegroundColor Green  } }
function Write-Err  ([string]$m) { if (-not $script:Quiet) { Write-Host "  [ERR] $m" -ForegroundColor Red    } else { [Console]::Error.WriteLine("ERR: $m") } }
function Write-Info ([string]$m) { if (-not $script:Quiet) { Write-Host "  [..]  $m" -ForegroundColor Cyan   } }
function Write-Warn ([string]$m) { if (-not $script:Quiet) { Write-Host "  [!!]  $m" -ForegroundColor Yellow } }

function Clip([string]$s, [int]$w) {
    if ($null -eq $s -or $s.Length -eq 0) { return ''.PadRight($w) }
    if ($s.Length -gt $w) { return $s.Substring(0, $w - 2) + '..' }
    return $s.PadRight($w)
}

# ---------------------------------------------------------------------------
# Restart Manager P/Invoke
# ---------------------------------------------------------------------------

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public struct RM_UNIQUE_PROCESS {
    public int dwProcessId;
    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
    public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
    public string strServiceShortName;
    public int ApplicationType;
    public uint AppStatus;
    public uint TSSessionId;
    public bool bRestartable;
}

public static class RestartManager {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
}
'@

# ApplicationType values from restartmanager.h
$RM_APP_TYPE = @{
    0    = 'Unknown'
    1    = 'MainWindow'
    2    = 'OtherWindow'
    3    = 'Service'
    4    = 'Explorer'
    5    = 'Console'
    1000 = 'Critical'
}

# ---------------------------------------------------------------------------
# Core: Get-LockingProcesses
# ---------------------------------------------------------------------------

function Get-LockingProcesses {
    param([string]$FilePath)

    $sessionHandle = 0
    $sessionKey    = [Guid]::NewGuid().ToString()

    $res = [RestartManager]::RmStartSession([ref]$sessionHandle, 0, $sessionKey)
    if ($res -ne 0) {
        throw "RmStartSession failed (error $res)"
    }

    try {
        $files = [string[]]@($FilePath)
        $res = [RestartManager]::RmRegisterResources($sessionHandle, [uint32]$files.Count, $files,
            0, $null, 0, $null)
        if ($res -ne 0) {
            throw "RmRegisterResources failed (error $res)"
        }

        $pnProcInfo       = [uint32]0
        $pnProcInfoNeeded = [uint32]0
        $rebootReasons    = [uint32]0
        $procInfo         = [RM_PROCESS_INFO[]]@()

        $res = [RestartManager]::RmGetList($sessionHandle, [ref]$pnProcInfoNeeded, [ref]$pnProcInfo,
            $procInfo, [ref]$rebootReasons)

        # ERROR_MORE_DATA (234): resize and call again
        if ($res -eq 234 -and $pnProcInfoNeeded -gt 0) {
            $pnProcInfo = $pnProcInfoNeeded
            $procInfo   = New-Object 'RM_PROCESS_INFO[]' $pnProcInfo
            $res = [RestartManager]::RmGetList($sessionHandle, [ref]$pnProcInfoNeeded, [ref]$pnProcInfo,
                $procInfo, [ref]$rebootReasons)
        }

        if ($res -ne 0) {
            throw "RmGetList failed (error $res)"
        }

        $pidCache = @{}
        $result   = [System.Collections.Generic.List[object]]::new()
        $seenPids = [System.Collections.Generic.HashSet[int]]::new()

        for ($i = 0; $i -lt $pnProcInfo; $i++) {
            $p = $procInfo[$i]
            if (-not $seenPids.Add($p.Process.dwProcessId)) { continue }

            $procId = $p.Process.dwProcessId
            if (-not $pidCache.ContainsKey($procId)) {
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                $pidCache[$procId] = if ($proc) { $proc.Name } else { '<unknown>' }
            }

            $startTime = $null
            try {
                $high = $p.Process.ProcessStartTime.dwHighDateTime
                $low  = $p.Process.ProcessStartTime.dwLowDateTime
                $ft   = ([int64]$high -shl 32) -bor ([int64]$low -band 0xFFFFFFFFL)
                if ($ft -gt 0) { $startTime = [DateTime]::FromFileTime($ft) }
            } catch { $startTime = $null }

            $appType = $RM_APP_TYPE[[int]$p.ApplicationType]
            if (-not $appType) { $appType = "Unknown($($p.ApplicationType))" }

            $result.Add([PSCustomObject]@{
                Pid         = $procId
                ProcessName = $pidCache[$procId]
                AppName     = $p.strAppName
                AppType     = $appType
                StartTime   = $startTime
            })
        }

        return @($result)
    } finally {
        [void][RestartManager]::RmEndSession($sessionHandle)
    }
}

# ---------------------------------------------------------------------------
# Detail card
# ---------------------------------------------------------------------------

function Write-ProcDetail($p) {
    $started = if ($p.StartTime) { $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "  PID       : $($p.Pid)"          -ForegroundColor White
    Write-Host "  Process   : $($p.ProcessName)"  -ForegroundColor White
    Write-Host "  App Name  : $($p.AppName)"      -ForegroundColor White
    Write-Host "  Type      : $($p.AppType)"      -ForegroundColor White
    Write-Host "  Started   : $started"           -ForegroundColor White
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: view (default)
# ---------------------------------------------------------------------------

function Invoke-View {
    param([string]$FullPath)

    $data = @(Get-LockingProcesses -FilePath $FullPath)

    if ($Json) { ConvertTo-Json -InputObject $data -Depth 5; return }

    if ($data.Count -eq 0) {
        Write-Info "Not locked -- '$FullPath' is free to move/delete/rename"
        return
    }

    Write-Host ''
    foreach ($p in $data) { Write-ProcDetail $p }
    Write-Host "  $($data.Count) process(es) holding this file open" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Action: --kill
# ---------------------------------------------------------------------------

function Invoke-Kill {
    param([string]$FullPath, [bool]$SkipConfirm)

    $data = @(Get-LockingProcesses -FilePath $FullPath)

    if ($data.Count -eq 0) {
        Write-Err "Nothing has '$FullPath' locked"
        return
    }

    Write-Host ''
    Write-Host '  Processes to terminate:' -ForegroundColor White
    Write-Host ''
    foreach ($p in $data) { Write-ProcDetail $p }

    if (-not $SkipConfirm) {
        Write-Host ''
        Write-Host "  This will terminate $($data.Count) process(es)." -ForegroundColor Yellow
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

    foreach ($p in $data) {
        try {
            Stop-Process -Id $p.Pid -Force -ErrorAction Stop
            Write-Ok "Killed PID $($p.Pid) ($($p.ProcessName))"
            $killed++
        } catch {
            $msg = $_.Exception.Message
            if ($msg -like '*Access*' -or $msg -like '*privilege*' -or $msg -like '*denied*') {
                Write-Err "Access denied for PID $($p.Pid) ($($p.ProcessName)) -- try running as Administrator"
            } else {
                Write-Err "Failed to kill PID $($p.Pid) : $msg"
            }
            $errCnt++
        }
    }

    Write-Host ''
    if ($killed -gt 0) { Write-Ok   "$killed process(es) terminated" }
    if ($errCnt -gt 0) { Write-Warn "$errCnt process(es) could not be killed" }
}

# ---------------------------------------------------------------------------
# Action: view directory
# ---------------------------------------------------------------------------

function Invoke-ViewDirectory {
    param([string]$DirPath)

    $files = @(Get-ChildItem -LiteralPath $DirPath -File -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0) {
        if ($Json) { ConvertTo-Json -InputObject @() -Depth 5; return }
        Write-Info "No files found in '$DirPath'"
        return
    }

    Write-Info "Checking $($files.Count) file(s) in '$DirPath'..."

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $procs = @(Get-LockingProcesses -FilePath $f.FullName)
        $rows.Add([PSCustomObject]@{
            Name      = $f.Name
            Locked    = ($procs.Count -gt 0)
            Processes = @($procs | ForEach-Object { "$($_.ProcessName) ($($_.Pid))" })
        })
    }

    if ($Json) { ConvertTo-Json -InputObject $rows -Depth 5; return }

    $C_STATUS = 8
    $C_NAME   = 40

    Write-Host ''
    $hdr = '  ' + (Clip 'STATUS' $C_STATUS) + '  ' + (Clip 'FILE' $C_NAME) + '  PROCESS(ES)'
    $sep = '  ' + ('-' * $C_STATUS) + '  ' + ('-' * $C_NAME) + '  ' + ('-' * 30)
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkGray

    foreach ($row in $rows) {
        $status  = if ($row.Locked) { 'LOCKED' } else { 'free' }
        $color   = if ($row.Locked) { 'Red' } else { 'Green' }
        $procStr = if ($row.Processes.Count -gt 0) { $row.Processes -join ', ' } else { '-' }
        $line    = '  ' + (Clip $status $C_STATUS) + '  ' + (Clip $row.Name $C_NAME) + '  ' + $procStr
        Write-Host $line -ForegroundColor $color
    }

    $lockedCount = @($rows | Where-Object { $_.Locked }).Count
    Write-Host ''
    Write-Host "  $($rows.Count) file(s) checked, $lockedCount locked" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

function Show-Usage {
    Write-Host ''
    Write-Host '  FileLocksmith -- show and unlock processes holding a file open' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  USAGE' -ForegroundColor White
    Write-Host '    file-locksmith <file>                  show processes locking the file'          -ForegroundColor Gray
    Write-Host '    file-locksmith <file> --kill           terminate locking process(es) (confirms)' -ForegroundColor Gray
    Write-Host '    file-locksmith <file> --kill --force   skip confirmation'                        -ForegroundColor Gray
    Write-Host '    file-locksmith <dir>                   list files in dir with locked status'     -ForegroundColor Gray
    Write-Host '    file-locksmith <path> --json           JSON output'                              -ForegroundColor Gray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

if (-not $Path -or $Path -eq '') {
    Show-Usage
    exit 0
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Err "Path not found: $Path"
    exit 1
}

$item     = Get-Item -LiteralPath $Path
$fullPath = $item.FullName

if ($item.PSIsContainer) {
    if ($Kill) {
        Write-Err '--kill requires a single file, not a directory'
        exit 1
    }
    Invoke-ViewDirectory -DirPath $fullPath
} elseif ($Kill) {
    Invoke-Kill -FullPath $fullPath -SkipConfirm ([bool]$Force)
} else {
    Invoke-View -FullPath $fullPath
}
