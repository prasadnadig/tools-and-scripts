#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
ROOT="${SCRIPT_DIR}/tmp-mermaid"

echo "Cleaning Mermaid temp directories in: ${ROOT}"

if [[ ! -d "$ROOT" ]]; then
  echo "No tmp-mermaid directory found."
  exit 0
fi

shopt -s nullglob
dirs=("${ROOT}/run-"*)

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No run-* directories found under tmp-mermaid."
  exit 0
fi

for d in "${dirs[@]}"; do
  if [[ -d "$d" ]]; then
    echo "Removing: $d"
    rm -rf -- "$d"
  fi
done

echo "Done."