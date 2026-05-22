# PowerToys CLI

A collection of personal PowerShell utility scripts for Windows automation, unified under a single `pt` command.

> **Not affiliated with or related to Microsoft PowerToys.**

---

## Commands

| Subcommand | Aliases | Description |
|---|---|---|
| `pt file-organizer` | `fo`, `organize` | Sort files into category folders by extension |
| `pt file-organizer-ai` | `foai` | Rule-based organizer with optional Ollama AI fallback *(experimental)* |
| `pt disk-cleaner` | `dc`, `clean` | Analyze disk usage, find duplicates and large files |
| `pt app-uninstaller` | `au`, `apps` | Interactive TUI to browse, select, and uninstall installed apps |
| `pt port` | `pm` | Inspect, kill, list, watch, and find free ports |
| `pt env` | `envm` | Manage environment variables, PATH, .env files, and profiles |
| `pt search` | `find` | Fast recursive file and content search |
| `pt run` | `workflow` | Execute predefined workflow scripts from `run.config.json` |
| `pt json` | `js` | Format, minify, validate, query, and patch JSON files |

---

## Requirements

- Windows PowerShell 5.1 or later
- [Ollama](https://ollama.com/download) — only required if using `pt file-organizer-ai -UseAI`

---

## Installation

```
install.bat
```

Prompts for an install path (default `C:\Tools\PowerToys`), copies all scripts and the `pt` launcher there, and adds the path to your user `PATH`. Open a new terminal after this completes.

Re-running `install.bat` is safe — scripts are skipped if already at the current version, updated if the version changed, and added if new.

To remove:

```
uninstall.bat
```

---

## Project Structure

```
scripts/
  lib/
    file-organizer.ps1
    file-organizer-ai.ps1
    disk-cleaner.ps1
    app-uninstaller.ps1
    port-manager.ps1
    env-manager.ps1
    search.ps1
    json.ps1
  pt.ps1            command router
  pt.bat            CMD launcher
  commands.json     command registry (names, aliases, versions, help)

install.bat         prompts for path, calls install.ps1
install.ps1         copies scripts/ to install path, manages PATH
uninstall.bat       prompts for path, calls uninstall.ps1
uninstall.ps1       removes install path from PATH and deletes the directory
```

**Installed layout** (`C:\Tools\PowerToys` on PATH):

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
pt.ps1
pt.bat
commands.json
```

### Adding a new command

1. Drop a `.ps1` into `scripts/lib/`
2. Add an entry to `scripts/commands.json`
3. Re-run `install.bat`

---

## file-organizer

Scans the root level of a directory and moves files into category subfolders based on their extension.

```powershell
pt file-organizer
pt fo -Path "C:\Users\Me\Downloads"
pt fo -WhatIf
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Path` | Current directory | Directory to organize |
| `-WhatIf` | Off | Preview actions without moving anything |

### Extension Mappings

| Category | Extensions |
|---|---|
| `Images` | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.webp` `.svg` `.avif` `.heic` `.tiff` `.ico` |
| `Videos` | `.mp4` `.mkv` `.flv` `.wmv` `.avi` `.mov` `.webm` `.m4v` |
| `Music` | `.mp3` `.wav` `.wma` `.aac` `.flac` `.m4a` `.ogg` |
| `Apps` | `.exe` `.msi` `.msix` `.bat` |
| `Archives` | `.zip` `.rar` `.7z` `.tar` `.gz` `.bz2` `.xz` |
| `Documents\PDF` | `.pdf` |
| `Documents\Word` | `.doc` `.docx` `.rtf` |
| `Documents\Excel` | `.xls` `.xlsx` `.csv` |
| `Documents\PowerPoint` | `.ppt` `.pptx` |
| `Documents\Text` | `.txt` `.md` `.log` |
| `Documents\Email` | `.eml` |

Files with no matching extension are listed as **Skipped**. Filename collisions are resolved by appending `_2`, `_3`, etc. — nothing is overwritten.

### Output

```
  File Organizer
  Path : C:\Users\Me\Downloads
  ----------------------------------------------------

  +  invoice_march.pdf   ->  Documents\PDF
  +  photo.jpg           ->  Images
  -  data.parquet        (no mapping)

  SUMMARY
  ----------------------------------------------------
  Total found    3
  Moved          2
  Skipped        1

  BY CATEGORY
  ----------------------------------------------------
  Documents\PDF             1 file
  Images                    1 file
```

---

## file-organizer-ai *(experimental)*

Classifies files using a layered strategy:

1. **Keyword rules** — filename keywords mapped to Finance or Documents categories
2. **Extension map** — same mapping as file-organizer
3. **Ollama AI fallback** — only when both rules above fail (requires `-UseAI`)
4. **Others** — catch-all for anything unclassified

Also detects duplicate files via SHA256 hash and moves them to a `Duplicates\` subfolder.

```powershell
pt file-organizer-ai
pt foai -Source "C:\Users\Me\Downloads" -DryRun
pt foai -UseAI -Model "gemma:2b"
pt foai -Source "D:\Docs" -Destination "D:\Sorted" -UseAI -DryRun
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Source` | `%USERPROFILE%\Downloads` | Directory to scan (root-level files only) |
| `-Destination` | `<Source>\Organized` | Root folder where organized files land |
| `-UseAI` | Off | Enable Ollama AI fallback for unclassified files |
| `-Model` | `gemma:2b` | Ollama model to use with `-UseAI` |
| `-DryRun` | Off | Preview all actions without moving anything |

### Keyword Rules

| Category | Keywords (filename match) |
|---|---|
| `Finance` | invoice, bill, receipt, payment, tax, salary, payslip, statement, budget, expense, finance, bank, ledger, transaction, refund, purchase, order, quote, payroll |
| `Documents` | report, resume, cv, letter, contract, agreement, proposal, memo, manual, guide, notes, summary, minutes, agenda, policy |

### Outputs

- **`organizer.log`** — timestamped log of every action
- **`organizer-metadata.json`** — per-file record with category, size, dates, AI flag, original and new paths

### AI fallback

Requires [Ollama](https://ollama.com/download) installed and running. Pull a model first:

```
ollama pull gemma:2b
```

If the specified model is not installed, the script lists available models and lets you choose interactively.

---

## disk-cleaner

Recursively scans a directory and provides an interactive menu to analyze, clean, and organize files.

```powershell
pt disk-cleaner
pt dc -Path "C:\Users\Me\Downloads"
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Path` | Current directory | Directory to analyze |

### Menu

```
  Analyzed: 1,234 files   Total size: 15.6 GB
  [!] 45 duplicate groups - 2.3 GB reclaimable
  [!] Largest file: movie.mkv (4.1 GB)

  1.  File Types      - breakdown by category with size bar
  2.  Duplicate Files - groups of identical files, wasted space
  3.  Large Files     - top 20 files by size
  4.  Organize        - run file-organizer on this path
  R.  Re-scan
  Q.  Quit
```

### Duplicate Files view

Groups files by SHA256 hash. For each group, shows file count and wasted space.

- **`D <group>`** — keep the newest copy, send the rest to Recycle Bin
- **`<group>`** — inspect files in the group and delete selectively

### File list options

| Input | Action |
|---|---|
| `<number>` | Send that file to Recycle Bin (with confirmation) |
| `O <number>` | Open file location in Explorer |
| `N` / `P` | Next / previous page |
| `B` | Back |

> All deletions go to the **Recycle Bin** — nothing is permanently deleted.

---

## app-uninstaller

Interactive terminal UI for browsing and uninstalling installed applications. Fully keyboard-driven.

```powershell
pt app-uninstaller
pt au -IncludeStore
```

> Automatically requests admin elevation on launch.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-IncludeStore` | Off | Also list Microsoft Store (AppX) packages |

### Keyboard Controls

| Key | Action |
|---|---|
| `Up` / `Down` | Move cursor |
| `Left` / `Right` | Previous / next page |
| `Space` | Toggle selection |
| `Ctrl+U` | Uninstall selected apps |
| `Ctrl+R` | Rescan |
| `F` / `C` | Open / clear filter |
| `S` | Cycle sort: Name → Size → Date → Publisher → Usage |
| `Q` | Quit |

### Columns

| Column | Source |
|---|---|
| Name | `DisplayName` registry value |
| Publisher | `Publisher` registry value |
| Version | `DisplayVersion` registry value |
| Installed | `InstallDate` (parsed from `yyyyMMdd`) |
| Size | `EstimatedSize` (converted from KB) |
| Type | `[MSI]` / `[EXE]` / `[Str]` Store |
| Last Used | Most recent prefetch timestamp in `C:\Windows\Prefetch\` |

### Uninstall behaviour

| Type | Method |
|---|---|
| MSI | `msiexec /X {GUID} /passive` |
| EXE | Launches the app's own uninstaller |
| Store | `Remove-AppxPackage` |
| Orphaned | Exe missing on disk — registry entry cleaned up automatically |

Requires typing `YES` (uppercase) on the confirmation screen before anything is removed.

---

## port

Inspect, kill, list, watch, and find free TCP ports.

```powershell
pt port --get 3000
pt port --kill 3000
pt port --list
pt port --watch 3000
pt port --free
```

### Commands

| Command | Description |
|---|---|
| `--get <port>` | Show all connections on a port |
| `--get --pid <id>` | Show connections by PID |
| `--get --name <name>` | Show connections by process name |
| `--kill <port>` | Kill process using a port — prompts `YES` to confirm |
| `--kill --pid <id>` | Kill by PID |
| `--kill --name <name>` | Kill by process name |
| `--kill <port> --force` | Kill without confirmation prompt |
| `--fix <port>` | Alias for `--kill` |
| `--list` | Table of all active TCP connections |
| `--list --range <n>` | Limit to first N results |
| `--list --s <start> --e <end>` | Filter by port number range |
| `--watch <port>` | Poll every second, print state changes — `Ctrl+C` exits |
| `--free` | Find the first free port in 1024–65535 |
| `--free --s <start> --e <end>` | Find a free port in a specific range |
| `--json` | Output as JSON (combine with any command) |

### List output

```
  PID      PORT    PROCESS                 STATE          LOCAL ADDRESS
  -------  ------  ----------------------  -------------  ----------------------
  4        80      System                  Listen         :::80
  2840     59908   svchost                 Established    192.168.1.7:59908
  0        60740   Idle                    TimeWait       127.0.0.1:60740
```

### Color coding

| Color | Meaning |
|---|---|
| Green | `Listen` / free port |
| Red | `Established` |
| Yellow | `TimeWait` / `CloseWait` |
| Gray | Other states |

---

## env

Manage Windows environment variables, PATH entries, `.env` files, and named environment profiles.

```powershell
pt env --list
pt env --get NODE_ENV
pt env --set MY_VAR=hello
pt env --path --list
pt env --profile dev
```

### Variable commands

| Command | Description |
|---|---|
| `--list [--user\|--system] [--json]` | List all variables with scope. Default: both. |
| `--get <NAME>` | Show User, System, and Session values side-by-side |
| `--set NAME=VALUE [--system]` | Set a variable. Default scope: User. Prompts `YES` on overwrite. |
| `--delete <NAME> [--system]` | Delete a variable. Prompts `YES` to confirm. |
| `--temp NAME=VALUE` | Set a variable for the current session only |

Sensitive values are automatically masked in output when the name contains `KEY`, `SECRET`, `TOKEN`, or `PASSWORD`.

### PATH commands

| Command | Description |
|---|---|
| `--path --list [--user\|--system]` | List PATH entries with `[OK]` / `[MISSING]` / `[DUP]` tags. Default: User. |
| `--path --get <term> [--user\|--system]` | Search PATH entries by name |
| `--path --add "C:\A" "C:\B" [--system]` | Add one or more directories. Skips duplicates, warns if path missing. |
| `--path --remove "C:\A" "C:\B" [--system]` | Remove one or more directories |

### .env file commands

| Command | Description |
|---|---|
| `--load <file.env>` | Load `KEY=VALUE` pairs into User scope. Skips comments and blank lines. |
| `--export <file.env>` | Export all User variables to a `.env` file |

### Profiles

Store named sets of variables as JSON files in `<install-dir>\env-profiles\`:

```json
{
  "API_URL": "http://localhost:3000",
  "NODE_ENV": "development",
  "DB_URL": "postgresql://localhost/mydb"
}
```

| Command | Description |
|---|---|
| `--profile` | List available profiles |
| `--profile <name>` | Apply all variables from the named profile into User scope |

### .env templates

```powershell
pt env --generate node      # Node.js starter
pt env --generate python    # Flask/Python starter
pt env --generate dotnet    # ASP.NET Core starter
```

Writes a `.env` file in the current directory. Load it with `pt env --load .env`.

---

## search

Fast recursive file and content search with smart type filters and noise-directory skipping.

```powershell
pt search readme.md
pt search readme.md --path "D:\Projects"
pt search "TODO" --content --code
pt search error --logs --path "C:\Logs" --limit 20
pt find *.json --path "D:\Projects\MyApp"
```

### Commands

| Command | Description |
|---|---|
| `pt search <query>` | Search filenames recursively (supports wildcards: `*.json`) |
| `pt search <query> --content` | Search inside files, show matching lines with line numbers |

### Flags

| Flag | Description |
|---|---|
| `--content` | Switch to content search mode |
| `--logs` | Restrict to `.log`, `.txt` files |
| `--json` | Restrict to `.json` files |
| `--code` | Restrict to `.js`, `.ts`, `.cs`, `.ps1` files |
| `--path <dir>` | Root directory to search. Default: current directory |
| `--limit <n>` | Cap number of results. Default: `50` |
| `--open <n>` | Open result number `n` with its default app |
| `--excl <list>` | Comma-separated directory or filename patterns to exclude (e.g. `node_modules,dist`) |
| `--jsonout` | Output results as JSON |

### Output

```
  Found 3 result(s)  [mode: filename]

  [1] AutoFlow\README.md        2026-05-11 12:03
  [2] PowerToys\README.md       2026-05-19 12:05
  [3] Portfolio\README.md       2026-05-06 23:25
```

Content mode shows matching lines:

```
  Found 2 result(s)  [mode: content]

  [1] src\app.ts  2026-05-18 09:14  3 match(es)
  Line 12: // TODO: add auth middleware
  Line 45: // TODO: rate limiting
  Line 89: // TODO: error boundary
```

### Built-in skip list

The following directories are always excluded from traversal:

`node_modules` `.git` `.svn` `.vs` `.idea` `bin` `obj` `dist` `out` `build` `.next` `.nuget` `packages` `vendor` `__pycache__` `.cache`

Use `--excl` to add more at runtime:

```powershell
pt search config --path "D:\Projects" --excl dist,coverage
```

---

## run

Execute named workflows defined in a `run.config.json` file in your project directory, or a global `pt.config.json` in the install directory.

```powershell
pt run dev
pt run build --dry
pt run deploy --continue
pt run dev --env staging
pt run --list
```

### Config file

Create `run.config.json` in your project root:

```json
{
  "scripts": {
    "dev": [
      "npm install",
      "npm run dev"
    ],
    "build": [
      { "cmd": "npm ci", "if": "node_modules missing" },
      { "parallel": ["npm run frontend", "npm run backend"] },
      { "cmd": "dotnet build", "timeout": 120 }
    ],
    "lint": ["eslint src", "dotnet format --verify-no-changes"]
  }
}
```

Config is resolved in this order:
1. `run.config.json` in the current working directory
2. `pt.config.json` in the install directory (global fallback)

### Execution commands

| Command | Description |
|---|---|
| `pt run <workflow>` | Execute a named workflow |
| `pt run <workflow> --dry` | Preview all steps without executing |
| `pt run <workflow> --continue` | Keep running even if a step fails |
| `pt run <workflow> --env <name>` | Apply a `pt env` profile before running |
| `pt run --list` | List all workflows defined in the config |
| `pt run --list --jsonout` | List workflows as JSON |

### Workflow management commands

| Command | Description |
|---|---|
| `pt run --create <name>` | Create a new empty workflow (creates `run.config.json` if missing) |
| `pt run <name> --list` | Show all steps in a workflow with their index |
| `pt run <name> --add --cmd "..."` | Append a step to a workflow |
| `pt run <name> --add --cmd "..." --cond "<condition>"` | Append a conditional step |
| `pt run <name> --add --cmd "..." --timeout 30` | Append a step with a timeout (seconds) |
| `pt run <name> --add --cmd "..." --retry 2` | Append a step that retries up to N times on failure |
| `pt run <name> --add --parallel "cmd1,cmd2"` | Append a parallel step (comma-separated commands) |
| `pt run <name> --remove <n>` | Remove step number `n` from the workflow |
| `pt run <name> --edit` | Interactively edit or delete steps in a workflow |

### Step formats

| Format | Description |
|---|---|
| `"command string"` | Simple command, run inline |
| `{ "cmd": "...", "timeout": 30 }` | Command with a timeout in seconds |
| `{ "cmd": "...", "retry": 2 }` | Command retried up to N times on failure |
| `{ "cmd": "...", "if": "<condition>" }` | Conditional step — skipped when condition is false |
| `{ "parallel": ["cmd1", "cmd2"] }` | Run multiple commands concurrently |

### Condition expressions

Used in the `"if"` field of a step object:

| Expression | Runs when |
|---|---|
| `node_modules missing` | `node_modules` directory does not exist |
| `dir missing: <path>` | The specified directory does not exist |
| `file missing: <path>` | The specified file does not exist |
| `env: <VAR>` | Environment variable is set |
| `env missing: <VAR>` | Environment variable is not set |

### Output

```
  Workflow: build
  --------------------------------------------------------

  Step 1 / 3
  [>>]  Running: npm ci
npm: ...
  [OK]  Success (4.2s)

  Step 2 / 3
  [||]  Parallel group (2 commands):
         npm run frontend
         npm run backend
  [OK]  Parallel group complete (8.1s)

  Step 3 / 3
  [>>]  Running: dotnet build
  [OK]  Success (12.3s)

  --------------------------------------------------------
  [OK]  Workflow 'build' completed successfully (3 step(s)).
```

---

## json

> **Status: in progress** — core operations stable; array mutation and streaming large files not yet supported.

Format, minify, validate, query, and patch JSON from files or stdin.

```powershell
pt json format   file.json
pt json minify   file.json
pt json validate file.json
pt json query    file.json user.address.city
pt json set      file.json user.name "John"

# Pipe support -- stdin replaces the file argument
cat file.json | pt json format
cat file.json | pt json query user.address.city
cat file.json | pt json set user.name "John"
```

### Operations

| Operation | Description |
|---|---|
| `format <file>` | Pretty-print with 4-space indentation |
| `minify <file>` | Collapse to a single compact line |
| `validate <file>` | Check JSON syntax; prints error with position on failure |
| `query <file> <path>` | Extract a value by dot-notation path |
| `set <file> <path> <value>` | Update a value in-place and save the file |

### Dot-path syntax

Segments are separated by `.`. Numeric segments index into arrays.

| Path | Resolves to |
|---|---|
| `user.name` | `"Alice"` |
| `user.address.city` | `"Seattle"` |
| `user.scores.0` | First element of the `scores` array |
| `config.flags.2` | Third element of a nested array |

### Value coercion for `set`

| Input | Stored as |
|---|---|
| `true` / `false` | Boolean |
| `null` | JSON null |
| `42` / `3.14` | Number |
| anything else | String |

### Output examples

```
pt json validate file.json
  [OK]  Valid JSON  (file.json)

pt json validate bad.json
  [ERR] Invalid JSON -- Unexpected character ... (line 3, position 5)

pt json query file.json user.address.city
Seattle

pt json set file.json user.name John
  [OK]  Saved file.json  -- set user.name = John
```
