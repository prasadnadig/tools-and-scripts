#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# torch-node-bootstrap.sh
#
# Purpose:
# - Bootstrap a basic PyTorch environment on a Linux GPU box.
# - Keep CUDA ownership explicit: this script does NOT install CUDA.
# - Install torch / torchvision / torchaudio from the cu128 wheel index.
#
# Why this script exists:
# - PyTorch wheels are CUDA-version-specific and need the right runtime context.
# - This script makes CUDA_HOME and environment selection explicit.
# - It reduces accidental installs into the wrong Conda env.
#
# What this script does NOT do:
# - It does not install or upgrade CUDA toolkit.
# - It does not install Torch-TTS or other model-specific packages.
# - It does not auto-detect the best torch version for your host.
#
# Safe usage guidance:
# - Keep torch-family packages aligned as a tested set.
# - Confirm the cu128 wheel index and compatibility before upgrading.
# - Re-run verify after any package change.
#
# Current script assumption:
# - CUDA version 12.8 (via CUDA_HOME path) for install/verify flows.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_PYTHON_VERSION="3.12.13"
PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
CUDA_HOME_PATH=""
ENV_NAME=""
CREATE_CONDA_ENV=0

DO_INSTALL=0
DO_VERIFY=0
DO_RUNBOOK=0
DO_SUMMARIZE_INSTALLATION=0

RUNBOOK_OUT="$SCRIPT_DIR/torch-node-bootstrap-runbook.md"
SUMMARY_OUT="$SCRIPT_DIR/torch-node-bootstrap-installation-summary.md"
TORCH_WHEEL_INDEX_URL="https://download.pytorch.org/whl/cu128"

usage() {
	cat <<'EOF'
Usage:
	torch-node-bootstrap.sh [ACTION] [REQUIRED OPTIONS] [OPTIONAL OPTIONS]

Assumption:
	This script currently assumes CUDA version 12.8 and the cu128 wheel index.

Actions (pick exactly one):
	--install                     Install basic PyTorch into a Conda env
	--verify                      Verify environment and key package imports
	--runbook                     Generate runbook markdown documentation
	--summarize-installation      Generate installation summary markdown

Required options for install/verify/summary:
	--env-name <name>             Conda environment name
	--cuda-home <path>            CUDA toolkit root (or set CUDA_HOME)

Optional options:
	--create-conda-env            Create conda env if it does not already exist
	--python-version <version>    Python version when creating env
																Default: 3.12.13
	--runbook-out <path>          Output path for --runbook
																Default: ./torch-node-bootstrap-runbook.md
	--summary-out <path>          Output path for --summarize-installation
																Default: ./torch-node-bootstrap-installation-summary.md
	-h, --help                    Show this help

Examples:
	torch-node-bootstrap.sh --install --env-name torch --cuda-home /usr/local/cuda-12.8 --create-conda-env
	torch-node-bootstrap.sh --verify --env-name torch --cuda-home /usr/local/cuda-12.8
	torch-node-bootstrap.sh --runbook
	torch-node-bootstrap.sh --summarize-installation --env-name torch --cuda-home /usr/local/cuda-12.8
EOF
}

log() {
	echo "[torch-node-bootstrap] $*"
}

die() {
	echo "[torch-node-bootstrap] ERROR: $*" >&2
	exit 1
}

on_error() {
	local exit_code="$1"
	local line_no="$2"
	local cmd="$3"

	echo "[torch-node-bootstrap] ERROR: command failed (exit=${exit_code}) at line ${line_no}" >&2
	echo "[torch-node-bootstrap] ERROR: ${cmd}" >&2

	if [[ "$cmd" == *"conda "* ]]; then
		echo "[torch-node-bootstrap] HINT: Conda command failed. Check Conda installation and whether the target env exists." >&2
		echo "[torch-node-bootstrap] HINT: Re-run with --create-conda-env when the env is missing, or validate with 'conda env list'." >&2
	elif [[ "$cmd" == *"pip install"* ]]; then
		echo "[torch-node-bootstrap] HINT: pip install failed. Verify network access and that the cu128 wheel index is reachable." >&2
	elif [[ "$cmd" == *"python -c"* ]]; then
		echo "[torch-node-bootstrap] HINT: Python runtime/import check failed. Confirm torch packages installed and versions are compatible." >&2
	fi
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_non_root() {
	if [[ "$(id -u)" -eq 0 ]]; then
		die "torch-node-bootstrap.sh must NOT run as root. Run it as the target Unix user."
	fi
}

assert_cuda_12_8_assumption() {
	if [[ "${CUDA_HOME}" != *"12.8"* ]]; then
		die "This script currently assumes CUDA version 12.8. CUDA_HOME is '${CUDA_HOME}'. Set CUDA_HOME to your CUDA 12.8 toolkit path (for example /usr/local/cuda-12.8) before proceeding."
	fi
}

resolve_cuda_home() {
	CUDA_HOME="${CUDA_HOME_PATH:-${CUDA_HOME:-}}"
	if [[ -z "$CUDA_HOME" ]]; then
		die "CUDA_HOME is required. Use --cuda-home <path> or export CUDA_HOME before running this script."
	fi

	if [[ ! -d "$CUDA_HOME" ]]; then
		die "CUDA_HOME points to a non-existent directory: $CUDA_HOME"
	fi

	if [[ ! -d "$CUDA_HOME/bin" ]]; then
		die "CUDA_HOME/bin is missing under: $CUDA_HOME"
	fi

	export CUDA_HOME
}

ensure_cuda_runtime_paths() {
	local lib_a="${CUDA_HOME}/lib64"
	local lib_b="${CUDA_HOME}/targets/x86_64-linux/lib"

	if [[ ":${PATH}:" != *":${CUDA_HOME}/bin:"* ]]; then
		export PATH="${CUDA_HOME}/bin:${PATH}"
		log "Added ${CUDA_HOME}/bin to PATH for this process."
	else
		log "PATH already contains ${CUDA_HOME}/bin."
	fi

	if [[ ":${LD_LIBRARY_PATH:-}:" != *":${lib_a}:"* ]]; then
		export LD_LIBRARY_PATH="${lib_a}:${LD_LIBRARY_PATH:-}"
	fi

	if [[ ":${LD_LIBRARY_PATH:-}:" != *":${lib_b}:"* ]]; then
		export LD_LIBRARY_PATH="${lib_b}:${LD_LIBRARY_PATH:-}"
	fi

	log "CUDA runtime paths are prepared for this process."
}

activate_conda_env() {
	need_cmd conda
	# shellcheck disable=SC1091
	eval "$(conda shell.bash hook)"
	conda activate "$ENV_NAME"
}

conda_env_exists() {
	need_cmd conda
	conda env list | awk '{print $1}' | grep -Fxq "$ENV_NAME"
}

validate_actions() {
	local count=$((DO_INSTALL + DO_VERIFY + DO_RUNBOOK + DO_SUMMARIZE_INSTALLATION))
	if [[ "$count" -eq 0 ]]; then
		usage
		exit 0
	fi
	if [[ "$count" -gt 1 ]]; then
		die "Specify exactly one action: --install OR --verify OR --runbook OR --summarize-installation"
	fi
}

validate_env_requirements() {
	if [[ "$DO_RUNBOOK" -eq 1 ]]; then
		return
	fi

	if [[ -z "$ENV_NAME" ]]; then
		die "--env-name is mandatory for this action. Use --env-name <name>."
	fi

	resolve_cuda_home
	assert_cuda_12_8_assumption
	need_cmd conda

	if conda_env_exists; then
		log "Conda env exists: $ENV_NAME"
		return
	fi

	if [[ "$CREATE_CONDA_ENV" -eq 1 ]]; then
		log "Conda env not found. Creating env: $ENV_NAME (python=$PYTHON_VERSION)"
		conda create -n "$ENV_NAME" "python=$PYTHON_VERSION" pip -y
	else
		die "Conda env '$ENV_NAME' does not exist. Re-run with --create-conda-env to create it."
	fi
}

install_pytorch() {
	need_cmd conda
	conda install -n "$ENV_NAME" pip -y

	activate_conda_env
	need_cmd python

	log "Installing basic PyTorch from cu128 wheel index"
	python -m pip install --index-url "$TORCH_WHEEL_INDEX_URL" torch torchvision torchaudio
}

print_version_summary() {
	python - <<'PY'
import importlib.metadata as metadata
import torch

def version(name):
		try:
				return metadata.version(name)
		except metadata.PackageNotFoundError:
				return "<not installed>"

print("torch", version("torch"))
print("torchvision", version("torchvision"))
print("torchaudio", version("torchaudio"))
print("torch.cuda", torch.version.cuda)
print("cuda_available", torch.cuda.is_available())
PY
}

do_install() {
	require_non_root
	validate_env_requirements
	ensure_cuda_runtime_paths
	install_pytorch
	log "Install action completed for env: $ENV_NAME"
}

do_verify() {
	require_non_root
	validate_env_requirements
	ensure_cuda_runtime_paths
	activate_conda_env

	log "Running basic package and runtime checks"
	print_version_summary
	log "Verify action completed for env: $ENV_NAME"
}

do_runbook() {
	cat > "$RUNBOOK_OUT" <<'EOF'
# Torch Node Bootstrap Runbook

## Purpose

Use this script to bootstrap a basic PyTorch environment on a Linux GPU box.

Script:
- torch-node-bootstrap.sh

## Key design choices

- No CUDA installation is performed by the script.
- Script currently assumes CUDA 12.8.
- CUDA_HOME is mandatory for operational actions.
- A Conda env name is mandatory for install/verify/summary.
- PyTorch is installed from the cu128 wheel index.
- PATH and LD_LIBRARY_PATH are normalized for the current shell execution.

## Typical usage

```bash
# Install (create env if needed)
./torch-node-bootstrap.sh --install --env-name torch --cuda-home /usr/local/cuda-12.8 --create-conda-env

# Verify
./torch-node-bootstrap.sh --verify --env-name torch --cuda-home /usr/local/cuda-12.8

# Generate docs
./torch-node-bootstrap.sh --runbook
./torch-node-bootstrap.sh --summarize-installation --env-name torch --cuda-home /usr/local/cuda-12.8
```

## Important reminders

- Verify CUDA_HOME points to your intended toolkit root.
- Confirm cu128 wheel compatibility before changing package versions.
- Upgrade torch-family packages together, not one-by-one.
EOF

	log "Generated runbook: $RUNBOOK_OUT"
}

do_summarize_installation() {
	require_non_root
	validate_env_requirements
	ensure_cuda_runtime_paths
	activate_conda_env

	cat > "$SUMMARY_OUT" <<EOF
# Torch Node Installation Summary

## Environment
- Conda env: ${ENV_NAME}
- Python target: ${PYTHON_VERSION}
- CUDA_HOME: ${CUDA_HOME}
- Script CUDA assumption: 12.8
- Wheel index: ${TORCH_WHEEL_INDEX_URL}

## Runtime path assumptions made by script
- PATH includes: ${CUDA_HOME}/bin
- LD_LIBRARY_PATH includes:
	- ${CUDA_HOME}/lib64
	- ${CUDA_HOME}/targets/x86_64-linux/lib

## Installed package strategy
- torch from cu128 wheel index
- torchvision from cu128 wheel index
- torchaudio from cu128 wheel index

## Operational caution
This setup assumes your selected CUDA_HOME toolkit should own runtime selection.
If this is not your intent, update CUDA_HOME and rerun install/verify.
Mismatched torch-family versions or wheel indexes can cause runtime .so issues.
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
			--summarize-installation)
				DO_SUMMARIZE_INSTALLATION=1
				shift
				;;
			--env-name)
				[[ $# -ge 2 ]] || die "--env-name requires a value"
				ENV_NAME="$2"
				shift 2
				;;
			--cuda-home)
				[[ $# -ge 2 ]] || die "--cuda-home requires a value"
				CUDA_HOME_PATH="$2"
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

	if [[ "$DO_INSTALL" -eq 1 ]]; then
		do_install
	elif [[ "$DO_VERIFY" -eq 1 ]]; then
		do_verify
	elif [[ "$DO_RUNBOOK" -eq 1 ]]; then
		do_runbook
	elif [[ "$DO_SUMMARIZE_INSTALLATION" -eq 1 ]]; then
		do_summarize_installation
	else
		usage
	fi
}

main "$@"
