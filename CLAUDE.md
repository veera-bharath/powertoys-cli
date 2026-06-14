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
    json.ps1                Format, minify, validate, query, and patch JSON files
    file-locksmith.ps1      Show and unlock processes holding a file open
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
  json.ps1
  file-locksmith.ps1
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

pt json format file.json
pt json minify file.json
pt json validate file.json
pt json query file.json user.address.city
pt json set file.json user.name "John"
cat file.json | pt json query user.name

pt file-locksmith "C:\Some\File.xlsx"
pt fl "C:\Some\File.xlsx" --kill --force
pt lock "C:\Some\Dir" --json

pt run dev
pt run build --dry
pt run deploy --continue
pt run dev --env staging
pt run --list
pt run --create build
pt run build --add --cmd "npm ci" --cond "node_modules missing"
pt run build --add --cmd "dotnet build" --timeout 120 --retry 2
pt run build --add --parallel "npm run frontend,npm run backend"
pt run build --list
pt run build --remove 2
pt run build --edit

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
- Passthrough args are normalized (`--foo` -> `-foo`) before dispatch; PowerShell 5.1 does not recognize double-dash as a named parameter prefix, only single-dash works
- Child scripts are invoked via `Invoke-Expression` (not array splatting `@passthrough`); array splatting treats every element positionally so named switches like `-create` never bind -- `Invoke-Expression` parses the command string the same way an interactive shell does; value args are single-quoted to protect spaces and `$` signs

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

### run.ps1
- Config priority: `run.config.json` in `(Get-Location).Path` first, then `run.config.json` in `$PSScriptRoot` (lib dir alongside run.ps1); `Load-Config` returns `$null` if neither exists
- `Save-Config` writes back via `ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8`; `New-LocalConfig` creates a blank `run.config.json` with an empty `scripts` object in `$PSScriptRoot` (lib dir alongside run.ps1), not the current directory
- Step normalization in `Resolve-Step`: plain string -> `{Kind='single'}`, object with `parallel` key -> `{Kind='parallel'}`, object with `cmd` key -> `{Kind='single'}` with optional `Condition`, `Timeout`, and `Retry`; `$raw.PSObject.Properties['if'].Value` used to safely read the `if` key (reserved word in PS statement position)
- `Invoke-Step` pipes through `Out-Host` (`Invoke-Expression $Cmd | Out-Host`) to prevent stdout leaking into the function's pipeline return stream -- without this, `$code = Invoke-Step ...` receives an array like `@("output-line", 0)` and `$array -ne 0` is truthy even on success
- `$global:LASTEXITCODE = 0` is reset before each `Invoke-Expression` call -- cmdlets do not update `$LASTEXITCODE`, so a stale non-zero value from a prior external process bleeds through otherwise
- Timeout steps use `Start-Job` + `Wait-Job -Timeout`; the job script block receives `$cmd` and `$dir` as arguments and calls `Set-Location $dir` to inherit the working directory (PS jobs start in the user profile by default); param named `$StepTimeout` (not `$Timeout`) to avoid conflict with the top-level `$Timeout` param
- Parallel steps also use `Start-Job`; output is streamed live via a 150ms polling loop (`Receive-Job` without `-Wait`) and printed with a color-coded `[N]` prefix per command; jobs are cleaned up in a `finally` block so Ctrl+C doesn't leave orphans; the parallel group exit code is 0 only if all jobs exit 0
- `Resolve-Step` handles `parallel` as either a JSON array (saved by `Invoke-AddStep`) or a legacy comma-separated string; both produce the same `Commands` array
- Retry loop in `Invoke-Workflow`: `$maxAttempts = 1 + [math]::Max(0, $step.Retry)`; retries only on non-zero exit code; prints attempt number before each retry
- `--continue` maps to `$KeepGoing`; on step failure the workflow increments `$failCount` and continues instead of returning early; final exit code is non-zero if `$failCount -gt 0`
- `--env <profile>` resolves `pt.ps1` via `$PSScriptRoot\..\pt.ps1` and calls `& $ptScript env --profile $Env`; failure aborts the workflow before any steps run
- `Show-Workflows` uses `Get-Member -MemberType NoteProperty` to enumerate workflow names from the `scripts` object returned by `ConvertFrom-Json`
- `Invoke-Create`: validates name against `^[a-zA-Z][a-zA-Z0-9_-]*$`, rejects duplicates, calls `New-LocalConfig` if no config exists, adds an empty array for the new workflow name
- `Invoke-AddStep`: `[string]$Parallel` is a comma-separated string (not `[string[]]`) to avoid PS5.1 positional arg binding conflicts; split and trimmed at runtime; requires minimum 2 entries for parallel; validates `--cond` syntax via `Test-ConditionSyntax` (warns but does not block on unrecognized expressions); builds plain string step when no options set, otherwise builds PSCustomObject with `Add-Member -NotePropertyName 'if'` (hashtable literal `@{ if = ... }` is ambiguous with the PS `if` keyword); updates the array via `$cfg.Data.scripts.PSObject.Properties[$name].Value = $newArray`
- `Invoke-RemoveStep`: removes by 1-based index; rebuilds array with a `for` loop skipping the target index; saves config
- `Invoke-EditWorkflow`: interactive `Read-Host` loop; shows `Show-WorkflowDetail`, prompts for step number, then `E` (edit) / `D` (delete) / `Q` (quit); edit prompts for each field individually, blank input keeps the current value; rebuilds and saves the step on confirmation
- Main dispatch order: `--create` (no config required) -> `--list` with no workflow name -> error if no workflow name -> `--list` with workflow name -> `--add` -> `--remove` -> `--edit` -> execute workflow

### json.ps1
- Stdin detection: `[Console]::IsInputRedirected` is guarded by a file-presence check on `$Arg1` -- if `$Arg1` ends with `.json` or resolves to an existing file, stdin is skipped; this prevents `[Console]::In.ReadToEnd()` from blocking in non-interactive shells
- When stdin is active, positional args shift: `$Arg1` = key path, `$Arg2` = value (instead of file, key, value)
- `Query-Json` returns `{Found, Value}` wrapper so a JSON `null` value is distinguishable from a missing key
- `Set-JsonValue` coerces the raw string value to bool/null/long/double/array/object/string before writing; intermediate nodes are created as empty PSCustomObjects if the path doesn't exist
- JSON array/object literals (`[...]` / `{...}`) are detected by their leading character before the type-switch and parsed via `ConvertFrom-Json`; the result is cast to `[object[]]` for arrays because `ConvertFrom-Json` returns a PS-decorated `Object[]` that `ConvertTo-Json` misserialises as `{value,Count}` without the cast
- Empty array assignment uses a direct `if` statement (not an `if`-expression) because an empty `[object[]]` output through a PS pipeline expression is silently lost, making the variable capture `$null` instead of `@()`
- All serialisation uses `ConvertTo-Json -Depth 20` to avoid truncation on deeply nested structures
- File writes use `Set-Content -Encoding utf8` (consistent with run.ps1)
- Operations that produce output (format, minify, query) write to stdout via `Write-Output` so they are pipeable; set writes status to the host via `Write-Ok`

### file-locksmith.ps1
- Detection via the Windows Restart Manager API (`rstrtmgr.dll`), called through `Add-Type -TypeDefinition` C# `DllImport` -- the first P/Invoke in this repo (`disk-cleaner.ps1`'s `Microsoft.VisualBasic.FileIO` is not a pattern fit for this)
- `Get-LockingProcesses`: `RmStartSession` -> `RmRegisterResources` (single file) -> `RmGetList` (two-call pattern: first call with `pnProcInfo=0` to read `pnProcInfoNeeded`, then re-call with an `RM_PROCESS_INFO[]` sized to that count if `ERROR_MORE_DATA` (234) is returned) -> `RmEndSession` in a `finally` block
- `ApplicationType` int is decoded via the `$RM_APP_TYPE` lookup table (MainWindow/OtherWindow/Service/Explorer/Console/Critical/Unknown); `ProcessStartTime` `FILETIME` is reassembled from `dwHighDateTime`/`dwLowDateTime` and converted via `[DateTime]::FromFileTime`
- Process names enriched via PID-cached `Get-Process`, same pattern as `port-manager.ps1`
- Single-element-array gotcha: `Get-LockingProcesses` results are re-wrapped with `@(...)` at every call site -- PowerShell unwraps a one-element array returned from a function, so `$data.Count` would otherwise be `$null`
- File mode: `Resolve-Path`/`Get-Item` resolves the path; not-locked vs locked detail cards (PID, Process, App Name, Type, Started) styled like `port-manager.ps1`'s `Write-ConnDetail`
- `--kill`: same "Type YES to confirm" flow as `port-manager.ps1`'s `Invoke-Kill`, including the Access-Denied message detection; `--force` skips the prompt
- Directory mode (`Invoke-ViewDirectory`): `Get-ChildItem -File` (top-level only, not recursive) calls `Get-LockingProcesses` once per file and renders a STATUS/FILE/PROCESS(ES) table (green=free, red=LOCKED); `--kill` is rejected on a directory
- `--json` uses `ConvertTo-Json -InputObject $data` (not piped) so an empty array serialises as `[]` instead of producing no output
