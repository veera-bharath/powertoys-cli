# PowerToys CLI

A collection of personal PowerShell utility scripts for Windows automation. Installable as global CLI commands via the included setup system.

> **Not affiliated with or related to Microsoft PowerToys.**

---

## Scripts

| Command | Description |
|---|---|
| `FileOrganizer` | Sorts files into category folders by extension |
| `FileOrganizerAI` | Rule-based organizer with optional Ollama AI fallback *(experimental)* |

---

## Requirements

- Windows PowerShell 5.1 or later
- [Ollama](https://ollama.com/download) — only required if using `FileOrganizerAI -UseAI`

---

## Installation

### Step 1 — Bootstrap the setup command (run once from the repo)

```
pt-installer.bat
```

Prompts for an install path (defaults to `C:\Tools\PowerToys`), copies the setup tool there, and adds it to your user `PATH`. Open a new terminal after this completes.

### Step 2 — Install scripts

```
pt-setup
```

Shows a menu of available scripts. Select by number or press `A` for all. Each script is copied to the install path and gets a `.bat` wrapper so it works from any terminal without needing to invoke `powershell` manually.

---

## FileOrganizer

Scans the root level of a directory and moves files into category subfolders based on their extension.

```powershell
FileOrganizer
FileOrganizer -Path "C:\Users\Me\Downloads"
FileOrganizer -WhatIf
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
FileOrganizerAI
FileOrganizerAI -Source "C:\Users\Me\Downloads" -DryRun
FileOrganizerAI -UseAI -Model "gemma:2b"
FileOrganizerAI -Source "D:\Docs" -Destination "D:\Sorted" -UseAI -DryRun
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

Setup/
  pt-setup.ps1            Installs selected scripts to PATH location
  pt-setup.bat            Launcher (copied to install path)
  scripts.json            Registry of installable scripts

pt-installer.bat          One-time bootstrapper (run from repo root)
```
