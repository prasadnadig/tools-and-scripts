# markdown-export

`markdown-export.sh` is a bash wrapper that converts one Markdown file to HTML and/or PDF using containerized Pandoc, with Mermaid diagrams pre-rendered via Mermaid CLI and embedded through a generated Lua filter.

## Current Folder Status

This is the current content of this `markdown-export` folder and what each file does:

- `markdown-export.sh`
  - Main CLI wrapper.
  - Parses options, renders Mermaid images, and runs Pandoc containers.
  - Supports per-target Mermaid image formats (`svg`/`png`) and Mermaid background color.

- `mermaid-filter.lua`
  - Lua helper used by generated run-specific filters.
  - Replaces Mermaid code blocks with image references (`diagram-N.svg` or `diagram-N.png`).

- `mermaid.json`
  - Mermaid configuration passed to Mermaid CLI (`--configFile`).
  - Current config uses `sans-serif` fonts and `flowchart.htmlLabels=false` for improved PDF compatibility.

- `markdown-export-clean-mermaid.sh`
  - Cleanup helper for temp run folders under `tmp-mermaid/run-*`.

- `README`
  - This document.

## Requirements

- macOS (Apple Silicon or Intel)
- A working `docker` CLI (Docker Desktop, Colima, Podman with shim, etc.)
- `jq` on host

Install `jq` (Homebrew):

```bash
brew install jq
```

## Usage

```bash
./markdown-export.sh [options] input.md
```

### Output Selection

- If neither `--html` nor `--pdf` is passed: generates both.
- `--html`: generate HTML only.
- `--pdf`: generate PDF only.

### Output Target

- `-o NAME` writes `NAME.html` and/or `NAME.pdf` into current directory.
- `-o PATH/NAME` writes into `PATH` (created automatically if needed).

### Mermaid Options

- `--html-image-format svg|png`
  - Mermaid image format used for HTML output.
  - Default in script: `svg`.

- `--pdf-image-format svg|png`
  - Mermaid image format used for PDF output.
  - Current script default: `png` (set near top of `markdown-export.sh`).
  - Recommended for PDF text reliability.

- `--mermaid-bgcolor '#RRGGBB'`
  - Sets Mermaid image background color.
  - If not passed, background defaults to transparent.
  - Accepted format: hex only (`#RGB` or `#RRGGBB`).

### Overwrite

- By default existing output files are not overwritten.
- Use `--overwrite` to replace existing outputs.

## Examples

Generate both HTML and PDF with defaults:

```bash
./markdown-export.sh notes.md
```

Generate both HTML and PDF for a different file:

```bash
./markdown-export.sh project-plan.md
```

Generate HTML only using SVG diagrams:

```bash
./markdown-export.sh --html --html-image-format svg notes.md
```

Generate PDF only using PNG diagrams (recommended):

```bash
./markdown-export.sh --pdf --pdf-image-format png notes.md
```

Set explicit diagram background color:

```bash
./markdown-export.sh --html --mermaid-bgcolor '#F0F0F0' notes.md
```

Write outputs into a directory:

```bash
./markdown-export.sh --html --pdf -o exports/report notes.md
```

## Pipeline Summary

For each run, `markdown-export.sh` does this:

1. Uses `pandoc/core` to produce AST JSON from input markdown.
2. Uses host `jq` to extract Mermaid fenced blocks.
3. Uses Mermaid CLI container to render required diagram files (`svg`, `png`, or both depending on options).
4. Copies rendered diagrams into output directory.
5. Generates run-specific Lua filter(s) mapping Mermaid block index to rendered image filenames.
6. Runs:
   - `pandoc/core` for HTML
   - `pandoc/latex:3-ubuntu` for PDF (`xelatex`)

Temp artifacts are written to:

```text
tmp-mermaid/run-<timestamp>-<pid>/
```

## Cleanup

Remove temp Mermaid run folders:

```bash
./markdown-export-clean-mermaid.sh
```

## Notes

- Mermaid SVG labels can still be problematic for some PDF toolchains due to `foreignObject` handling; using `--pdf-image-format png` is the safer default for PDF output.
- PDF fonts are configurable via environment variables:
  - `PDF_MAINFONT` (default: `DejaVu Serif`)
  - `PDF_SANSFONT` (default: `DejaVu Sans`)
  - `PDF_MONOFONT` (default: `DejaVu Sans Mono`)
