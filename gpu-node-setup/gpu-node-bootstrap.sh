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
#   setup-cuda-runtimes -> install/configure CUDA runtime + container runtime components
#   verify   -> run diagnostics
#   runbook  -> emit a concise markdown runbook
#
# Extra option:
#   --summarize-installation -> print installed versions/details (standalone or after setup)
#   --setup-all              -> run the full golden-path install flow end-to-end (idempotent)
#   --install-base-packages  -> install host prerequisites before driver/runtime steps (idempotent)
#   --install-nvidia-driver  -> install host NVIDIA driver stack (idempotent)
#   --install-cuda-runtime   -> install CUDA toolkit/runtime and active profile (idempotent)
#   --install-cuda-container-runtime -> install NVIDIA container runtime integration (idempotent)
#   --switch-active-cuda     -> switch active CUDA runtime profile (idempotent)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/gpu-node-bootstrap"
BASE_PACKAGES_MARKER="$STATE_DIR/base-packages.done"
DRIVER_INSTALL_MARKER="$STATE_DIR/nvidia-driver.done"
CUDA_RUNTIME_MARKER="$STATE_DIR/cuda-runtime.done"
CUDA_CONTAINER_RUNTIME_MARKER="$STATE_DIR/cuda-container-runtime.done"

MODE=""
RUNBOOK_OUT="$SCRIPT_DIR/gpu-node-bootstrap-runbook.md"
CUDA_TOOLKIT_APT_PACKAGE="cuda-toolkit-12-8"
CUDA_HOME="/usr/local/cuda-12.8"
NVIDIA_CONTAINER_TOOLKIT_VERSION="latest"
NVIDIA_DRIVER_BRANCH="580"
NVIDIA_DRIVER_VERSION=""
DISABLE_NVIDIA_HOLD=0
SKIP_DOCKER_INSTALL=0
SUMMARIZE_ONLY=0
SETUP_ALL_ONLY=0
INSTALL_BASE_PACKAGES_ONLY=0
INSTALL_NVIDIA_DRIVER_ONLY=0
INSTALL_CUDA_RUNTIME_ONLY=0
INSTALL_CUDA_CONTAINER_RUNTIME_ONLY=0
SWITCH_ACTIVE_CUDA_HOME=""
ACTION_SELECTED=0
ARG_COUNT=$#

usage() {
  cat <<'EOF'
Usage:
  sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes|verify|runbook [options]
  sudo ./gpu-node-bootstrap.sh --setup-all [options]
  sudo ./gpu-node-bootstrap.sh --install-base-packages [options]
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver [options]
  sudo ./gpu-node-bootstrap.sh --install-cuda-runtime [options]
  sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime [options]
  sudo ./gpu-node-bootstrap.sh --switch-active-cuda <cuda-home> [options]
  sudo ./gpu-node-bootstrap.sh --summarize-installation [options]

Notes:
  - At least one action option is required: --mode, --setup-all, --install-base-packages, --install-nvidia-driver, --install-cuda-runtime, --install-cuda-container-runtime, --switch-active-cuda, or --summarize-installation
  - Running with no arguments only prints this help
  - Run --install-base-packages first on a fresh host so help can inspect and suggest NVIDIA driver candidates for the next step
  - Run --install-nvidia-driver second, then reboot
  - After drivers are ready, --install-cuda-container-runtime can be installed independently of host CUDA toolkit/runtime
  - Host CUDA runtime is optional for container-first GPU nodes
  - --setup-all follows the full golden path and stops at the first failing step
  - Re-running setup/driver install is safe (idempotent) and intended for repair workflows
  - Re-running CUDA profile switches is safe (idempotent)

Options:
  --mode <mode>                                setup-cuda-runtimes, verify, runbook
  --setup-all                                  Run full golden-path install flow end-to-end
  --install-base-packages                      Install host prerequisite packages before driver/runtime steps
  --install-nvidia-driver                      Install/update host NVIDIA drivers (idempotent)
  --install-cuda-runtime                       Install CUDA toolkit/runtime and active CUDA shell profile
  --install-cuda-container-runtime             Install NVIDIA container runtime integration for Docker
  --switch-active-cuda <path>                  Switch active CUDA runtime profile (idempotent)
  --nvidia-driver-branch <branch>              Driver branch to install/pin (default: 580)
  --nvidia-driver-version <ver>                Exact driver version to pin (example: 580.173.02-1ubuntu1)
  --disable-nvidia-hold                        Do not apt-mark hold NVIDIA packages after install
  --cuda-toolkit-apt-package <name>            APT CUDA toolkit package (default: cuda-toolkit-12-8)
  --cuda-home <path>                           CUDA_HOME path (default: /usr/local/cuda-12.8)
  --nvidia-container-toolkit-version <version> Toolkit version to install (default: latest)
  --skip-docker-install                         Skip Docker install/configuration
  --runbook-out <path>                         Output path for runbook mode
  --summarize-installation                      Print key versions/details and exit
  -h, --help                                   Show this help

Examples (all options reference):
  sudo ./gpu-node-bootstrap.sh --setup-all
  sudo ./gpu-node-bootstrap.sh --install-base-packages
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
  sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
  sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-version 580.173.02-1ubuntu1
  sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes
  sudo ./gpu-node-bootstrap.sh --switch-active-cuda /usr/local/cuda-12.8
  sudo ./gpu-node-bootstrap.sh --mode verify
  sudo ./gpu-node-bootstrap.sh --nvidia-container-toolkit-version 1.17.8-1
  sudo ./gpu-node-bootstrap.sh --summarize-installation

Examples (golden path):
  sudo ./gpu-node-bootstrap.sh --install-base-packages
  sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580
  sudo reboot
  # after reboot
  sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
  # optional host CUDA toolkit/runtime
  sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
  sudo ./gpu-node-bootstrap.sh --mode verify
  sudo ./gpu-node-bootstrap.sh --summarize-installation
EOF

  print_driver_upgrade_advice
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

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

mark_action_complete() {
  local marker="$1"
  ensure_state_dir
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker"
}

base_packages_ready() {
  [[ -f "$BASE_PACKAGES_MARKER" ]] && return 0

  if dpkg -s ubuntu-drivers-common >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    mark_action_complete "$BASE_PACKAGES_MARKER"
    return 0
  fi

  return 1
}

driver_install_ready() {
  [[ -f "$DRIVER_INSTALL_MARKER" ]] && return 0

  if has_nvidia_smi && has_libnvidia_ml; then
    mark_action_complete "$DRIVER_INSTALL_MARKER"
    return 0
  fi

  return 1
}

cuda_runtime_ready() {
  [[ -f "$CUDA_RUNTIME_MARKER" ]] && return 0

  if dpkg -s "$CUDA_TOOLKIT_APT_PACKAGE" >/dev/null 2>&1; then
    mark_action_complete "$CUDA_RUNTIME_MARKER"
    return 0
  fi

  return 1
}

cuda_container_runtime_ready() {
  [[ -f "$CUDA_CONTAINER_RUNTIME_MARKER" ]] && return 0

  if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    mark_action_complete "$CUDA_CONTAINER_RUNTIME_MARKER"
    return 0
  fi

  return 1
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

apt_candidate_version() {
  local pkg="$1"
  apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

recommended_driver_package() {
  if ! command -v ubuntu-drivers >/dev/null 2>&1; then
    return
  fi

  ubuntu-drivers devices 2>/dev/null \
    | awk '
      /recommended/ {
        for (i = 1; i <= NF; i++) {
          token = $i
          gsub(/[^a-zA-Z0-9._+-]/, "", token)
          if (token ~ /^nvidia-driver-[0-9]+([a-zA-Z0-9._+-]*)?$/) {
            print token
            exit
          }
        }
      }
    '
}

installed_driver_version() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1
  fi
}

driver_branch_from_package() {
  local pkg="$1"
  echo "$pkg" | sed -E 's/^nvidia-driver-([0-9]+).*$/\1/'
}

print_driver_upgrade_advice() {
  local kernel current recommended_pkg recommended_branch recommended_candidate module_open_pkg module_pkg module_open_candidate module_candidate

  kernel="$(uname -r 2>/dev/null || echo unknown)"
  current="$(installed_driver_version || true)"
  recommended_pkg="$(recommended_driver_package || true)"

  echo
  echo "Driver Upgrade Guidance"
  echo "-----------------------"
  echo "Current kernel              : $kernel"
  echo "Installed driver version    : ${current:-not detected}"

  if [[ -n "$recommended_pkg" ]]; then
    recommended_branch="$(driver_branch_from_package "$recommended_pkg")"
    recommended_candidate="$(apt_candidate_version "$recommended_pkg")"
    module_open_pkg="linux-modules-nvidia-${recommended_branch}-open-${kernel}"
    module_pkg="linux-modules-nvidia-${recommended_branch}-${kernel}"
    module_open_candidate="$(apt_candidate_version "$module_open_pkg")"
    module_candidate="$(apt_candidate_version "$module_pkg")"

    echo "Recommended driver package  : $recommended_pkg"
    echo "Best upgrade candidate now  : ${recommended_candidate:-not available}"
    echo "Kernel module candidate     : $module_open_pkg => ${module_open_candidate:-none}"
    echo "Kernel module fallback      : $module_pkg => ${module_candidate:-none}"
    echo "Tip                         : choose a branch where both driver and kernel module candidates are available"
  else
    echo "Recommended driver package  : unavailable (run --install-base-packages first so help can inspect and suggest the next NVIDIA driver step)"
  fi
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
  sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
  sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
  # or use the wrapper:
  sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes
EOF
}

setup_all_failure() {
  local step="$1"
  local rerun_hint="$2"
  local exit_code="$3"

  echo >&2
  echo "ERROR: setup-all stopped during step: $step" >&2
  echo "Resolve the issue shown above, then rerun the full flow or the specific step." >&2
  echo "Suggested retry: $rerun_hint" >&2
  echo "The script is idempotent, so repeating completed steps is safe." >&2
  exit "$exit_code"
}

run_setup_all_step() {
  local label="$1"
  local rerun_hint="$2"
  shift 2

  log "setup-all: starting ${label}"
  if "$@"; then
    log "setup-all: completed ${label}"
    return 0
  fi

  setup_all_failure "$label" "$rerun_hint" 1
}

setup_all_action() {
  require_root
  need_cmd apt-get

  run_setup_all_step \
    "base packages" \
    "sudo ./gpu-node-bootstrap.sh --install-base-packages" \
    install_base_packages_action

  if driver_install_ready; then
    log "setup-all: detected working NVIDIA driver userspace; continuing with runtime steps"
  else
    run_setup_all_step \
      "nvidia driver install" \
      "sudo ./gpu-node-bootstrap.sh --install-nvidia-driver${NVIDIA_DRIVER_VERSION:+ --nvidia-driver-version $NVIDIA_DRIVER_VERSION}${NVIDIA_DRIVER_BRANCH:+ --nvidia-driver-branch $NVIDIA_DRIVER_BRANCH}" \
      install_nvidia_driver

    echo
    echo "setup-all requires a reboot before runtime steps can continue." >&2
    echo "Run: sudo reboot" >&2
    echo "After reboot, rerun: sudo ./gpu-node-bootstrap.sh --setup-all" >&2
    echo "Completed steps are recorded; rerunning is safe." >&2
    return 0
  fi

  run_setup_all_step \
    "nvidia container runtime" \
    "sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime" \
    install_cuda_container_runtime_action

  run_setup_all_step \
    "host cuda runtime" \
    "sudo ./gpu-node-bootstrap.sh --install-cuda-runtime" \
    install_cuda_runtime_action

  run_setup_all_step \
    "verification" \
    "sudo ./gpu-node-bootstrap.sh --mode verify" \
    do_verify

  echo
  echo "setup-all completed successfully." >&2
  echo "The script is idempotent, so rerunning --setup-all is safe for repair workflows." >&2
}

install_nvidia_driver() {
  local target_driver_pkg

  require_root
  need_cmd apt-get

  require_base_packages_completed

  target_driver_pkg="nvidia-driver-${NVIDIA_DRIVER_BRANCH}"

  log "Installing/updating host NVIDIA driver stack (idempotent, branch=${NVIDIA_DRIVER_BRANCH})"
  apt-get update -y
  apt-get -y --fix-broken install || true
  apt_install_if_missing ubuntu-drivers-common

  write_nvidia_pin_preferences
  apt-get update -y

  ubuntu-drivers devices || true

  if ! ensure_apt_candidate "$target_driver_pkg"; then
    echo "ERROR: Driver package candidate not available: $target_driver_pkg" >&2
    print_driver_upgrade_advice >&2
    exit 1
  fi

  apt-get install -y "$target_driver_pkg"

  if [[ "$DISABLE_NVIDIA_HOLD" -eq 0 ]]; then
    hold_nvidia_branch_packages
  else
    log "Skipping apt-mark hold for NVIDIA packages by request"
  fi

  echo
  echo "NVIDIA driver installation step completed."
  echo "Pinned branch               : ${NVIDIA_DRIVER_BRANCH}"
  if [[ -n "$NVIDIA_DRIVER_VERSION" ]]; then
    echo "Pinned exact version        : ${NVIDIA_DRIVER_VERSION}"
  fi
  echo "A reboot is required before GPU runtime checks will pass."
  echo "Run: sudo reboot"

  mark_action_complete "$DRIVER_INSTALL_MARKER"
}

require_base_packages_completed() {
  if base_packages_ready; then
    return
  fi

  echo "ERROR: Base packages step has not been completed on this host." >&2
  echo "Run first: sudo ./gpu-node-bootstrap.sh --install-base-packages" >&2
  exit 1
}

require_driver_install_completed() {
  if driver_install_ready; then
    return
  fi

  echo "ERROR: NVIDIA driver installation step has not been completed on this host." >&2
  echo "Run next: sudo ./gpu-node-bootstrap.sh --install-nvidia-driver" >&2
  exit 1
}

install_base_packages_action() {
  require_root
  need_cmd apt-get

  log "Installing base host packages and Ubuntu-side prerequisites (idempotent)"
  apt-get update -y

  install_base_packages
  apt_install_if_missing ubuntu-drivers-common
  install_docker_stack

  mark_action_complete "$BASE_PACKAGES_MARKER"

  echo
  echo "Base packages installation step completed."
  echo "Next step: sudo ./gpu-node-bootstrap.sh --install-nvidia-driver"
}

install_cuda_runtime_action() {
  require_root
  need_cmd apt-get

  require_base_packages_completed
  require_driver_install_completed
  require_nvidia_driver_ready_for_setup

  log "Installing CUDA toolkit/runtime and active profile (idempotent)"
  apt-get update -y

  install_cuda_toolkit
  write_cuda_profile

  mark_action_complete "$CUDA_RUNTIME_MARKER"

  echo
  echo "CUDA runtime installation step completed."
  echo "Next step: optionally install container runtime with: sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime"
}

install_cuda_container_runtime_action() {
  require_root
  need_cmd apt-get

  require_base_packages_completed
  require_driver_install_completed
  require_nvidia_driver_ready_for_setup

  log "Installing NVIDIA container runtime integration (idempotent)"
  apt-get update -y

  install_nvidia_container_toolkit

  mark_action_complete "$CUDA_CONTAINER_RUNTIME_MARKER"

  echo
  echo "CUDA container runtime installation step completed."
  echo "Next step: verify with sudo ./gpu-node-bootstrap.sh --mode verify"
}

write_nvidia_pin_preferences() {
  local pin_file pin_version

  pin_file="/etc/apt/preferences.d/nvidia-driver-pin"
  pin_version="${NVIDIA_DRIVER_VERSION:-${NVIDIA_DRIVER_BRANCH}.*}"

  cat > "$pin_file" <<EOF
Package: nvidia-driver-${NVIDIA_DRIVER_BRANCH} nvidia-kernel-common-${NVIDIA_DRIVER_BRANCH} nvidia-utils-${NVIDIA_DRIVER_BRANCH} libnvidia-compute-${NVIDIA_DRIVER_BRANCH} linux-modules-nvidia-${NVIDIA_DRIVER_BRANCH}-* linux-objects-nvidia-${NVIDIA_DRIVER_BRANCH}-* nvidia-dkms-${NVIDIA_DRIVER_BRANCH}
Pin: version ${pin_version}
Pin-Priority: 1001
EOF

  chmod 0644 "$pin_file"
  log "Wrote NVIDIA apt pin preferences: $pin_file (version=${pin_version})"
}

hold_nvidia_branch_packages() {
  local pkgs=()
  local pkg

  for pkg in \
    "nvidia-driver-${NVIDIA_DRIVER_BRANCH}" \
    "nvidia-kernel-common-${NVIDIA_DRIVER_BRANCH}" \
    "nvidia-utils-${NVIDIA_DRIVER_BRANCH}" \
    "libnvidia-compute-${NVIDIA_DRIVER_BRANCH}" \
    "nvidia-dkms-${NVIDIA_DRIVER_BRANCH}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      pkgs+=("$pkg")
    fi
  done

  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    apt-mark hold "${pkgs[@]}" >/dev/null
    log "Held NVIDIA packages: ${pkgs[*]}"
  else
    log "No installed NVIDIA packages found to hold for branch ${NVIDIA_DRIVER_BRANCH}"
  fi
}

cuda_slug_from_home() {
  local home="$1"
  local slug

  slug="${home#/usr/local/}"
  slug="${slug//\//-}"
  slug="${slug//[^a-zA-Z0-9._-]/-}"

  echo "$slug"
}

profile_path_for_cuda_home() {
  local home="$1"
  local slug

  slug="$(cuda_slug_from_home "$home")"
  echo "/etc/profile.d/cuda-${slug}-runtime.sh"
}

write_cuda_profile_for_home() {
  local home="$1"
  local profile_file

  profile_file="$(profile_path_for_cuda_home "$home")"

  cat > "$profile_file" <<EOF
export CUDA_HOME=$home
export PATH="\$CUDA_HOME/bin:\$PATH"
export LD_LIBRARY_PATH="\$CUDA_HOME/lib64:\$CUDA_HOME/targets/x86_64-linux/lib:\$LD_LIBRARY_PATH"
EOF

  chmod 0644 "$profile_file"
  ln -sfn "$profile_file" /etc/profile.d/cuda-active-runtime.sh

  log "Wrote CUDA environment profile: $profile_file"
  log "Updated active CUDA profile symlink: /etc/profile.d/cuda-active-runtime.sh -> $profile_file"
}

switch_active_cuda() {
  local home="$1"

  require_root

  if [[ -z "$home" ]]; then
    echo "ERROR: --switch-active-cuda requires a path argument." >&2
    exit 1
  fi

  if [[ ! -d "$home" ]]; then
    echo "ERROR: CUDA home path does not exist: $home" >&2
    exit 1
  fi

  if [[ ! -d "$home/bin" || ! -d "$home/lib64" ]]; then
    echo "ERROR: Invalid CUDA home (missing bin/lib64): $home" >&2
    exit 1
  fi

  write_cuda_profile_for_home "$home"

  echo
  echo "Active CUDA runtime switched to: $home"
  echo "Open a new shell or run: source /etc/profile"
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
  write_cuda_profile_for_home "$CUDA_HOME"
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

  require_base_packages_completed
  require_driver_install_completed
  require_nvidia_driver_ready_for_setup

  install_cuda_container_runtime_action
  install_cuda_runtime_action

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
  echo "NVIDIA driver branch target   : $NVIDIA_DRIVER_BRANCH"
  if [[ -n "$NVIDIA_DRIVER_VERSION" ]]; then
    echo "NVIDIA driver version target  : $NVIDIA_DRIVER_VERSION"
  fi
  echo "Active CUDA profile link      : /etc/profile.d/cuda-active-runtime.sh"
  echo "Base packages marker          : $BASE_PACKAGES_MARKER"
  echo "Driver install marker         : $DRIVER_INSTALL_MARKER"
  echo "CUDA runtime marker           : $CUDA_RUNTIME_MARKER"
  echo "CUDA container marker         : $CUDA_CONTAINER_RUNTIME_MARKER"
  echo

  echo "Installed package versions:"
  dpkg -l | egrep 'cuda-toolkit-12-8|nvidia-container-toolkit|docker-ce|containerd.io|nvidia-driver-[0-9]+|nvidia-kernel-common-[0-9]+' || true
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

  echo "Held NVIDIA packages:"
  apt-mark showhold | grep '^nvidia' || true
  echo

  print_driver_upgrade_advice
  echo

  echo "Profile config (active):"
  if [[ -L /etc/profile.d/cuda-active-runtime.sh ]]; then
    ls -l /etc/profile.d/cuda-active-runtime.sh
    cat /etc/profile.d/cuda-active-runtime.sh
  elif [[ -f /etc/profile.d/cuda-active-runtime.sh ]]; then
    cat /etc/profile.d/cuda-active-runtime.sh
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
sudo ./gpu-node-bootstrap.sh --install-base-packages
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime

# optional host CUDA toolkit/runtime
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime

# convenience wrapper for both runtime steps
sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes
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

This script writes one profile per CUDA home and updates an active symlink:

- /etc/profile.d/cuda-<slug>-runtime.sh
- /etc/profile.d/cuda-active-runtime.sh

with:

\`\`\`bash
export CUDA_HOME=/usr/local/cuda-12.8
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/targets/x86_64-linux/lib:$LD_LIBRARY_PATH"
\`\`\`

## 6) Switch active CUDA runtime

\`\`\`bash
sudo ./gpu-node-bootstrap.sh --switch-active-cuda /usr/local/cuda-12.8
\`\`\`

## 7) Driver compatibility and upgrades

\`\`\`bash
# Show current kernel + installed driver + recommended upgrade candidate
sudo ./gpu-node-bootstrap.sh --help

# Full golden-path automation (stops after driver install and asks you to reboot)
sudo ./gpu-node-bootstrap.sh --setup-all

# Install/pin a branch and hold NVIDIA packages
sudo ./gpu-node-bootstrap.sh --install-base-packages
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580

# Install/pin an exact version
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580 --nvidia-driver-version 580.173.02-1ubuntu1

# Install NVIDIA container runtime after drivers
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime

# Optional host CUDA runtime/toolkit
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
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
    --setup-all)
      SETUP_ALL_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --install-base-packages)
      INSTALL_BASE_PACKAGES_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --install-nvidia-driver)
      INSTALL_NVIDIA_DRIVER_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --install-cuda-runtime)
      INSTALL_CUDA_RUNTIME_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --install-cuda-container-runtime)
      INSTALL_CUDA_CONTAINER_RUNTIME_ONLY=1
      ACTION_SELECTED=1
      shift
      ;;
    --switch-active-cuda)
      SWITCH_ACTIVE_CUDA_HOME="$2"
      ACTION_SELECTED=1
      shift 2
      ;;
    --nvidia-driver-branch)
      NVIDIA_DRIVER_BRANCH="$2"
      shift 2
      ;;
    --nvidia-driver-version)
      NVIDIA_DRIVER_VERSION="$2"
      shift 2
      ;;
    --disable-nvidia-hold)
      DISABLE_NVIDIA_HOLD=1
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
  echo "ERROR: No action selected. Choose one of: --mode, --setup-all, --install-base-packages, --install-nvidia-driver, --install-cuda-runtime, --install-cuda-container-runtime, --switch-active-cuda, --summarize-installation" >&2
  usage
  exit 1
fi

if [[ "$SETUP_ALL_ONLY" -eq 1 ]]; then
  setup_all_action
  exit 0
fi

if [[ "$INSTALL_BASE_PACKAGES_ONLY" -eq 1 ]]; then
  install_base_packages_action
  exit 0
fi

if [[ "$INSTALL_NVIDIA_DRIVER_ONLY" -eq 1 ]]; then
  install_nvidia_driver
  exit 0
fi

if [[ "$INSTALL_CUDA_RUNTIME_ONLY" -eq 1 ]]; then
  install_cuda_runtime_action
  exit 0
fi

if [[ "$INSTALL_CUDA_CONTAINER_RUNTIME_ONLY" -eq 1 ]]; then
  install_cuda_container_runtime_action
  exit 0
fi

if [[ -n "$SWITCH_ACTIVE_CUDA_HOME" ]]; then
  switch_active_cuda "$SWITCH_ACTIVE_CUDA_HOME"
  exit 0
fi

if [[ "$SUMMARIZE_ONLY" -eq 1 ]]; then
  require_root
  summarize_installation
  exit 0
fi

case "$MODE" in
  setup-cuda-runtimes)
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
