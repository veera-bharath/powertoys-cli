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
