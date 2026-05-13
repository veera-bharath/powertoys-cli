# PowerToys CLI

A collection of personal PowerShell utility scripts for Windows automation, unified under a single `pt` command.

> **Not affiliated with or related to Microsoft PowerToys.**

---

## Commands

| `pt` subcommand | Aliases | Description |
|---|---|---|
| `pt file-organizer` | `fo`, `organize` | Sort files into category folders by extension |
| `pt file-organizer-ai` | `foai` | Rule-based organizer with optional Ollama AI fallback *(experimental)* |
| `pt disk-cleaner` | `dc`, `clean` | Analyze disk usage, find duplicates and large files, delete or organize |
| `pt app-uninstaller` | `au`, `apps` | Interactive TUI to browse, select, and uninstall installed apps |
| `pt port` | `pm` | Inspect, kill, list, watch, and find free ports |

---

## Requirements

- Windows PowerShell 5.1 or later
- [Ollama](https://ollama.com/download) — only required if using `pt file-organizer-ai -UseAI`

---

## Installation

Run once from the repo root:

```
pt-installer.bat
```

Prompts for an install path (default `C:\Tools\PowerToys`), copies `pt.ps1`, `pt.bat`, and `commands.json` there, bakes the repo location into the config, and adds the install path to your user `PATH`. Open a new terminal after this completes.

```
pt help
```

### Adding new commands (plugin system)

Drop a `.json` file into `<InstallPath>\plugins\` with the same shape as an entry in `commands.json`:

```json
{
    "name": "my-tool",
    "aliases": ["mt"],
    "displayName": "MyTool",
    "description": "Does something useful",
    "script": "MyTools/MyTool.ps1",
    "usage": "pt my-tool [-Flag]",
    "help": ["One line of help text.", "Another line."]
}
```

`pt` discovers and loads all plugin files at startup — no installer changes needed.

### Legacy per-script installation

Individual scripts can still be installed with `pt-setup` for direct invocation (`FileOrganizer`, `DiskCleaner`, etc.) outside of `pt`. Run `pt-installer.bat` first, then `pt-setup` in a new terminal.

---

## FileOrganizer

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

Files with no matching extension are listed as **Skipped** in the summary. Filename collisions are resolved by appending `_2`, `_3`, etc. — nothing is overwritten.

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
  Failed         0
  Skipped        1

  BY CATEGORY
  ----------------------------------------------------
  Documents\PDF             1 file
  Images                    1 file
```

---

## FileOrganizerAI *(experimental)*

An advanced organizer that classifies files using a layered strategy:

1. **Keyword rules** — filename keywords mapped to Finance or Documents categories
2. **Extension map** — same broad extension-to-category mapping as FileOrganizer
3. **Ollama AI fallback** — called only when both rules above fail (requires `-UseAI`)
4. **Others** — catch-all for anything unclassified

Also detects duplicate files via SHA256 hash and moves them to a `Duplicates\` subfolder instead of overwriting or deleting.

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

Keyword matching takes priority over the extension map.

### Extension Mappings

| Category | Extensions |
|---|---|
| `Documents` | `.pdf` `.doc` `.docx` `.rtf` `.xls` `.xlsx` `.csv` `.ppt` `.pptx` `.txt` `.md` `.log` `.odt` `.ods` `.odp` |
| `Images` | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.svg` `.webp` `.heic` `.tiff` `.ico` `.avif` `.raw` |
| `Videos` | `.mp4` `.mkv` `.avi` `.mov` `.wmv` `.flv` `.webm` `.m4v` `.mpg` `.mpeg` |
| `Code` | `.py` `.js` `.ts` `.cs` `.java` `.cpp` `.c` `.h` `.html` `.css` `.php` `.rb` `.go` `.rs` `.ps1` `.sh` `.json` `.xml` `.yaml` `.yml` `.sql` |
| `Archives` | `.zip` `.rar` `.7z` `.tar` `.gz` `.bz2` `.xz` `.iso` |

### Outputs

Two files are written to the `Destination` folder after each run:

- **`organizer.log`** — timestamped log of every action (moved, duplicated, error)
- **`organizer-metadata.json`** — per-file record including category, tags, size, dates, AI usage flag, original and new paths

### Using AI fallback

Requires [Ollama](https://ollama.com/download) installed and running. Pull a model first:

```
ollama pull gemma:2b
ollama pull llama3.2:1b
```

If the model specified by `-Model` is not installed, the script lists available models and lets you choose interactively.

---

## DiskCleaner

Recursively scans a directory and gives you an interactive menu to analyze, clean, and organize files.

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
  4.  Organize        - run FileOrganizer on this path
  R.  Re-scan
  Q.  Quit
```

### File Types view

Lists all extension categories (Videos, Images, Documents, Archives, Code, Executables, Others) with file count, total size, and a visual bar. Select a category to browse its files with pagination (18 per page).

### Duplicate Files view

Groups files by SHA256 hash. For each group, shows file count and wasted space (total size minus one copy). Options:

- **`D <group>`** — keep the newest copy, send the rest to Recycle Bin
- **`<group>`** — inspect individual files in the group and delete selectively

### Large Files view

Top 20 files sorted by size. Same file list interface as File Types.

### File list options (available in all views)

| Input | Action |
|---|---|
| `<number>` | Send that file to Recycle Bin (with confirmation) |
| `O <number>` | Open file location in Explorer |
| `N` / `P` | Next / previous page |
| `B` | Back to previous menu |

> All deletions go to the **Recycle Bin** — nothing is permanently deleted without going through the Bin first.

### Organize integration

Option 4 looks for FileOrganizer in your `PATH`, then at `C:\Tools\PowerToys`, then as a sibling script in the repo. If not found, it prints install instructions. If found, offers a **WhatIf preview** before running for real.

---

## AppUninstaller

An interactive terminal UI for browsing and uninstalling installed applications. Fully keyboard-driven — no typing required to navigate.

```powershell
pt app-uninstaller
pt au -IncludeStore
```

> Automatically requests admin elevation on launch (required to remove HKLM registry entries and files in Program Files).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-IncludeStore` | Off | Also list Microsoft Store (AppX) packages |

### Keyboard Controls

| Key | Action |
|---|---|
| `Up` / `Down` | Move cursor |
| `Left` / `Right` | Previous / next page |
| `Space` | Toggle selection on highlighted app (cursor advances) |
| `Ctrl+U` | Open uninstall confirmation for all selected apps |
| `Ctrl+R` | Rescan installed apps |
| `F` | Open filter prompt (type name or publisher, Enter to apply) |
| `C` | Clear active filter |
| `S` | Cycle sort: Name → Size → Date → Publisher → Usage |
| `Q` | Quit |

### Columns

| Column | Source |
|---|---|
| Name | `DisplayName` registry value |
| Publisher | `Publisher` registry value |
| Version | `DisplayVersion` registry value |
| Installed | `InstallDate` registry value (parsed from `yyyyMMdd`) |
| Size | `EstimatedSize` registry value (converted from KB) |
| Type | `[MSI]` Windows Installer / `[EXE]` standalone / `[Str]` Store |
| Last Used | Most recent `LastWriteTime` among matching prefetch files in `C:\Windows\Prefetch\` |

### Uninstall behaviour

| App type | Method |
|---|---|
| MSI | `msiexec /X {GUID} /passive` — silent with progress bar, no clicks |
| EXE | Launches the app's own uninstaller window |
| Store | `Remove-AppxPackage` — silent background removal |
| Orphaned entry | Exe no longer on disk → registry entry is cleaned up automatically |

The confirmation screen lists every selected app with its type and size before anything is removed. You must type `YES` (uppercase) to proceed.

### Selection

Selected apps are highlighted in yellow. The count is shown in the header and the hint bar. Multi-select as many apps as you like before pressing `Ctrl+U` to uninstall them in sequence.

---

## PortManager

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
| `--fix <port>` | Alias for `--kill` — detect conflict, prompt, kill |
| `--list` | Table of all active TCP connections |
| `--list --range <n>` | Limit to first N results |
| `--list --s <start> --e <end>` | Filter by port number range |
| `--watch <port>` | Poll port every second, print state changes — `Ctrl+C` exits |
| `--free` | Find the first free port in 1024–65535 |
| `--free --s <start> --e <end>` | Find a free port in a specific range |
| `--json` | Output as JSON instead of formatted tables (combine with any command) |

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
| Red | `Established` (active connection) |
| Yellow | `TimeWait` / `CloseWait` (closing) |
| Gray | Other states (`Bound`, etc.) |

### Kill confirmation

`--kill` always shows a detail card before acting and requires typing `YES` in full. Use `--force` to skip the prompt in scripts.

If a kill fails with access denied, the error message suggests re-running as Administrator.

---

## Setup System

The setup is split into two stages so the tool works from anywhere after initial install.

### `pt-installer.bat` (run from the repo, once)

- Asks for an install path (default `C:\Tools\PowerToys`)
- Bakes the repo root and install path into `Setup\scripts.json`
- Copies `pt-setup.ps1`, `pt-setup.bat`, and `scripts.json` to the install path
- Adds the install path to your user `PATH`

### `pt-setup` (run from any terminal, any time)

- Reads config from `scripts.json` (no arguments needed)
- Lists already-installed scripts and excludes them from the menu
- Copies the selected `.ps1` files from the repo and generates thin `.bat` wrappers
- All script parameters pass through the `.bat` wrappers transparently

### Adding a new script

Add one entry to `Setup/scripts.json` — no changes to any `.ps1` file needed:

```json
{
  "id":          "MyScript",
  "displayName": "MyScript",
  "description": "One-line description shown in the menu",
  "source":      "MyScript/MyScript.ps1",
  "usage":       "MyScript [-Param value]"
}
```

---

## Project Structure

```
FileOrganizer/
  FileOrganizer.ps1       Extension-based file organizer
  FileOrganizer.bat       Interactive launcher

FileOrganizerAI/
  FileOrganizerAI.ps1     Rule-based + AI fallback organizer
  FileOrganizerAI.bat     Interactive launcher

DiskCleaner/
  DiskCleaner.ps1         Disk usage analyzer and cleaner
  DiskCleaner.bat         Interactive launcher

AppUninstaller/
  AppUninstaller.ps1      Interactive app uninstaller with keyboard navigation
  AppUninstaller.bat      Launcher (prompts for Store app inclusion)

PortManager/
  PortManager.ps1         Port inspector, killer, watcher, and free-port finder
  port.bat                Thin launcher (command is "port")

Setup/
  pt-setup.ps1            Installs selected scripts to PATH location
  pt-setup.bat            Launcher (copied to install path)
  scripts.json            Registry of installable scripts

pt-installer.bat          One-time bootstrapper (run from repo root)
```
