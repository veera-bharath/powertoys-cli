# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of personal PowerShell utility scripts for Windows automation. Not related to Microsoft PowerToys.

## Folder Structure

```
FileOrganizer/
  FileOrganizer.ps1     # Organizes files into category folders by extension and keyword rules
  FileOrganizer.bat     # Interactive launcher for the above

FileOrganizerAI/
  FileOrganizerAI.ps1   # Rule-based organizer with optional Ollama AI fallback (experimental)
  FileOrganizerAI.bat   # Interactive launcher for the above

DiskCleaner/
  DiskCleaner.ps1       # Analyzes disk usage, finds duplicates and large files, delete or organize
  DiskCleaner.bat       # Interactive launcher for the above

AppUninstaller/
  AppUninstaller.ps1    # Lists installed apps with details, uninstalls interactively
  AppUninstaller.bat    # Interactive launcher (prompts whether to include Store apps)

PortManager/
  PortManager.ps1       # Inspect, kill, list, watch, and find free ports
  port.bat              # Thin launcher (command is "port")

LaunchTools/
  LaunchTools.ps1       # Launches Chrome + File Explorer to D:\Projects
  LaunchTools.bat       # Launcher for the above

Setup/
  Setup.ps1             # Installs selected scripts to a PATH-accessible location
  Setup.bat             # Launcher for the above
  scripts.json          # Registry of all installable scripts (id, displayName, source, usage)
```

## Running Scripts

```powershell
# Basic organizer — defaults to current directory
powershell -ExecutionPolicy Bypass -File FileOrganizer/FileOrganizer.ps1
powershell -ExecutionPolicy Bypass -File FileOrganizer/FileOrganizer.ps1 -Path "C:\Some\Dir" -WhatIf

# AI organizer — rule-based first, Ollama fallback with -UseAI
powershell -ExecutionPolicy Bypass -File FileOrganizerAI/FileOrganizerAI.ps1
powershell -ExecutionPolicy Bypass -File FileOrganizerAI/FileOrganizerAI.ps1 -UseAI -Model "gemma:2b" -DryRun

# Disk cleaner — analyze, find duplicates/large files, delete or organize
powershell -ExecutionPolicy Bypass -File DiskCleaner/DiskCleaner.ps1
powershell -ExecutionPolicy Bypass -File DiskCleaner/DiskCleaner.ps1 -Path "C:\Some\Dir"

# App uninstaller — list and uninstall installed apps interactively
powershell -ExecutionPolicy Bypass -File AppUninstaller/AppUninstaller.ps1
powershell -ExecutionPolicy Bypass -File AppUninstaller/AppUninstaller.ps1 -IncludeStore

# Port manager — inspect, kill, list, watch ports
powershell -ExecutionPolicy Bypass -File PortManager/PortManager.ps1 --list
powershell -ExecutionPolicy Bypass -File PortManager/PortManager.ps1 --get 3000
powershell -ExecutionPolicy Bypass -File PortManager/PortManager.ps1 --kill 3000
powershell -ExecutionPolicy Bypass -File PortManager/PortManager.ps1 --watch 3000
powershell -ExecutionPolicy Bypass -File PortManager/PortManager.ps1 --free

# Setup — installs scripts to C:\Tools\PowerToys and adds to user PATH
Setup\Setup.bat
```

## Architecture

### FileOrganizer.ps1
- Hardcoded `$ExtensionMap` maps extensions → category folders (e.g. `.pdf` → `Documents\PDF`)
- Skips the script itself and `.bat` launchers in its own folder
- Handles filename collisions by appending `_2`, `_3`, … instead of overwriting
- `-WhatIf` for dry-run preview; structured summary with by-category breakdown at the end

### FileOrganizerAI.ps1
- Classification priority: Finance/Document **keywords** → **extension map** → **Ollama AI** (fallback only) → Others
- `-UseAI` enables AI fallback; validates Ollama is installed and prompts model selection at startup
- AI called per-file only when both keyword and extension rules fail; single call with 30s timeout
- Duplicate detection via SHA256 hash (streamed — memory-safe); duplicates moved to `Duplicates\`
- Outputs `organizer.log` and `organizer-metadata.json` to the destination folder

### DiskCleaner.ps1
- Scans recursively with `Get-ChildItem -Recurse`; all results held in memory for fast menu navigation
- Extension-to-category map (`$CAT_MAP`) drives file type grouping; same categories as FileOrganizer
- Duplicate detection: groups by file size first (fast pre-filter), then SHA256 hash via `Get-FileHash`
- Deletions go to Recycle Bin via `Microsoft.VisualBasic.FileIO.FileSystem` — never permanent by default
- FileOrganizer integration: searches PATH, then `C:\Tools\PowerToys`, then sibling folder; prompts install if missing
- Menu flow: Main → File Types → file list (paginated, 18/page) | Duplicates | Large Files | Organize

### AppUninstaller.ps1
- Fully keyboard-driven TUI: Up/Down moves cursor, Left/Right pages, Space multi-selects, Ctrl+U uninstalls, Ctrl+R rescans
- Renders in-place via `[Console]::SetCursorPosition(0,0)` + fixed-height rows (no flicker); cursor hidden during draw
- Scans three registry hives for Win32/MSI apps; deduplicates by `Name|Version` key; skips `SystemComponent=1` and Windows update entries
- `EstimatedSize` (KB) → human-readable size; `InstallDate` parsed from `yyyyMMdd` registry string
- Last-used detection: builds a prefetch map (`C:\Windows\Prefetch\*.pf` → exe basename → `LastWriteTime`), then matches each app via InstallLocation exes, uninstall string exe, and name heuristics
- Selection tracked by string key (`Name|Version|Publisher`) in a `HashSet` -- survives filter/sort rebuilds
- Sort modes: Name / Size / Date / Publisher / Usage (last used); text filter by name or publisher (F to open, C to clear)
- Uninstall strategy: MSI → `msiexec /X {GUID} /passive`; EXE → launch uninstall string interactively; Store → `Remove-AppxPackage`
- Confirmation screen shows all selected apps with size and type; requires typing `YES` before proceeding
- `-IncludeStore` adds AppX packages (`SignatureKind=Store`), excluding core Windows framework packages
- Auto-elevates to admin on startup via `Start-Process -Verb RunAs` (required for HKLM key deletion and Program Files access)
- Orphaned entries (registry key present but exe missing on disk): auto-removes the registry key via `$app.RegKeyPath` (stored as `$k.PSPath` during scan) instead of trying to run the missing uninstaller
- EXE uninstall string parsing: quoted path → token-walk `Test-Path` to handle unquoted paths with spaces → `cmd /c` fallback

### PortManager.ps1
- Command is `port` (installed as `port.bat` + `port.ps1` via Setup; `id: "port"` in scripts.json)
- Uses `Get-NetTCPConnection` for TCP state data; enriches with process names via `Get-Process` (PID-cached)
- Background job (`Start-Job`) powers the spinner -- job fetches connections while main thread animates
- `--get`: detail card per connection (PID, process, local/remote addr, state), filter by port/pid/name
- `--kill` / `--fix`: shows detail cards → requires typing `YES` to confirm → `Stop-Process -Force`; `--force` skips prompt; access-denied errors suggest running as Administrator
- `--list`: table sorted by port; `--range <n>` limits rows; `--port-range <s> <e>` filters by port number
- `--watch`: polls `Get-NetTCPConnection` every 1s, prints timestamped state lines, Ctrl+C exits
- `--free`: builds a `HashSet[int]` of used ports, scans the range linearly for the first gap; default range 1024-65535
- `--json`: any command outputs `ConvertTo-Json` instead of formatted tables
- Color coding: Green=LISTEN/free, Red=ESTABLISHED, Yellow=TIME_WAIT/CLOSE_WAIT, Gray=other

### Setup.ps1
- Reads `Setup/scripts.json` for the script registry — no hardcoded script list in the PS1
- `scripts.json` fields: `id` (filename), `displayName` (shown in menu), `description`, `source` (path relative to repo root), `usage` (shown after install)
- Detects already-installed scripts and excludes them from the selection menu
- Copies `.ps1` to install folder, generates a thin `.bat` wrapper (`%*` passthrough)
- Adds install folder to user PATH (one entry regardless of how many scripts installed)

## Key Conventions

- All scripts default `$Path`/`$Source` to `(Get-Location).Path` — run from any directory without arguments
- Organizer scripts scan **root-level files only** (`Get-ChildItem -File`, no `-Recurse`)
- `.bat` launchers use `ExecutionPolicy Bypass` to avoid needing system-wide policy changes
- To add a new installable script: add an entry to `Setup/scripts.json` only — no changes to `Setup.ps1`
