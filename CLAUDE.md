# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal PowerShell utility scripts for Windows automation, unified under a single `pt` CLI command. Not related to Microsoft PowerToys.

## Folder Structure

```
scripts/
  lib/
    file-organizer.ps1      Organizes files into category folders by extension
    file-organizer-ai.ps1   Rule-based organizer with optional Ollama AI fallback (experimental)
    disk-cleaner.ps1        Analyzes disk usage, finds duplicates and large files
    app-uninstaller.ps1     Lists installed apps with details, uninstalls interactively
    port-manager.ps1        Inspect, kill, list, watch, and find free ports
    env-manager.ps1         Manage environment variables, PATH, .env files, and profiles
    search.ps1              Fast recursive file and content search
  pt.ps1                    Command router -- reads commands.json, delegates to lib scripts
  pt.bat                    Thin CMD launcher for pt.ps1
  commands.json             Command registry: name, version, aliases, script path, help text

install.bat                 Prompts for install path, calls install.ps1
install.ps1                 Copies scripts/ to install path, manages user PATH
uninstall.bat               Prompts for install path, calls uninstall.ps1
uninstall.ps1               Removes install dir from PATH and deletes it
```

## Installed Layout (e.g. C:\Tools\PowerToys, on user PATH)

```
lib\
  file-organizer.ps1
  file-organizer-ai.ps1
  disk-cleaner.ps1
  app-uninstaller.ps1
  port-manager.ps1
  env-manager.ps1
  search.ps1
pt.ps1
pt.bat
commands.json
```

`pt.ps1` uses `$PSScriptRoot` to locate `commands.json` and resolve lib script paths, so this layout works identically in both installed and dev (repo) modes.

## Running Scripts

```powershell
# Via pt (works from repo scripts/ or from install path)
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
pt port --kill 3000 --force
pt port --watch 3000
pt port --free --s 3000 --e 9000

pt env --list
pt env --list --user
pt env --get PATH
pt env --set MY_VAR=hello
pt env --set MY_VAR=hello --system
pt env --delete MY_VAR
pt env --temp MY_VAR=hello
pt env --path --list
pt env --path --list --system
pt env --path --get Python
pt env --path --add "C:\Tools\X1" "C:\Tools\X2"
pt env --path --remove "C:\Tools\X1" "C:\Tools\X2" --system
pt env --load .env
pt env --export .env
pt env --profile dev
pt env --generate node

pt search readme.md --path "D:\Projects"
pt search "TODO" --content --code --path "D:\Projects\MyApp"
pt search error --logs --limit 20
pt search *.json --path "D:\Projects" --excl node_modules,dist

# From the repo without installing
powershell -ExecutionPolicy Bypass -File scripts\pt.ps1 help
powershell -ExecutionPolicy Bypass -File scripts\pt.ps1 disk-cleaner -Path "C:\Some\Dir"
```

## Key Conventions

- No non-ASCII characters in `.ps1` or `.bat` files (PS5.1 + CMD corrupt them)
- All lib scripts default `$Path`/`$Source` to `(Get-Location).Path` -- callable from any directory
- Organizer scripts scan root-level files only (`Get-ChildItem -File`, no `-Recurse`)
- To add a new command: add entry to `scripts/commands.json` + drop `.ps1` in `scripts/lib/` -- no other files change
- To bump a script version: increment `version` in its `commands.json` entry; `install.ps1` will overwrite it on next run

## Architecture

### pt.ps1
- No `param()` block -- uses `$args` directly so all arguments pass through unmodified to child scripts
- `$PSScriptRoot` is the base for all path resolution; no hardcoded paths anywhere
- `--debug` is consumed here and never forwarded; prints command name, resolved script path, and forwarded args
- Subcommand lookup: exact `name` match first, then `aliases`; typo recovery via substring match

### commands.json
- Top-level `version` mirrors the overall release; per-command `version` is what `install.ps1` compares
- `script` paths are relative to `pt.ps1` location (e.g. `lib/file-organizer.ps1`)
- `help` is an array of strings rendered line-by-line by `pt help <command>`

### install.ps1
- Always overwrites `pt.ps1` and `pt.bat` (launcher should always be current)
- Per lib script: reads source vs installed `commands.json`, compares `version` field
  - Same version: skip (prints `ok`)
  - Different version: overwrite (prints `UPDATE vX -> vY`)
  - Not present: copy (prints `ADD`)
- Writes `commands.json` last -- only reflects scripts that were successfully copied
- Idempotent: safe to re-run at any time

### file-organizer.ps1
- `$ExtensionMap` maps extensions to category folders (e.g. `.pdf` -> `Documents\PDF`)
- Skips the script itself and `.bat` files in its own folder
- Filename collisions resolved by appending `_2`, `_3`, ... -- never overwrites
- `-WhatIf` previews without moving; summary shows by-category breakdown

### file-organizer-ai.ps1
- Classification priority: Finance/Document keywords -> extension map -> Ollama AI -> Others
- `-UseAI` enables Ollama fallback; validates install and prompts model selection at startup
- AI called per-file only when keyword and extension rules both fail; 30s timeout per call
- Duplicate detection via SHA256 (streamed, memory-safe); duplicates go to `Duplicates\`
- Outputs `organizer.log` and `organizer-metadata.json` to the destination folder

### disk-cleaner.ps1
- Scans recursively; all results held in memory for fast paginated menu navigation
- `$CAT_MAP` drives extension-to-category grouping
- Duplicate detection: size pre-filter then SHA256 via `Get-FileHash`
- Deletions via `Microsoft.VisualBasic.FileIO.FileSystem` (Recycle Bin, never permanent)
- Menu flow: Main -> File Types | Duplicates | Large Files | Organize

### app-uninstaller.ps1
- Keyboard-driven TUI rendered in-place via `[Console]::SetCursorPosition` (no flicker)
- Scans three registry hives for Win32/MSI apps; deduplicates by `Name|Version`
- Last-used detection via prefetch map (`C:\Windows\Prefetch\*.pf`)
- Sort: Name / Size / Date / Publisher / Usage; filter by name or publisher
- Uninstall: MSI -> `msiexec /X {GUID} /passive`; EXE -> uninstall string; Store -> `Remove-AppxPackage`
- Orphaned entries (exe missing on disk): registry key removed automatically
- Auto-elevates to admin on startup

### port-manager.ps1
- `Get-NetTCPConnection` for TCP state; process names enriched via PID-cached `Get-Process`
- Background job (`Start-Job`) fetches connections while main thread shows spinner
- `--kill`/`--fix`: shows detail card, requires `YES` to confirm; `--force` skips prompt
- `--free`: `HashSet[int]` of used ports, linear scan for first gap in range
- `--json`: `ConvertTo-Json` output for any command
- Color: Green=LISTEN/free, Red=ESTABLISHED, Yellow=TIME_WAIT/CLOSE_WAIT, Gray=other

### env-manager.ps1
- All env reads/writes via `[System.Environment]::GetEnvironmentVariable` / `SetEnvironmentVariable` with explicit `User` or `Machine` target
- Positional args use `ValueFromRemainingArguments` (`[string[]]$Values`) so `--path --add` accepts any number of directories
- `--path` is checked first in the dispatch so `--path --list` and `--path --get` don't fall into the top-level `--list`/`--get` branches
- PATH operations read, mutate, then write in one call -- no partial writes on multi-dir input
- Sensitive masking: any var whose name contains `KEY`, `SECRET`, `TOKEN`, `PASSWORD`, `PASS`, `PWD`, `CREDENTIAL`, or `AUTH` has its value partially masked in all output
- Profiles stored as JSON files in `<install-dir>\env-profiles\<name>.json`; `Get-ProfileDir` resolves via `$PSScriptRoot`
- `--path --list` deduplication: shared `HashSet[string]` (OrdinalIgnoreCase) across User then System -- cross-scope dups are tagged `[DUP]`
- `--generate` templates are defined in the `$ENV_TEMPLATES` hashtable at script scope; add new keys there to add new templates

### search.ps1
- Two modes: filename (default) and content (`--content`); dispatched in main body based on `$Content` switch
- BFS traversal via `[System.Collections.Generic.Queue[string]]`; stops as soon as `$Limit` results are collected -- never scans more than needed
- File enumeration via `[System.IO.Directory]::EnumerateFiles` (lazy .NET enumerator, faster than `Get-ChildItem`)
- `$SKIP_DIRS` is a `HashSet[string]` (OrdinalIgnoreCase) checked against each subdirectory name before enqueueing; built-in list covers `node_modules`, `.git`, `bin`, `obj`, `dist`, and ~10 others
- `--excl` splits on comma, trims, and adds entries into `$SKIP_DIRS` at runtime before the search starts
- Smart filters (`--logs`, `--json`, `--code`) resolve to extension glob arrays passed as `$Include` to search functions; `@('*')` means no filter
- Filename mode: when `$Include = @('*')`, uses `"*$Pattern*"` as the EnumerateFiles glob so the OS filters by name; when a type filter is active, enumerates by extension glob then checks name with `-like "*$Pattern*"`
- Content mode: `Select-String` per file; results sorted by match count desc then modified desc
- Results use `[System.Collections.Generic.List[object]]` for O(1) appends (avoids PS array `+=` realloc)
- `--open <n>` calls `Start-Process` on the nth result path -- opens with whatever the OS default app is
- Parameter name collision avoided: JSON file filter is `$JsonFiles` with `[Alias('json')]`; JSON output is `$Jsonout` -- both `-json` and `-jsonout` are unambiguous in PS5.1 splatting
