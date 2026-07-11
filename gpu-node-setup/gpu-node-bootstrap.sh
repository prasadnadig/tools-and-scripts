#!/usr/bin/env bash
set -euo pipefail

# gpu-node-bootstrap.sh
# Root-only host bootstrap for GPU nodes.
# Responsibility: host-level CUDA 12.8 user-space runtime/toolkit, Docker, and NVIDIA container runtime.
# This script is idempotent and safe to re-run.
#
# Why these installs matter:
# - cuda-toolkit-12-8: provides CUDA compiler/runtime user-space libraries used by GPU workloads.
# - Docker + compose/buildx: standard container runtime and build workflow.
# - nvidia-container-toolkit: enables Docker containers to access host GPUs.
# - profile.d CUDA exports: ensures CUDA binaries/libraries are discoverable in shells by default.
#
# Modes:
#   setup    -> install/configure components
#   verify   -> run diagnostics
#   runbook  -> emit a concise markdown runbook
#
# Extra option:
#   --summarize-installation -> print installed versions/details (standalone or after setup)
#   --install-nvidia-driver  -> install host NVIDIA driver stack (idempotent)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
RUNBOOK_OUT="$SCRIPT_DIR/gpu-node-bootstrap-runbook.md"
CUDA_TOOLKIT_APT_PACKAGE="cuda-toolkit-12-8"
CUDA_HOME="/usr/local/cuda-12.8"
NVIDIA_CONTAINER_TOOLKIT_VERSION="latest"
SKIP_DOCKER_INSTALL=0
SUMMARIZE_ONLY=0
INSTALL_NVIDIA_DRIVER_ONLY=0
ACTION_SELECTED=0
ARG_COUNT=$#

usage() {
  cat <<'EOF'
Usage:
  sudo ./gpu-node-bootstrap.sh --mode setup|verify|runbook [options]
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver [options]
  sudo ./gpu-node-bootstrap.sh --summarize-installation [options]

Notes:
  - At least one action option is required: --mode, --install-nvidia-driver, or --summarize-installation
  - Running with no arguments only prints this help
  - Re-running setup/driver install is safe (idempotent) and intended for repair workflows

Options:
  --mode <mode>                                setup, verify, runbook
  --install-nvidia-driver                      Install/update host NVIDIA drivers (idempotent)
  --cuda-toolkit-apt-package <name>            APT CUDA toolkit package (default: cuda-toolkit-12-8)
  --cuda-home <path>                           CUDA_HOME path (default: /usr/local/cuda-12.8)
  --nvidia-container-toolkit-version <version> Toolkit version to install (default: latest)
  --skip-docker-install                         Skip Docker install/configuration
  --runbook-out <path>                         Output path for runbook mode
  --summarize-installation                      Print key versions/details and exit
  -h, --help                                   Show this help

Examples:
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
  sudo ./gpu-node-bootstrap.sh --mode setup
  sudo ./gpu-node-bootstrap.sh --mode verify
  sudo ./gpu-node-bootstrap.sh --nvidia-container-toolkit-version 1.17.8-1
  sudo ./gpu-node-bootstrap.sh --summarize-installation
EOF
}

log() {
  echo "[gpu-node-bootstrap] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: gpu-node-bootstrap.sh must run as root." >&2
    echo "Usage: sudo ./gpu-node-bootstrap.sh ..." >&2
    exit 1
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Package already installed: $pkg"
  else
    log "Installing package: $pkg"
    apt-get install -y "$pkg"
  fi
}

ensure_apt_candidate() {
  local pkg="$1"
  local candidate
  candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"

  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "ERROR: APT cannot resolve package: $pkg" >&2
    echo "Check configured repos and run: apt-get update" >&2
    echo >&2
    echo "Diagnostics:" >&2
    apt-cache policy "$pkg" >&2 || true
    return 1
  fi

  return 0
}

has_nvidia_smi() {
  command -v nvidia-smi >/dev/null 2>&1
}

has_libnvidia_ml() {
  ldconfig -p 2>/dev/null | grep -q 'libnvidia-ml.so.1'
}

print_nvidia_driver_remediation() {
  cat <<'EOF'
NVIDIA driver userspace is missing (nvidia-smi/libnvidia-ml.so.1 not found).
Install host NVIDIA drivers first, then reboot.

Suggested commands (Ubuntu):
  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall
  sudo reboot

After reboot, rerun:
  sudo ./gpu-node-bootstrap.sh --mode setup
EOF
}

install_nvidia_driver() {
  require_root
  need_cmd apt-get

  log "Installing/updating host NVIDIA driver stack (idempotent)"
  apt-get update -y
  apt_install_if_missing ubuntu-drivers-common

  ubuntu-drivers devices || true
  ubuntu-drivers autoinstall

  echo
  echo "NVIDIA driver installation step completed."
  echo "A reboot is required before GPU runtime checks will pass."
  echo "Run: sudo reboot"
}

require_nvidia_driver_ready_for_setup() {
  if has_nvidia_smi && has_libnvidia_ml; then
    return
  fi

  echo "ERROR: NVIDIA drivers are not ready on this host." >&2
  print_nvidia_driver_remediation >&2
  echo "Or run the script action: sudo ./gpu-node-bootstrap.sh --install-nvidia-driver" >&2
  exit 1
}

install_base_packages() {
  # gpg and curl are needed for vendor repository key management.
  local pkgs=(
    ca-certificates
    curl
    gnupg
    lsb-release
    software-properties-common
    apt-transport-https
    wget
    ripgrep
    tree
  )

  for pkg in "${pkgs[@]}"; do
    apt_install_if_missing "$pkg"
  done
}

install_cuda_toolkit() {
  setup_cuda_repo

  # Uses the CUDA package/version stream requested by the caller, defaulting to CUDA 12.8.
  apt_install_if_missing "$CUDA_TOOLKIT_APT_PACKAGE"
}

setup_cuda_repo() {
  # Ubuntu repos usually do not carry version-pinned CUDA packages like cuda-toolkit-12-8.
  # Install NVIDIA's cuda-keyring package once so APT can resolve CUDA 12.8 packages.
  if dpkg -s cuda-keyring >/dev/null 2>&1; then
    log "CUDA repository keyring already installed"
    apt-get update -y
    return
  fi

  local distro
  distro="$(. /etc/os-release && echo "ubuntu${VERSION_ID//./}")"

  local keyring_deb
  keyring_deb="/tmp/cuda-keyring_1.1-1_all.deb"

  log "Installing NVIDIA CUDA APT keyring for ${distro}"
  curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb" -o "$keyring_deb"
  dpkg -i "$keyring_deb"
  rm -f "$keyring_deb"

  apt-get update -y
}

write_cuda_profile() {
  local profile_file="/etc/profile.d/cuda-12-8-runtime.sh"

  cat > "$profile_file" <<EOF
export CUDA_HOME=$CUDA_HOME
export PATH="\$CUDA_HOME/bin:\$PATH"
export LD_LIBRARY_PATH="\$CUDA_HOME/lib64:\$CUDA_HOME/targets/x86_64-linux/lib:\$LD_LIBRARY_PATH"
EOF

  chmod 0644 "$profile_file"
  log "Wrote CUDA environment profile: $profile_file"
}

install_docker_stack() {
  if [[ "$SKIP_DOCKER_INSTALL" -eq 1 ]]; then
    log "Skipping Docker installation by request"
    return
  fi

  log "Installing Docker from official repository"
  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

setup_nvidia_container_repo() {
  install -m 0755 -d /usr/share/keyrings

  if [[ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  fi

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
}

install_nvidia_container_toolkit() {
  setup_nvidia_container_repo
  apt-get update -y

  if ! ensure_apt_candidate nvidia-container-toolkit; then
    echo "Repo file content (/etc/apt/sources.list.d/nvidia-container-toolkit.list):" >&2
    if [[ -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
      cat /etc/apt/sources.list.d/nvidia-container-toolkit.list >&2
    else
      echo "(not found)" >&2
    fi
    exit 1
  fi

  if [[ "$NVIDIA_CONTAINER_TOOLKIT_VERSION" == "latest" ]]; then
    apt-get install -y nvidia-container-toolkit
  else
    apt-get install -y "nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
  fi

  if command -v nvidia-ctk >/dev/null 2>&1; then
    # Configures Docker runtime integration for GPU passthrough.
    nvidia-ctk runtime configure --runtime=docker || true
  fi

  if systemctl list-unit-files | grep -q '^docker.service'; then
    systemctl restart docker || true
  fi
}

do_setup() {
  require_root
  need_cmd apt-get

  log "Host checks"
  lsb_release -a || true
  nvidia-smi || true
  nvcc --version || true

  log "Refreshing APT cache"
  apt-get update -y

  require_nvidia_driver_ready_for_setup

  install_base_packages
  install_cuda_toolkit
  write_cuda_profile
  install_docker_stack
  install_nvidia_container_toolkit

  log "Setup complete. Running verification checks"
  do_verify
}

do_verify() {
  require_root

  log "Core checks"
  if has_nvidia_smi; then
    nvidia-smi || true
  else
    log "nvidia-smi not found in PATH"
  fi
  nvcc --version || true

  if command -v ldconfig >/dev/null 2>&1; then
    log "CUDA runtime library visibility checks"
    ldconfig -p | egrep 'libcudart.so|libnvrtc.so|libnppicc.so' || true
    log "NVIDIA management library visibility check"
    ldconfig -p | grep 'libnvidia-ml.so.1' || true
  fi

  if ! has_nvidia_smi || ! has_libnvidia_ml; then
    print_nvidia_driver_remediation
  fi

  log "Command path checks"
  which nvidia-smi nvcc docker nvidia-ctk || true

  if command -v docker >/dev/null 2>&1; then
    docker --version || true
    docker info --format '{{json .Runtimes}}' || true

    if has_nvidia_smi && has_libnvidia_ml; then
      docker run --rm --gpus all nvidia/cuda:12.8.1-runtime-ubuntu22.04 nvidia-smi || true
    else
      log "Skipping Docker GPU smoke test because host NVIDIA driver userspace is not ready"
    fi
  fi

  summarize_installation
}

summarize_installation() {
  echo
  echo "============================================================"
  echo "GPU node installation summary"
  echo "============================================================"
  echo "CUDA apt package target       : $CUDA_TOOLKIT_APT_PACKAGE"
  echo "CUDA_HOME target              : $CUDA_HOME"
  echo "NVIDIA toolkit version target : $NVIDIA_CONTAINER_TOOLKIT_VERSION"
  echo

  echo "Installed package versions:"
  dpkg -l | egrep 'cuda-toolkit-12-8|nvidia-container-toolkit|docker-ce|containerd.io' || true
  echo

  echo "Detected runtime/tool versions:"
  if has_nvidia_smi; then
    nvidia-smi --query-gpu=driver_version,name --format=csv,noheader || true
  else
    echo "nvidia-smi: not found"
  fi
  nvcc --version || true
  docker --version || true
  nvidia-ctk --version || true
  echo

  echo "CUDA linker visibility:"
  ldconfig -p | egrep 'libcudart.so|libnvrtc.so|libnppicc.so' || true
  echo
  echo "NVIDIA management library visibility:"
  ldconfig -p | grep 'libnvidia-ml.so.1' || true
  echo

  echo "Profile config (/etc/profile.d/cuda-12-8-runtime.sh):"
  if [[ -f /etc/profile.d/cuda-12-8-runtime.sh ]]; then
    cat /etc/profile.d/cuda-12-8-runtime.sh
  else
    echo "(not found)"
  fi
  echo "============================================================"
}

do_runbook() {
  cat > "$RUNBOOK_OUT" <<EOF
# GPU Node Bootstrap Runbook (CUDA 12.8 + NVIDIA Container Toolkit)

## 1) Run host bootstrap (root)

\`\`\`bash
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --mode setup
\`\`\`

## 2) Verify host + runtime wiring

\`\`\`bash
sudo ./gpu-node-bootstrap.sh --mode verify
\`\`\`

## 3) Print installed versions/details

\`\`\`bash
sudo ./gpu-node-bootstrap.sh --summarize-installation
\`\`\`

## 4) Useful verification commands

\`\`\`bash
nvidia-smi
nvcc --version
docker --version
docker info --format '{{json .Runtimes}}'
docker run --rm --gpus all nvidia/cuda:12.8.1-runtime-ubuntu22.04 nvidia-smi
\`\`\`

## 5) Shell runtime defaults

This script writes:

- /etc/profile.d/cuda-12-8-runtime.sh

with:

\`\`\`bash
export CUDA_HOME=/usr/local/cuda-12.8
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/targets/x86_64-linux/lib:$LD_LIBRARY_PATH"
\`\`\`
EOF

  log "Generated runbook: $RUNBOOK_OUT"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      ACTION_SELECTED=1
      shift 2
      ;;
    --install-nvidia-driver)
      INSTALL_NVIDIA_DRIVER_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --cuda-toolkit-apt-package)
      CUDA_TOOLKIT_APT_PACKAGE="$2"
      shift 2
      ;;
    --cuda-home)
      CUDA_HOME="$2"
      shift 2
      ;;
    --nvidia-container-toolkit-version)
      NVIDIA_CONTAINER_TOOLKIT_VERSION="$2"
      shift 2
      ;;
    --skip-docker-install)
      SKIP_DOCKER_INSTALL=1
      shift
      ;;
    --runbook-out)
      RUNBOOK_OUT="$2"
      shift 2
      ;;
    --summarize-installation)
      SUMMARIZE_ONLY=1
      ACTION_SELECTED=1
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

if [[ "$ARG_COUNT" -eq 0 && "$ACTION_SELECTED" -eq 0 ]]; then
  usage
  exit 0
fi

if [[ "$ACTION_SELECTED" -eq 0 ]]; then
  echo "ERROR: No action selected. Choose one of: --mode, --install-nvidia-driver, --summarize-installation" >&2
  usage
  exit 1
fi

if [[ "$INSTALL_NVIDIA_DRIVER_ONLY" -eq 1 ]]; then
  install_nvidia_driver
  exit 0
fi

if [[ "$SUMMARIZE_ONLY" -eq 1 ]]; then
  require_root
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
