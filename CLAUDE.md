# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of personal PowerShell utility scripts for Windows automation, unified under a single `pt` CLI command. Not related to Microsoft PowerToys.

## Folder Structure

```
scripts/
  lib/
    file-organizer.ps1      # Organizes files into category folders by extension
    file-organizer-ai.ps1   # Rule-based organizer with optional Ollama AI fallback (experimental)
    disk-cleaner.ps1        # Analyzes disk usage, finds duplicates and large files
    app-uninstaller.ps1     # Lists installed apps with details, uninstalls interactively
    port-manager.ps1        # Inspect, kill, list, watch, and find free ports
  pt.ps1                    # Unified CLI entry point (command router)
  pt.bat                    # Thin CMD launcher for pt.ps1
  commands.json             # Command registry: name, version, aliases, script path, help

install.bat                 # Prompts for install path, calls install.ps1
install.ps1                 # Copies scripts/ to install path, adds to user PATH
uninstall.bat               # Prompts for install path, calls uninstall.ps1
uninstall.ps1               # Removes install path from PATH and deletes the directory
```

## Installed Structure (e.g. C:\Tools\PowerToys)

```
C:\Tools\PowerToys\         <- on user PATH, pt.bat accessible directly
  lib\
    file-organizer.ps1
    file-organizer-ai.ps1
    disk-cleaner.ps1
    app-uninstaller.ps1
    port-manager.ps1
  pt.ps1
  pt.bat
  commands.json
```

## Running Scripts

```powershell
# Via the pt CLI (installed or directly from scripts/)
pt file-organizer
pt fo -Path "C:\Some\Dir" -WhatIf

pt file-organizer-ai
pt foai -Source "C:\Some\Dir" -UseAI -Model "gemma:2b" -DryRun

pt disk-cleaner
pt dc -Path "C:\Some\Dir"

pt app-uninstaller
pt au -IncludeStore

pt port --list
pt port --get 3000
pt port --kill 3000
pt port --watch 3000
pt port --free

# Directly from the repo (dev mode)
powershell -ExecutionPolicy Bypass -File scripts\pt.ps1 help
powershell -ExecutionPolicy Bypass -File scripts\pt.ps1 disk-cleaner -Path "C:\Some\Dir"

# Install / uninstall
install.bat
uninstall.bat
```

## Architecture

### pt.ps1
- No `param()` block -- uses `$args` directly so all arguments pass through unmodified to child scripts
- `$PSScriptRoot` is always the base for resolving `commands.json` and lib scripts; works identically in dev and installed modes
- `--debug` is consumed by `pt.ps1` and never forwarded; shows routing info (command, script path, args)
- `Get-Suggestions` does substring match on name and aliases for typo recovery
- Plugin support: drops a `.json` next to `commands.json` -- `pt.ps1` loads all `*.json` files in a `plugins\` subdirectory

### commands.json
- Top-level `version` field tracks the overall release version
- Per-command `version` field is used by `install.ps1` to decide skip / update / add on re-run
- `script` paths are relative to `$PSScriptRoot` of `pt.ps1` (e.g. `lib/file-organizer.ps1`)
- To add a new command: add an entry here and drop the `.ps1` in `scripts/lib/` -- no changes to `pt.ps1` or `install.ps1`

### install.ps1
- Always overwrites `pt.ps1`, `pt.bat` (launcher files should always be current)
- Per lib script: compares `version` field in source vs installed `commands.json`; skips if equal, updates if changed, adds if absent
- Writes `commands.json` last so it only reflects scripts that were successfully copied
- Idempotent: safe to re-run at any time

### file-organizer.ps1
- Hardcoded `$ExtensionMap` maps extensions to category folders (e.g. `.pdf` -> `Documents\PDF`)
- Skips the script itself and `.bat` launchers in its own folder
- Handles filename collisions by appending `_2`, `_3`, ... instead of overwriting
- `-WhatIf` for dry-run preview; structured summary with by-category breakdown at the end

### file-organizer-ai.ps1
- Classification priority: Finance/Document **keywords** -> **extension map** -> **Ollama AI** (fallback only) -> Others
- `-UseAI` enables AI fallback; validates Ollama is installed and prompts model selection at startup
- AI called per-file only when both keyword and extension rules fail; single call with 30s timeout
- Duplicate detection via SHA256 hash (streamed -- memory-safe); duplicates moved to `Duplicates\`
- Outputs `organizer.log` and `organizer-metadata.json` to the destination folder

### disk-cleaner.ps1
- Scans recursively with `Get-ChildItem -Recurse`; all results held in memory for fast menu navigation
- Extension-to-category map (`$CAT_MAP`) drives file type grouping
- Duplicate detection: groups by file size first (fast pre-filter), then SHA256 hash via `Get-FileHash`
- Deletions go to Recycle Bin via `Microsoft.VisualBasic.FileIO.FileSystem` -- never permanent by default
- Menu flow: Main -> File Types -> file list (paginated, 18/page) | Duplicates | Large Files | Organize

### app-uninstaller.ps1
- Fully keyboard-driven TUI: Up/Down moves cursor, Left/Right pages, Space multi-selects, Ctrl+U uninstalls, Ctrl+R rescans
- Renders in-place via `[Console]::SetCursorPosition(0,0)` + fixed-height rows (no flicker); cursor hidden during draw
- Scans three registry hives for Win32/MSI apps; deduplicates by `Name|Version` key
- Last-used detection via prefetch map (`C:\Windows\Prefetch\*.pf`)
- Sort modes: Name / Size / Date / Publisher / Usage; text filter by name or publisher
- Uninstall strategy: MSI -> `msiexec /X {GUID} /passive`; EXE -> launch uninstall string; Store -> `Remove-AppxPackage`
- Requires Administrator elevation (auto-prompted on launch)

### port-manager.ps1
- Uses `Get-NetTCPConnection` for TCP state data; enriches with process names via `Get-Process` (PID-cached)
- Background job (`Start-Job`) powers the spinner -- job fetches connections while main thread animates
- `--kill` / `--fix`: requires typing `YES` to confirm; `--force` skips prompt
- `--free`: builds a `HashSet[int]` of used ports, scans the range linearly for the first gap
- `--json`: outputs `ConvertTo-Json` instead of formatted tables
- Color coding: Green=LISTEN/free, Red=ESTABLISHED, Yellow=TIME_WAIT/CLOSE_WAIT, Gray=other

## Key Conventions

- All scripts default `$Path`/`$Source` to `(Get-Location).Path` -- run from any directory without arguments
- Organizer scripts scan **root-level files only** (`Get-ChildItem -File`, no `-Recurse`)
- `.bat` launchers use `ExecutionPolicy Bypass` to avoid needing system-wide policy changes
- No non-ASCII characters in `.ps1` or `.bat` files (PS5.1 + CMD corrupt them)
- To add a new command: add entry to `scripts/commands.json` + drop `.ps1` in `scripts/lib/`
