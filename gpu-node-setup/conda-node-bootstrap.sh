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
# - PATH/LD_LIBRARY_PATH exports: predictable CUDA and Conda command discovery.
#
# Modes:
#   setup    -> install/configure (default)
#   verify   -> run diagnostics
#   runbook  -> emit concise markdown runbook
#
# Extra option:
#   --summarize-installation -> print installed versions/details (standalone or after setup)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="setup"
RUNBOOK_OUT="$SCRIPT_DIR/conda-node-bootstrap-runbook.md"
MINIFORGE_DIR="$HOME/local/miniforge3"
PYTHON_VERSION="3.12"
MINIFORGE_INSTALLER_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
CUDA_HOME="/usr/local/cuda-12.8"
SUMMARIZE_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  ./conda-node-bootstrap.sh [--mode setup|verify|runbook] [options]
  ./conda-node-bootstrap.sh --summarize-installation

Options:
  --mode <mode>                 setup (default), verify, runbook
  --miniforge-dir <path>        Miniforge install path (default: ~/local/miniforge3)
  --python-version <version>    Python version for base env (default: 3.12)
  --installer-url <url>         Miniforge installer URL
  --cuda-home <path>            CUDA_HOME used in shell exports (default: /usr/local/cuda-12.8)
  --runbook-out <path>          Output path for runbook mode
  --summarize-installation      Print key versions/details and exit
  -h, --help                    Show this help

Examples:
  ./conda-node-bootstrap.sh
  ./conda-node-bootstrap.sh --mode verify
  ./conda-node-bootstrap.sh --python-version 3.12
  ./conda-node-bootstrap.sh --summarize-installation
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

  # Notebook UX in base env and env kernel discovery in JupyterLab.
  conda run -n base python -m pip install --upgrade pip
  conda run -n base python -m pip install jupyterlab nb_conda_kernels

  # Any future conda env created by this user gets ipykernel by default.
  conda config --add create_default_packages ipykernel >/dev/null 2>&1 || true
}

write_user_exports() {
  local bashrc="$HOME/.bashrc"
  ensure_shell_line "export PATH=\"$MINIFORGE_DIR/bin:\$PATH\"" "$bashrc"
  ensure_shell_line "export CUDA_HOME=$CUDA_HOME" "$bashrc"
  ensure_shell_line "export PATH=\"\$CUDA_HOME/bin:\$PATH\"" "$bashrc"
  ensure_shell_line "export LD_LIBRARY_PATH=\"\$CUDA_HOME/lib64:\$CUDA_HOME/targets/x86_64-linux/lib:\$LD_LIBRARY_PATH\"" "$bashrc"

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

  log "Setup complete. Running verification checks"
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
  echo "CUDA_HOME=${CUDA_HOME}"

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
  echo "CUDA_HOME target             : $CUDA_HOME"
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
  grep -nE 'miniforge3/bin|CUDA_HOME|LD_LIBRARY_PATH' "$HOME/.bashrc" || true
  echo "============================================================"
}

do_runbook() {
  cat > "$RUNBOOK_OUT" <<'EOF'
# Conda Node Bootstrap Runbook (Miniforge + Python 3.12)

## 1) Run user bootstrap (NOT root)

\`\`\`bash
./conda-node-bootstrap.sh --mode setup
\`\`\`

## 2) Verify Conda + notebook tooling

\`\`\`bash
./conda-node-bootstrap.sh --mode verify
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
export CUDA_HOME=/usr/local/cuda-12.8
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/targets/x86_64-linux/lib:$LD_LIBRARY_PATH"
\`\`\`

It also configures Conda to auto-install ipykernel for all future environments:

\`\`\`bash
conda config --add create_default_packages ipykernel
\`\`\`
EOF

  log "Generated runbook: $RUNBOOK_OUT"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
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
    --cuda-home)
      CUDA_HOME="$2"
      shift 2
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

case "$MODE" in
  setup)
    do_setup
    ;;
  verify)
    do_verify
    ;;
  runbook)
    do_runbook
    ;;
  *)
    echo "Invalid mode: $MODE" >&2
    usage
    exit 1
    ;;
esac
