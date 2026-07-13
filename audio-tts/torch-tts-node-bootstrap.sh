#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# torch-tts-node-bootstrap.sh
#
# Purpose:
# - Bootstrap a repeatable Torch + TTS node environment on a Linux GPU box.
# - Keep CUDA ownership explicit: this script does NOT install CUDA.
# - Install a known-good torch family (cu128) + f5-tts into a conda env.
#
# Why this script exists:
# - Prior issues were caused by runtime .so mismatch and mixed CUDA libraries.
# - This script makes CUDA_HOME and path assumptions explicit and visible.
# - It enforces env-name correctness and reduces accidental installs to wrong envs.
#
# What this script does NOT do:
# - It does not install or upgrade CUDA toolkit.
# - It does not run deep ldd/ABI symbol checks.
# - It does not auto-detect best torch versions for your CUDA toolkit.
#
# Safe usage guidance:
# - Keep torch / torchaudio / torchcodec versions aligned as a group.
# - Confirm chosen wheel index and versions at: https://download.pytorch.org/whl/
# - If you change versions later, do so as a tested group, not individually.
#
# Current script assumption:
# - CUDA version 12.8 (via CUDA_HOME path) for install/verify flows.
###############################################################################

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_PYTHON_VERSION="3.12.13"
PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
F5_TTS_VERSION="1.1.21"
ENV_NAME=""
CREATE_CONDA_ENV=0

DO_INSTALL=0
DO_VERIFY=0
DO_RUNBOOK=0
DO_INSTALL_SUMMARY=0

RUNBOOK_OUT="$SCRIPT_DIR/torch-tts-node-bootstrap-runbook.md"
SUMMARY_OUT="$SCRIPT_DIR/torch-tts-node-bootstrap-installation-summary.md"

usage() {
  cat <<'EOF'
Usage:
  torch-tts-node-bootstrap.sh [ACTION] [REQUIRED OPTIONS] [OPTIONAL OPTIONS]

Assumption:
  This script currently assumes CUDA version 12.8.
  f5-tts is pinned to version 1.1.21.

Actions (pick exactly one):
  --install                     Install torch-family deps, ffmpeg, and f5-tts
  --verify                      Verify environment and key package imports
  --runbook                     Generate runbook markdown documentation
  --installation-summary        Generate installation summary markdown

Required options for all actions except --runbook:
  --env-name <name>             Conda environment name

Optional options:
  --create-conda-env            Create conda env if it does not already exist
  --python-version <version>    Python version when creating env
                                Default: 3.12.13
  --f5-tts-version <version>    f5-tts version to install
                                Default: 1.1.21
  --runbook-out <path>          Output path for --runbook
                                Default: ./torch-tts-node-bootstrap-runbook.md
  --summary-out <path>          Output path for --installation-summary
                                Default: ./torch-tts-node-bootstrap-installation-summary.md
  -h, --help                    Show this help

Examples:
  torch-tts-node-bootstrap.sh --install --env-name f5-tts --create-conda-env
  torch-tts-node-bootstrap.sh --verify --env-name f5-tts
  torch-tts-node-bootstrap.sh --install --env-name f5-tts --f5-tts-version 1.1.21
  torch-tts-node-bootstrap.sh --runbook
  torch-tts-node-bootstrap.sh --installation-summary --env-name f5-tts
EOF
}

log() {
  echo "[torch-tts-bootstrap] $*"
}

die() {
  echo "[torch-tts-bootstrap] ERROR: $*" >&2
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  local cmd="$3"

  echo "[torch-tts-bootstrap] ERROR: command failed (exit=${exit_code}) at line ${line_no}" >&2
  echo "[torch-tts-bootstrap] ERROR: ${cmd}" >&2

  if [[ "$cmd" == *"conda "* ]]; then
    echo "[torch-tts-bootstrap] HINT: Conda command failed. Check Conda installation and whether the target env exists." >&2
    echo "[torch-tts-bootstrap] HINT: Re-run with --create-conda-env when the env is missing, or validate with 'conda env list'." >&2
  elif [[ "$cmd" == *"pip install"* ]]; then
    echo "[torch-tts-bootstrap] HINT: pip install failed. Verify network access and package index availability." >&2
    echo "[torch-tts-bootstrap] HINT: For torch-family installs, ensure cu128 wheel variants exist for the pinned versions." >&2
  elif [[ "$cmd" == *"python -c"* ]]; then
    echo "[torch-tts-bootstrap] HINT: Python runtime/import check failed. Confirm install completed and package versions are compatible." >&2
  elif [[ "$cmd" == *"f5-tts_infer-gradio"* ]]; then
    echo "[torch-tts-bootstrap] HINT: f5-tts CLI check failed. Ensure f5-tts is installed in the selected Conda environment." >&2
  fi
}

# Prints contextual failure details whenever an unhandled command error occurs.
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

assert_cuda_12_8_assumption() {
  if [[ "${CUDA_HOME}" != *"12.8"* ]]; then
    die "This script currently assumes CUDA version 12.8. CUDA_HOME is '${CUDA_HOME}'. Set CUDA_HOME to your CUDA 12.8 toolkit path (for example /usr/local/cuda-12.8) before proceeding."
  fi
}

# CUDA_HOME is treated as a required contract for operational actions because
# runtime .so loading behavior depends on this value and path precedence.
ensure_cuda_home() {
  if [[ -z "${CUDA_HOME:-}" ]]; then
    die "CUDA_HOME is not set. Export CUDA_HOME to your intended toolkit root (example: /usr/local/cuda-12.8) before running this script."
  fi

  if [[ ! -d "$CUDA_HOME" ]]; then
    die "CUDA_HOME points to a non-existent directory: $CUDA_HOME"
  fi

  if [[ ! -d "$CUDA_HOME/bin" ]]; then
    die "CUDA_HOME/bin is missing under: $CUDA_HOME"
  fi

  # Requirement: check if CUDA_HOME/bin is in PATH, otherwise add and print message.
  if [[ ":${PATH}:" != *":${CUDA_HOME}/bin:"* ]]; then
    export PATH="${CUDA_HOME}/bin:${PATH}"
    log "Added ${CUDA_HOME}/bin to PATH for this process."
  else
    log "PATH already contains ${CUDA_HOME}/bin."
  fi

  # Requirement: check lib64 and targets paths in LD_LIBRARY_PATH and add if needed.
  local lib_a="${CUDA_HOME}/lib64"
  local lib_b="${CUDA_HOME}/targets/x86_64-linux/lib"
  local changed=0

  if [[ ":${LD_LIBRARY_PATH:-}:" != *":${lib_a}:"* ]]; then
    export LD_LIBRARY_PATH="${lib_a}:${LD_LIBRARY_PATH:-}"
    changed=1
  fi

  if [[ ":${LD_LIBRARY_PATH:-}:" != *":${lib_b}:"* ]]; then
    export LD_LIBRARY_PATH="${lib_b}:${LD_LIBRARY_PATH:-}"
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    log "Updated LD_LIBRARY_PATH with CUDA runtime paths for this process."
  else
    log "LD_LIBRARY_PATH already contains required CUDA paths."
  fi
}

activate_conda_env() {
  need_cmd conda
  # shellcheck disable=SC1091
  eval "$(conda shell.bash hook)"
  conda activate "$ENV_NAME"
}

conda_env_exists() {
  conda env list | awk '{print $1}' | grep -Fxq "$ENV_NAME"
}

validate_actions() {
  local count=$((DO_INSTALL + DO_VERIFY + DO_RUNBOOK + DO_INSTALL_SUMMARY))
  if [[ "$count" -eq 0 ]]; then
    usage
    exit 0
  fi
  if [[ "$count" -gt 1 ]]; then
    die "Specify exactly one action: --install OR --verify OR --runbook OR --installation-summary"
  fi
}

validate_env_requirements() {
  # --runbook can work without an env.
  if [[ "$DO_RUNBOOK" -eq 1 ]]; then
    return
  fi

  if [[ -z "$ENV_NAME" ]]; then
    die "--env-name is mandatory for this action. Use --env-name <name>."
  fi

  need_cmd conda

  if conda_env_exists; then
    log "Conda env exists: $ENV_NAME"
    return
  fi

  if [[ "$CREATE_CONDA_ENV" -eq 1 ]]; then
    log "Conda env not found. Creating env: $ENV_NAME (python=$PYTHON_VERSION)"
    conda create -n "$ENV_NAME" "python=$PYTHON_VERSION" -y
  else
    die "Conda env '$ENV_NAME' does not exist. Re-run with --create-conda-env to create it."
  fi
}

write_torch_requirements() {
  local req_file="$1"
  cat > "$req_file" <<'EOF'
# torch-family dependencies are pinned and installed as a tested group.
# Rationale:
# - These versions were selected together to reduce ABI/runtime mismatch risk.
# - Using mismatched torch/torchaudio/torchcodec versions is a common source
#   of dynamic library (.so) load failures on GPU nodes.
# - Keep these three packages aligned as a group when upgrading.
# - Cross-check wheel availability and compatibility at:
#   https://download.pytorch.org/whl/
#
# Selected group:
torch==2.9.1+cu128
torchaudio==2.9.1+cu128
torchcodec==0.9.1+cu128
EOF
}

post_install_runtime_notice() {
  cat <<EOF

[torch-tts-bootstrap] IMPORTANT RUNTIME NOTICE
- This script assumes CUDA runtime ownership via CUDA_HOME: ${CUDA_HOME}
- It has set PATH and LD_LIBRARY_PATH for this process to include:
  - ${CUDA_HOME}/bin
  - ${CUDA_HOME}/lib64
  - ${CUDA_HOME}/targets/x86_64-linux/lib

Please confirm this is your intended runtime/toolkit selection.
If not, .so loading issues may occur at runtime.

Also ensure your chosen torch / torchaudio / torchcodec versions are valid as a group
for this CUDA toolkit and the wheel index used.
Cross-check versions and index at:
  https://download.pytorch.org/whl/
EOF
}

do_install() {
  ensure_cuda_home
  assert_cuda_12_8_assumption
  activate_conda_env

  need_cmd pip

  log "Installing ffmpeg from conda-forge"
  conda install -c conda-forge ffmpeg -y

  local req_file
  req_file="$(mktemp /tmp/torch-family-requirements.XXXXXX.txt)"
  trap "rm -f '$req_file'" EXIT

  write_torch_requirements "$req_file"

  log "Installing torch-family dependencies from cu128 wheel index"
  pip install -r "$req_file" --index-url https://download.pytorch.org/whl/cu128

  log "Installing f5-tts==${F5_TTS_VERSION}"
  pip install "f5-tts==${F5_TTS_VERSION}"

  post_install_runtime_notice
  log "Install action completed for env: $ENV_NAME"
}

do_verify() {
  ensure_cuda_home
  assert_cuda_12_8_assumption
  activate_conda_env

  log "Running basic package and runtime checks"
  python -c "import torch, torchaudio, torchcodec; print('torch', torch.__version__); print('torchaudio', torchaudio.__version__); print('torchcodec import ok')"
  python -c "import torch; print('cuda_available', torch.cuda.is_available())"
  f5-tts_infer-gradio --help >/dev/null && echo "f5-tts CLI ok"

  post_install_runtime_notice
  log "Verify action completed for env: $ENV_NAME"
}

do_runbook() {
  cat > "$RUNBOOK_OUT" <<'EOF'
# Torch TTS Node Bootstrap Runbook

## Purpose

Use this script to bootstrap and verify a Torch + TTS node where CUDA runtime is
explicitly controlled by CUDA_HOME and path exports.

Script:
- torch-tts-node-bootstrap.sh

## Key design choices

- No CUDA installation is performed by the script.
- Script currently assumes CUDA 12.8.
- CUDA_HOME is mandatory for operational actions.
- PATH and LD_LIBRARY_PATH are normalized for current shell execution.
- torch / torchaudio / torchcodec are pinned and installed as a group.
- f5-tts is pinned to a known-good version (`${F5_TTS_VERSION}`).
- ffmpeg is installed from conda-forge.
- f5-tts is installed via pip as `f5-tts==${F5_TTS_VERSION}`.

## Typical usage

```bash
# Install (create env if needed)
./torch-tts-node-bootstrap.sh --install --env-name f5-tts --create-conda-env

# Verify
./torch-tts-node-bootstrap.sh --verify --env-name f5-tts

# Generate docs
./torch-tts-node-bootstrap.sh --runbook
./torch-tts-node-bootstrap.sh --installation-summary --env-name f5-tts
```

## Important reminders

- Verify CUDA_HOME points to your intended toolkit root.
- Confirm wheel compatibility on https://download.pytorch.org/whl/.
- Upgrade torch-family packages together, not one-by-one.
EOF
  log "Generated runbook: $RUNBOOK_OUT"
}

do_installation_summary() {
  ensure_cuda_home
  assert_cuda_12_8_assumption
  activate_conda_env

  cat > "$SUMMARY_OUT" <<EOF
# Torch TTS Node Installation Summary

## Environment
- Conda env: ${ENV_NAME}
- Python target: ${PYTHON_VERSION}
- CUDA_HOME: ${CUDA_HOME}
- Script CUDA assumption: 12.8

## Runtime path assumptions made by script
- PATH includes: ${CUDA_HOME}/bin
- LD_LIBRARY_PATH includes:
  - ${CUDA_HOME}/lib64
  - ${CUDA_HOME}/targets/x86_64-linux/lib

## Installed package strategy
- ffmpeg from conda-forge
- torch-family from cu128 wheel index (installed as a pinned group):
  - torch==2.9.1+cu128
  - torchaudio==2.9.1+cu128
  - torchcodec==0.9.1+cu128
- f5-tts via pip
- f5-tts pinned: f5-tts==${F5_TTS_VERSION}

## Operational caution
This setup assumes your selected CUDA_HOME toolkit should own runtime selection.
If this is not your intent, update CUDA_HOME and rerun install/verify.
Mismatched torch-family versions or wheel indexes can cause runtime .so issues.
Cross-check: https://download.pytorch.org/whl/
EOF

  log "Generated installation summary: $SUMMARY_OUT"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install)
        DO_INSTALL=1
        shift
        ;;
      --verify)
        DO_VERIFY=1
        shift
        ;;
      --runbook)
        DO_RUNBOOK=1
        shift
        ;;
      --installation-summary)
        DO_INSTALL_SUMMARY=1
        shift
        ;;
      --env-name)
        [[ $# -ge 2 ]] || die "--env-name requires a value"
        ENV_NAME="$2"
        shift 2
        ;;
      --create-conda-env)
        CREATE_CONDA_ENV=1
        shift
        ;;
      --python-version)
        [[ $# -ge 2 ]] || die "--python-version requires a value"
        PYTHON_VERSION="$2"
        shift 2
        ;;
      --f5-tts-version)
        [[ $# -ge 2 ]] || die "--f5-tts-version requires a value"
        F5_TTS_VERSION="$2"
        shift 2
        ;;
      --runbook-out)
        [[ $# -ge 2 ]] || die "--runbook-out requires a value"
        RUNBOOK_OUT="$2"
        shift 2
        ;;
      --summary-out)
        [[ $# -ge 2 ]] || die "--summary-out requires a value"
        SUMMARY_OUT="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  validate_actions
  validate_env_requirements

  if [[ "$DO_INSTALL" -eq 1 ]]; then
    do_install
  elif [[ "$DO_VERIFY" -eq 1 ]]; then
    do_verify
  elif [[ "$DO_RUNBOOK" -eq 1 ]]; then
    do_runbook
  elif [[ "$DO_INSTALL_SUMMARY" -eq 1 ]]; then
    do_installation_summary
  else
    usage
  fi
}

main "$@"
