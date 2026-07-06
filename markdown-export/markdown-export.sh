#!/usr/bin/env bash
set -euo pipefail

DO_HTML=0
DO_PDF=0
OVERWRITE=0
OUTPUT_BASENAME=""
INPUT_FILE=""
MERMAID_BGCOLOR="transparent"
HTML_IMAGE_FORMAT="svg"
PDF_IMAGE_FORMAT="png"  #required; else text labels in PDF are not rendered correctly (mermaid-cli bug)

# PDF font defaults (override via environment if needed)
PDF_MAINFONT="${PDF_MAINFONT:-DejaVu Serif}"
PDF_SANSFONT="${PDF_SANSFONT:-DejaVu Sans}"
PDF_MONOFONT="${PDF_MONOFONT:-DejaVu Sans Mono}"

# Always define as empty array to avoid unbound issues with set -u
LUA_FILTER_ARGS_HTML=()
LUA_FILTER_ARGS_PDF=()

print_usage() {
  cat <<EOF
Usage: markdown-export [options] input.md

Options:
  --html           Generate HTML output
  --pdf            Generate PDF output
  --html-image-format FMT
                   Mermaid image format for HTML output: svg|png (default: svg)
  --pdf-image-format FMT
                   Mermaid image format for PDF output: svg|png (default: png)
  --mermaid-bgcolor HEX
                   Set Mermaid SVG background color (hex, e.g. '#F0F0F0')
  -o TARGET        Output target:
                   - NAME: write exports in current folder
                   - PATH/NAME: write exports in PATH
  --overwrite      Overwrite existing output files
  -h, --help       Show this help

Behavior:
  - If neither --html nor --pdf is given, generate BOTH HTML and PDF.
  - If only --html is given, generate only HTML.
  - If only --pdf is given, generate only PDF.
  - If both --html and --pdf are given, generate BOTH.
  - If -o is not given, the output basename is derived from the input filename,
    and files are written to the current folder.
  - If any target output file already exists and --overwrite is NOT set,
    the script exits with an error and does not overwrite.

Internally uses:
  - pandoc/core         for HTML
  - pandoc/latex:3-ubuntu for PDF (via LaTeX)
  - A Mermaid CLI container (on the host) for Mermaid diagrams

PDF font customization (optional env vars):
  - PDF_MAINFONT   (default: DejaVu Serif)
  - PDF_SANSFONT   (default: DejaVu Sans)
  - PDF_MONOFONT   (default: DejaVu Sans Mono)

Mermaid options:
  - --mermaid-bgcolor defaults to transparent when not provided.
  - --html-image-format defaults to svg; --pdf-image-format defaults to png.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_CWD="$(pwd)"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --html)
      DO_HTML=1
      shift
      ;;
    --pdf)
      DO_PDF=1
      shift
      ;;
    --html-image-format)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --html-image-format requires a value: svg or png." >&2
        exit 1
      fi
      HTML_IMAGE_FORMAT="$1"
      if [[ "$HTML_IMAGE_FORMAT" != "svg" && "$HTML_IMAGE_FORMAT" != "png" ]]; then
        echo "Error: --html-image-format must be 'svg' or 'png'." >&2
        exit 1
      fi
      shift
      ;;
    --pdf-image-format)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --pdf-image-format requires a value: svg or png." >&2
        exit 1
      fi
      PDF_IMAGE_FORMAT="$1"
      if [[ "$PDF_IMAGE_FORMAT" != "svg" && "$PDF_IMAGE_FORMAT" != "png" ]]; then
        echo "Error: --pdf-image-format must be 'svg' or 'png'." >&2
        exit 1
      fi
      shift
      ;;
    --mermaid-bgcolor)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --mermaid-bgcolor requires a hex color (e.g. '#F0F0F0')." >&2
        exit 1
      fi
      MERMAID_BGCOLOR="$1"
      if [[ ! "$MERMAID_BGCOLOR" =~ ^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$ ]]; then
        echo "Error: --mermaid-bgcolor must be a hex color like '#RGB' or '#RRGGBB'." >&2
        exit 1
      fi
      shift
      ;;
    -o)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: -o requires a basename argument" >&2
        exit 1
      fi
      OUTPUT_BASENAME="$1"
      shift
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *)
      if [[ -n "$INPUT_FILE" ]]; then
        echo "Error: Multiple input files given. Only one is supported." >&2
        exit 1
      fi
      INPUT_FILE="$1"
      shift
      ;;
  esac
done

if [[ -z "$INPUT_FILE" ]]; then
  echo "Error: No input file specified." >&2
  print_usage
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: Input file '$INPUT_FILE' not found." >&2
  exit 1
fi

# If neither html nor pdf specified, do both
if [[ $DO_HTML -eq 0 && $DO_PDF -eq 0 ]]; then
  DO_HTML=1
  DO_PDF=1
fi

# Determine output target (folder + basename)
if [[ -z "$OUTPUT_BASENAME" ]]; then
  fname="$(basename -- "$INPUT_FILE")"
  OUTPUT_BASENAME="${fname%.*}"
fi

if [[ "$OUTPUT_BASENAME" == */* ]]; then
  OUTPUT_DIR="$(dirname "$OUTPUT_BASENAME")"
  OUTPUT_STEM="$(basename "$OUTPUT_BASENAME")"
  # Create directory if it doesn't exist, then resolve to absolute path
  mkdir -p "$OUTPUT_DIR"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
else
  OUTPUT_DIR="$CALLER_CWD"
  OUTPUT_STEM="$OUTPUT_BASENAME"
fi

if [[ -z "$OUTPUT_STEM" || "$OUTPUT_STEM" == "." || "$OUTPUT_STEM" == ".." ]]; then
  echo "Error: invalid -o target '$OUTPUT_BASENAME'." >&2
  exit 1
fi

HTML_OUT="${OUTPUT_STEM}.html"
PDF_OUT="${OUTPUT_STEM}.pdf"
HTML_OUT_ABS="${OUTPUT_DIR}/${HTML_OUT}"
PDF_OUT_ABS="${OUTPUT_DIR}/${PDF_OUT}"

# Check for existing outputs
if [[ $OVERWRITE -eq 0 ]]; then
  if [[ $DO_HTML -eq 1 && -f "$HTML_OUT_ABS" ]]; then
    echo "Error: Output file '$HTML_OUT_ABS' already exists. Use --overwrite to overwrite." >&2
    exit 1
  fi
  if [[ $DO_PDF -eq 1 && -f "$PDF_OUT_ABS" ]]; then
    echo "Error: Output file '$PDF_OUT_ABS' already exists. Use --overwrite to overwrite." >&2
    exit 1
  fi
fi

# Resolve absolute path and directory for input
INPUT_ABS="$(cd "$(dirname "$INPUT_FILE")" && pwd)/$(basename "$INPUT_FILE")"
WORKDIR="$(cd "$(dirname "$INPUT_ABS")" && pwd)"
INPUT_NAME="$(basename "$INPUT_ABS")"

USER_ID="$(id -u)"
GROUP_ID="$(id -g)"
USER_MAPPING="${USER_ID}:${GROUP_ID}"

# Temp base inside script dir for Mermaid artefacts and generated filters
MERMAID_TMP_ROOT="${SCRIPT_DIR}/tmp-mermaid"
mkdir -p "$MERMAID_TMP_ROOT"

# Use a per-run subdir (e.g. tmp-mermaid/run-<timestamp>-<pid>)
RUN_ID="$(date +%s)-$$"
RUN_DIR="${MERMAID_TMP_ROOT}/run-${RUN_ID}"
mkdir -p "$RUN_DIR"

FILTER_FILE_HOST="${RUN_DIR}/mermaid-filter-run.lua"
# We mount RUN_DIR into the containers at the same path, so we can reuse this path inside
FILTER_FILE_CONTAINER="${RUN_DIR}/mermaid-filter-run.lua"
FILTER_FILE_HTML_HOST="${RUN_DIR}/mermaid-filter-html.lua"
FILTER_FILE_PDF_HOST="${RUN_DIR}/mermaid-filter-pdf.lua"
FILTER_FILE_HTML_CONTAINER="${RUN_DIR}/mermaid-filter-html.lua"
FILTER_FILE_PDF_CONTAINER="${RUN_DIR}/mermaid-filter-pdf.lua"

# Mermaid CLI image (host) – can be overridden via MERMAID_CLI_IMAGE
MERMAID_IMAGE="${MERMAID_CLI_IMAGE:-ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:latest}"

MERMAID_COUNT=0
AST_JSON="${RUN_DIR}/ast.json"

echo "Scanning for Mermaid diagrams and pre-rendering via Mermaid CLI container..."

# Convert markdown to JSON AST (host, using pandoc/core container)
docker run --rm \
  -v "${WORKDIR}:/data" \
  -w /data \
  -u "$USER_MAPPING" \
  pandoc/core \
  "$INPUT_NAME" \
  -t json \
  -o "/data/$(basename "$AST_JSON")"

# Move AST file into RUN_DIR
mv "${WORKDIR}/$(basename "$AST_JSON")" "$AST_JSON"

# Function to render a single Mermaid diagram to SVG
render_mermaid_image() {
  local index="$1"
  local mermaid_text_file="$2"
  local image_out="$3"
  local image_format="$4"

  docker run --rm \
    -u "$USER_MAPPING" \
    -v "${RUN_DIR}:/data" \
    -v "$(dirname "$0")/mermaid.json:/mermaid.json:ro" \
    "$MERMAID_IMAGE" \
    -i "/data/$(basename "$mermaid_text_file")" \
    -o "/data/$(basename "$image_out")" \
    -e "$image_format" \
    -b "$MERMAID_BGCOLOR" \
    --configFile /mermaid.json
}

# jq is required on host
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required on the host for Mermaid pre-processing." >&2
  echo "Install jq (e.g. brew install jq) and try again." >&2
  exit 1
fi

# Extract all CodeBlocks with class "mermaid" from the full AST
MERMAID_BLOCKS_JSON="${RUN_DIR}/mermaid-blocks.txt"

# echo "Debug: showing first few CodeBlocks from AST (if any):"
# jq '
#   .. | objects
#   | select(.t? == "CodeBlock")
# ' "$AST_JSON" | head || true

echo "Debug: extracting Mermaid CodeBlocks..."
jq -c '
  .. | objects
  | select(.t? == "CodeBlock")
  | select(
      (.c | type == "array" and length > 1)
      and (.c[0] | type == "array" and length > 1)
      and (.c[0][1] | type == "array")
      and (any(.c[0][1][]?; . == "mermaid"))
    )
  | .c[1]
' "$AST_JSON" > "$MERMAID_BLOCKS_JSON"

# echo "Debug: contents of mermaid-blocks.txt:"
# if [[ -s "$MERMAID_BLOCKS_JSON" ]]; then
#   cat "$MERMAID_BLOCKS_JSON"
# else
#   echo "(empty)"
# fi

# For each Mermaid block, render required image formats via Mermaid CLI container
if [[ -s "$MERMAID_BLOCKS_JSON" ]]; then
  NEED_SVG=0
  NEED_PNG=0
  if [[ $DO_HTML -eq 1 && "$HTML_IMAGE_FORMAT" == "svg" ]]; then
    NEED_SVG=1
  fi
  if [[ $DO_PDF -eq 1 && "$PDF_IMAGE_FORMAT" == "svg" ]]; then
    NEED_SVG=1
  fi
  if [[ $DO_HTML -eq 1 && "$HTML_IMAGE_FORMAT" == "png" ]]; then
    NEED_PNG=1
  fi
  if [[ $DO_PDF -eq 1 && "$PDF_IMAGE_FORMAT" == "png" ]]; then
    NEED_PNG=1
  fi

  while IFS= read -r line; do
    MERMAID_COUNT=$((MERMAID_COUNT + 1))
    local_mmd="${RUN_DIR}/diagram-${MERMAID_COUNT}.mmd"
    local_svg="${RUN_DIR}/diagram-${MERMAID_COUNT}.svg"
    local_png="${RUN_DIR}/diagram-${MERMAID_COUNT}.png"

    # Decode JSON string to raw Mermaid text with real newlines
    printf "%s\n" "$(echo "$line" | jq -r '.')" > "$local_mmd"

    echo "  Rendering Mermaid diagram #${MERMAID_COUNT}..."
    if [[ $NEED_SVG -eq 1 ]]; then
      if ! render_mermaid_image "$MERMAID_COUNT" "$local_mmd" "$local_svg" "svg"; then
        echo "Error: Mermaid render failed for diagram #${MERMAID_COUNT}." >&2
        echo "  Mermaid source: ${local_mmd}" >&2
        echo "  Expected image: ${local_svg}" >&2
        echo "  Tip: open the source file above and validate Mermaid syntax for that block." >&2
        echo "  Export aborted because diagrams must be rendered before embedding into HTML/PDF." >&2
        exit 1
      fi
    fi
    if [[ $NEED_PNG -eq 1 ]]; then
      if ! render_mermaid_image "$MERMAID_COUNT" "$local_mmd" "$local_png" "png"; then
        echo "Error: Mermaid render failed for diagram #${MERMAID_COUNT}." >&2
        echo "  Mermaid source: ${local_mmd}" >&2
        echo "  Expected image: ${local_png}" >&2
        echo "  Tip: open the source file above and validate Mermaid syntax for that block." >&2
        echo "  Export aborted because diagrams must be rendered before embedding into HTML/PDF." >&2
        exit 1
      fi
    fi
  done < "$MERMAID_BLOCKS_JSON"
else
  echo "No Mermaid diagrams found."
fi

# Generate run-specific Lua filters
generate_mermaid_filter() {
  local image_ext="$1"
  local filter_file="$2"

  cat > "$filter_file" <<'LUA'
-- Auto-generated Mermaid filter for this run.
-- Uses mermaid-filter.lua helper functions plus a simple mapping.

-- Make sure Lua can find /tool/mermaid-filter.lua
package.path = "/tool/?.lua;/tool/?/init.lua;" .. package.path

local helper = require("mermaid-filter")

local svg_map = {
LUA

  for ((i=1; i<=MERMAID_COUNT; i++)); do
    image_name="diagram-${i}.${image_ext}"
    echo "  [${i}] = \"${image_name}\"," >> "$filter_file"
  done

  cat >> "$filter_file" <<'LUA'
}

return {
  { CodeBlock = helper.make_mermaid_replacer(svg_map) }
}
LUA
}

# Copy Mermaid images into OUTPUT_DIR so all exports (html/pdf/images) stay together.
if [[ $MERMAID_COUNT -gt 0 ]]; then
  echo "Copying rendered Mermaid images into output directory..."
  for ((i=1; i<=MERMAID_COUNT; i++)); do
    for ext in svg png; do
      image_name="diagram-${i}.${ext}"
      if [[ -f "${RUN_DIR}/${image_name}" ]]; then
        cp "${RUN_DIR}/${image_name}" "${OUTPUT_DIR}/${image_name}"
      fi
    done
  done
fi

# Build Lua filter args per output type (if any diagrams)
LUA_FILTER_ARGS_HTML=()
LUA_FILTER_ARGS_PDF=()
if [[ $MERMAID_COUNT -gt 0 ]]; then
  if [[ $DO_HTML -eq 1 ]]; then
    generate_mermaid_filter "$HTML_IMAGE_FORMAT" "$FILTER_FILE_HTML_HOST"
    LUA_FILTER_ARGS_HTML=(--lua-filter="$FILTER_FILE_HTML_CONTAINER")
  fi
  if [[ $DO_PDF -eq 1 ]]; then
    generate_mermaid_filter "$PDF_IMAGE_FORMAT" "$FILTER_FILE_PDF_HOST"
    LUA_FILTER_ARGS_PDF=(--lua-filter="$FILTER_FILE_PDF_CONTAINER")
  fi
  if [[ $DO_HTML -eq 1 && $DO_PDF -eq 1 ]]; then
    echo "Mermaid diagrams detected (${MERMAID_COUNT}). HTML uses ${HTML_IMAGE_FORMAT}, PDF uses ${PDF_IMAGE_FORMAT}."
  elif [[ $DO_HTML -eq 1 ]]; then
    echo "Mermaid diagrams detected (${MERMAID_COUNT}). HTML uses ${HTML_IMAGE_FORMAT}."
  elif [[ $DO_PDF -eq 1 ]]; then
    echo "Mermaid diagrams detected (${MERMAID_COUNT}). PDF uses ${PDF_IMAGE_FORMAT}."
  fi
fi

# HTML via pandoc/core
if [[ $DO_HTML -eq 1 ]]; then
  echo "Generating HTML: '$INPUT_FILE' -> '$HTML_OUT_ABS' (via pandoc/core)..."
  docker run --rm \
    -v "${WORKDIR}:/data" \
    -v "${SCRIPT_DIR}:/tool" \
    -v "${RUN_DIR}:${RUN_DIR}" \
    -v "${OUTPUT_DIR}:${OUTPUT_DIR}" \
    -w /data \
    -u "$USER_MAPPING" \
    pandoc/core \
    "$INPUT_NAME" \
    -o "$HTML_OUT_ABS" \
    --standalone \
    --mathjax \
    --resource-path="/data:${OUTPUT_DIR}" \
    ${LUA_FILTER_ARGS_HTML+"${LUA_FILTER_ARGS_HTML[@]}"}
  echo "Wrote $HTML_OUT_ABS"
fi

# PDF via pandoc/latex:3-ubuntu (arm64-capable)
if [[ $DO_PDF -eq 1 ]]; then
  echo "Generating PDF: '$INPUT_FILE' -> '$PDF_OUT_ABS' (via pandoc/latex:3-ubuntu)..."
  docker run --rm \
    -v "${WORKDIR}:/data" \
    -v "${SCRIPT_DIR}:/tool" \
    -v "${RUN_DIR}:${RUN_DIR}" \
    -v "${OUTPUT_DIR}:${OUTPUT_DIR}" \
    -w /data \
    -u "$USER_MAPPING" \
    pandoc/latex:3-ubuntu \
    "$INPUT_NAME" \
    -o "$PDF_OUT_ABS" \
    --pdf-engine=xelatex \
    -V "mainfont=${PDF_MAINFONT}" \
    -V "sansfont=${PDF_SANSFONT}" \
    -V "monofont=${PDF_MONOFONT}" \
    --resource-path="/data:${OUTPUT_DIR}" \
    ${LUA_FILTER_ARGS_PDF+"${LUA_FILTER_ARGS_PDF[@]}"}
  echo "Wrote $PDF_OUT_ABS"
fi

echo "Done."
echo "Mermaid temp files for this run are in: ${RUN_DIR}"