#!/usr/bin/env bash
set -euo pipefail

# conda-node-bootstrap.sh
# User-level Conda bootstrap (must NOT run as root).
# Responsibility: install Miniforge, set Python in base env, add notebook tooling,
# and apply defaults that help all future Conda environments.
# This script is idempotent and safe to re-run.
#
# Why these installs/settings matter:
# - Miniforge: lightweight conda-forge based Conda distribution.
# - Python in base env: consistent baseline interpreter for tooling.
# - jupyterlab + nb_conda_kernels in base: notebook UX and env kernel discovery.
# - create_default_packages ipykernel: every newly created env automatically gets ipykernel.
# - Optional CUDA env update: adds CUDA paths safely without duplicate PATH/LD_LIBRARY_PATH entries.
#
# Actions:
#   --install-conda -> install/configure Conda + base notebook tooling
#   --verify        -> run diagnostics
#   --runbook       -> emit concise markdown runbook
#   (no action)     -> print help
#
# Extra option:
#   --summarize-installation -> print installed versions/details (standalone or after setup)
#   --update-cuda-paths-in-env [CUDA_PATH] -> update ~/.bashrc CUDA block (path arg or CUDA_HOME env)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNBOOK_OUT="$SCRIPT_DIR/conda-node-bootstrap-runbook.md"
MINIFORGE_DIR="$HOME/local/miniforge3"
PYTHON_VERSION="3.12"
MINIFORGE_INSTALLER_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
SUMMARIZE_ONLY=0
UPDATE_CUDA_ENV=0
CUDA_PATH_ARG=""
INSTALL_CONDA_ONLY=0
VERIFY_ONLY=0
RUNBOOK_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  ./conda-node-bootstrap.sh [--install-conda|--verify|--runbook] [options]
  ./conda-node-bootstrap.sh --update-cuda-paths-in-env [path]
  ./conda-node-bootstrap.sh --summarize-installation
  ./conda-node-bootstrap.sh --help

Options:
  Primary actions (choose at most one):
    --install-conda               Install/configure Miniforge + base env tooling
    --verify                      Run diagnostics for existing installation
    --runbook                     Generate concise markdown runbook
    --summarize-installation      Print key versions/details and exit

  Action-scoped options:
    For --install-conda:
      --miniforge-dir <path>      Miniforge install path (default: ~/local/miniforge3)
      --python-version <version>  Python version for base env (default: 3.12)
      --installer-url <url>       Miniforge installer URL

    For --runbook:
      --runbook-out <path>        Output path for runbook markdown

    Standalone CUDA env update operation:
      --update-cuda-paths-in-env [path]
                                  Update CUDA-related shell exports in ~/.bashrc.
                                  Uses provided path, otherwise falls back to CUDA_HOME env.
                                  Also exports CONDA_OVERRIDE_CUDA based on the selected CUDA home,
                                  so Conda solves as if that CUDA version is available.
                                  Can be run by itself (no primary action required).

  Misc:
    -h, --help                    Show this help

Examples:
  ./conda-node-bootstrap.sh --install-conda
  ./conda-node-bootstrap.sh --verify
  ./conda-node-bootstrap.sh --runbook
  ./conda-node-bootstrap.sh --python-version 3.12
  ./conda-node-bootstrap.sh --update-cuda-paths-in-env /usr/local/cuda-12.8
  CUDA_HOME=/usr/local/cuda-12.8 ./conda-node-bootstrap.sh --update-cuda-paths-in-env
  ./conda-node-bootstrap.sh --summarize-installation
  ./conda-node-bootstrap.sh --help
EOF
}

log() {
  echo "[conda-node-bootstrap] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_non_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: conda-node-bootstrap.sh must NOT run as root." >&2
    echo "Run as target unix user, for example: sudo -u <user> bash ./conda-node-bootstrap.sh" >&2
    exit 1
  fi
}

ensure_shell_line() {
  local line="$1"
  local file="$2"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    echo "$line" >> "$file"
  fi
}

replace_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local tmp
  tmp="$(mktemp)"

  touch "$file"
  awk -v start="$start_marker" -v end="$end_marker" '
    BEGIN { skip=0 }
    {
      if (index($0, start) == 1) { skip=1; next }
      if (skip && index($0, end) == 1) { skip=0; next }
      if (!skip) print
    }
  ' "$file" > "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"

  {
    echo
    echo "$block_content"
  } >> "$file"
}

dedupe_colon_list() {
  local input="$1"
  local output=""
  local part
  local -A seen=()

  IFS=':' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    if [[ -z "${seen[$part]+x}" ]]; then
      seen[$part]=1
      if [[ -z "$output" ]]; then
        output="$part"
      else
        output="$output:$part"
      fi
    fi
  done

  echo "$output"
}

remove_paths_from_colon_list() {
  local input="$1"
  shift
  local output=""
  local part
  local drop
  local keep

  IFS=':' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    keep=1
    for drop in "$@"; do
      if [[ -n "$drop" && "$part" == "$drop" ]]; then
        keep=0
        break
      fi
    done

    if [[ "$keep" -eq 1 ]]; then
      if [[ -z "$output" ]]; then
        output="$part"
      else
        output="$output:$part"
      fi
    fi
  done

  echo "$output"
}

build_cuda_env_values() {
  local cuda_home="$1"
  local current_path="$2"
  local current_ld="$3"
  local cuda_bin="$cuda_home/bin"
  local cuda_lib64="$cuda_home/lib64"
  local cuda_targets="$cuda_home/targets/x86_64-linux/lib"
  local cleaned_path
  local cleaned_ld
  local next_path
  local next_ld

  cleaned_path="$(remove_paths_from_colon_list "$current_path" "$cuda_bin")"
  cleaned_ld="$(remove_paths_from_colon_list "$current_ld" "$cuda_lib64" "$cuda_targets")"

  next_path="$cuda_bin"
  if [[ -n "$cleaned_path" ]]; then
    next_path="$next_path:$cleaned_path"
  fi

  next_ld="$cuda_lib64:$cuda_targets"
  if [[ -n "$cleaned_ld" ]]; then
    next_ld="$next_ld:$cleaned_ld"
  fi

  CUDA_NEXT_PATH="$(dedupe_colon_list "$next_path")"
  CUDA_NEXT_LD_LIBRARY_PATH="$(dedupe_colon_list "$next_ld")"
}

cuda_override_version_from_home() {
  local cuda_home="$1"
  local basename

  basename="$(basename "$cuda_home")"
  if [[ "$basename" =~ cuda-([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$cuda_home" =~ /cuda-([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

update_cuda_paths_in_env() {
  local requested_path="$1"
  local cuda_home_resolved="$requested_path"
  local bashrc="$HOME/.bashrc"
  local start_marker="# >>> conda-node-bootstrap cuda paths >>>"
  local end_marker="# <<< conda-node-bootstrap cuda paths <<<"
  local block
  local conda_override_cuda=""

  if [[ -z "$cuda_home_resolved" ]]; then
    cuda_home_resolved="${CUDA_HOME:-}"
  fi

  if [[ -z "$cuda_home_resolved" ]]; then
    echo "ERROR: CUDA path not provided. Use --update-cuda-paths-in-env <path> or set CUDA_HOME." >&2
    exit 1
  fi

  if [[ ! -d "$cuda_home_resolved" ]]; then
    echo "ERROR: CUDA path does not exist: $cuda_home_resolved" >&2
    exit 1
  fi

  build_cuda_env_values "$cuda_home_resolved" "${PATH:-}" "${LD_LIBRARY_PATH:-}"

  conda_override_cuda="$(cuda_override_version_from_home "$cuda_home_resolved" || true)"
  if [[ -z "$conda_override_cuda" ]]; then
    echo "ERROR: Could not infer a CUDA version for CONDA_OVERRIDE_CUDA from: $cuda_home_resolved" >&2
    echo "Use a CUDA home named like /usr/local/cuda-12.8 so the override can be derived." >&2
    exit 1
  fi

  export CUDA_HOME="$cuda_home_resolved"
  export CONDA_OVERRIDE_CUDA="$conda_override_cuda"
  export PATH="$CUDA_NEXT_PATH"
  export LD_LIBRARY_PATH="$CUDA_NEXT_LD_LIBRARY_PATH"

  block=$(cat <<EOF
$start_marker
export CUDA_HOME="$cuda_home_resolved"
export CONDA_OVERRIDE_CUDA="$conda_override_cuda"
export PATH="$CUDA_NEXT_PATH"
export LD_LIBRARY_PATH="$CUDA_NEXT_LD_LIBRARY_PATH"
$end_marker
EOF
)

  replace_managed_block "$bashrc" "$start_marker" "$end_marker" "$block"
  log "Updated CUDA env paths in $bashrc using CUDA_HOME=$cuda_home_resolved and CONDA_OVERRIDE_CUDA=$conda_override_cuda"
}

install_miniforge() {
  if [[ -x "$MINIFORGE_DIR/bin/conda" ]] && "$MINIFORGE_DIR/bin/conda" --version >/dev/null 2>&1; then
    log "Miniforge already installed at $MINIFORGE_DIR"
    return
  fi

  if [[ -d "$MINIFORGE_DIR" ]]; then
    log "Removing incomplete Miniforge directory: $MINIFORGE_DIR"
    rm -rf "$MINIFORGE_DIR"
  fi

  need_cmd wget
  local installer_path
  installer_path="$HOME/Miniforge3.sh"

  log "Downloading Miniforge installer"
  wget "$MINIFORGE_INSTALLER_URL" -O "$installer_path"

  log "Installing Miniforge to $MINIFORGE_DIR"
  bash "$installer_path" -b -p "$MINIFORGE_DIR"

  rm -f "$installer_path"
}

init_conda() {
  local conda_bin="$MINIFORGE_DIR/bin/conda"
  if [[ ! -x "$conda_bin" ]]; then
    echo "ERROR: conda binary not found at $conda_bin" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$($conda_bin shell.bash hook)"
}

configure_base_env() {
  # Keep base Python pinned to caller-requested version for consistent tooling.
  conda install -n base -y "python=$PYTHON_VERSION"

  # Let Conda manage pip itself to avoid pip/Conda state drift in base.
  conda install -n base -y pip

  # Install notebook tooling from conda-forge; nb_conda_kernels is not reliably available on pip.
  conda install -n base -y -c conda-forge jupyterlab nb_conda_kernels

  # Any future conda env created by this user gets ipykernel by default.
  conda config --add create_default_packages ipykernel >/dev/null 2>&1 || true
}

write_user_exports() {
  local bashrc="$HOME/.bashrc"
  ensure_shell_line "export PATH=\"$MINIFORGE_DIR/bin:\$PATH\"" "$bashrc"

  # Make sure login shells load conda setup as well.
  "$MINIFORGE_DIR/bin/conda" init bash >/dev/null 2>&1 || true
}

do_setup() {
  require_non_root
  need_cmd bash

  install_miniforge
  init_conda
  configure_base_env
  write_user_exports

  log "Install complete. Running verification checks"
  do_verify
}

do_verify() {
  require_non_root

  if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
    echo "ERROR: Miniforge not found at $MINIFORGE_DIR" >&2
    exit 1
  fi

  init_conda

  log "Conda + Python checks"
  conda --version
  conda run -n base python --version || true

  log "Notebook package checks (base env)"
  conda run -n base python -c "import jupyterlab, nb_conda_kernels; print('jupyterlab', jupyterlab.__version__); print('nb_conda_kernels', nb_conda_kernels.__version__)" || true

  log "Conda default package policy check"
  conda config --show create_default_packages || true

  log "Shell path checks"
  which conda || true
  echo "CUDA_HOME=${CUDA_HOME:-<not set>}"

  summarize_installation
}

summarize_installation() {
  require_non_root

  echo
  echo "============================================================"
  echo "Conda node installation summary"
  echo "============================================================"
  echo "User                         : $(id -un)"
  echo "Miniforge dir                : $MINIFORGE_DIR"
  echo "Base python target version   : $PYTHON_VERSION"
  echo "CUDA_HOME env                : ${CUDA_HOME:-<not set>}"
  echo

  if [[ -x "$MINIFORGE_DIR/bin/conda" ]]; then
    "$MINIFORGE_DIR/bin/conda" --version || true
    init_conda
    conda run -n base python --version || true
    conda run -n base python -m pip show jupyterlab nb_conda_kernels ipykernel || true
    conda config --show create_default_packages || true
  else
    echo "Conda is not installed at expected path."
  fi

  echo
  echo "Key shell exports found in ~/.bashrc:"
  grep -nE 'miniforge3/bin|conda-node-bootstrap cuda paths|CUDA_HOME|LD_LIBRARY_PATH' "$HOME/.bashrc" || true
  echo "============================================================"
}

do_runbook() {
  cat > "$RUNBOOK_OUT" <<'EOF'
# Conda Node Bootstrap Runbook (Miniforge + Python 3.12)

## 1) Run user bootstrap (NOT root)

\`\`\`bash
./conda-node-bootstrap.sh --install-conda
\`\`\`

## 2) Verify Conda + notebook tooling

\`\`\`bash
./conda-node-bootstrap.sh --verify
\`\`\`

## 3) Print installed versions/details

\`\`\`bash
./conda-node-bootstrap.sh --summarize-installation
\`\`\`

## 4) Validation commands

\`\`\`bash
conda --version
conda run -n base python --version
conda run -n base python -c "import jupyterlab, nb_conda_kernels; print(jupyterlab.__version__, nb_conda_kernels.__version__)"
conda config --show create_default_packages
\`\`\`

## 5) Default shell exports

This script appends to ~/.bashrc:

\`\`\`bash
export PATH="$HOME/local/miniforge3/bin:$PATH"
\`\`\`

## 6) Optional CUDA shell export update (separate step)

Use one of:

\`\`\`bash
./conda-node-bootstrap.sh --update-cuda-paths-in-env /usr/local/cuda-12.8
CUDA_HOME=/usr/local/cuda-12.8 ./conda-node-bootstrap.sh --update-cuda-paths-in-env
\`\`\`

This writes a managed CUDA block in ~/.bashrc and sanitizes values to avoid duplicated entries.

It also configures Conda to auto-install ipykernel for all future environments:

\`\`\`bash
conda config --add create_default_packages ipykernel
\`\`\`
EOF

  log "Generated runbook: $RUNBOOK_OUT"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-conda)
      INSTALL_CONDA_ONLY=1
      shift
      ;;
    --verify)
      VERIFY_ONLY=1
      shift
      ;;
    --runbook)
      RUNBOOK_ONLY=1
      shift
      ;;
    --miniforge-dir)
      MINIFORGE_DIR="$2"
      shift 2
      ;;
    --python-version)
      PYTHON_VERSION="$2"
      shift 2
      ;;
    --installer-url)
      MINIFORGE_INSTALLER_URL="$2"
      shift 2
      ;;
    --update-cuda-paths-in-env)
      UPDATE_CUDA_ENV=1
      if [[ $# -gt 1 && "${2:-}" != --* ]]; then
        CUDA_PATH_ARG="$2"
        shift 2
      else
        shift
      fi
      ;;
    --runbook-out)
      RUNBOOK_OUT="$2"
      shift 2
      ;;
    --summarize-installation)
      SUMMARIZE_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SUMMARIZE_ONLY" -eq 1 ]]; then
  summarize_installation
  exit 0
fi

if [[ "$UPDATE_CUDA_ENV" -eq 1 ]]; then
  require_non_root
  update_cuda_paths_in_env "$CUDA_PATH_ARG"
fi

action_count=$((INSTALL_CONDA_ONLY + VERIFY_ONLY + RUNBOOK_ONLY))
if [[ "$action_count" -gt 1 ]]; then
  echo "ERROR: choose only one action: --install-conda, --verify, or --runbook" >&2
  usage
  exit 1
fi

# Default behavior: with no action and no standalone operation, print help.
if [[ "$action_count" -eq 0 && "$UPDATE_CUDA_ENV" -eq 0 ]]; then
  usage
  exit 0
fi

if [[ "$INSTALL_CONDA_ONLY" -eq 1 ]]; then
  do_setup
elif [[ "$VERIFY_ONLY" -eq 1 ]]; then
  do_verify
elif [[ "$RUNBOOK_ONLY" -eq 1 ]]; then
  do_runbook
fi
 