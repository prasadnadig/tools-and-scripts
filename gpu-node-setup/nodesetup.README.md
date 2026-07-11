# Node Setup Scripts

This folder now includes two bootstrap scripts that split host-level GPU runtime setup from user-level Conda setup.

## What each script does

### gpu-node-bootstrap.sh (root only)

Purpose:
- Configure GPU host runtime components needed by local and containerized GPU workloads.

Installs/configures:
- CUDA toolkit/runtime package: `cuda-toolkit-12-8` (default, configurable)
- Docker engine + compose/buildx plugins
- NVIDIA Container Toolkit runtime integration with Docker (`nvidia-ctk runtime configure --runtime=docker`)
- Global CUDA shell exports via per-version profiles and `/etc/profile.d/cuda-active-runtime.sh`

Not installed:
- No Conda or Python environment setup
- No FFmpeg installation

Design notes:
- Uses CUDA major/minor stream from the repeatable setup script (12.8 defaults)
- Supports idempotent re-runs (checks package presence and safely rewrites config)
- Supports idempotent NVIDIA driver re-install via explicit action for repair workflows
- Supports diagnostic/check modes and runbook generation
- Supports NVIDIA driver branch/version pinning and package hold workflow for stable upgrades

Action requirement:
- You must pass an explicit action option: `--mode`, `--setup-all`, `--install-base-packages`, `--install-nvidia-driver`, `--install-cuda-runtime`, `--install-cuda-container-runtime`, `--switch-active-cuda`, or `--summarize-installation`
- Running with no options prints help only
- Fresh hosts should start with `--install-base-packages`

CLI modes/options:
- `--mode setup-cuda-runtimes|verify|runbook` (`setup-cuda-runtimes` is a convenience wrapper that runs both runtime install steps)
- `--setup-all` (runs the golden path end-to-end, stops for reboot after driver install, then resumes on rerun)
- `--install-base-packages` (mandatory first step on fresh hosts)
- `--install-nvidia-driver` (idempotent; safe to rerun)
- `--install-cuda-runtime` (install CUDA toolkit/runtime and active profile)
- `--install-cuda-container-runtime` (install NVIDIA container runtime integration)
- `--switch-active-cuda <path>` (idempotent; safe to rerun)
- `--nvidia-driver-branch <branch>` (default: `580`)
- `--nvidia-driver-version <version>` (optional exact pin, for example `580.173.02-1ubuntu1`)
- `--disable-nvidia-hold` (optional; by default NVIDIA branch packages are held after install)
- `--summarize-installation`
- `--nvidia-container-toolkit-version <version>` (default: `latest`)
- `--cuda-toolkit-apt-package <name>`
- `--cuda-home <path>`
- `--skip-docker-install`

Setup precondition:
- `--install-base-packages` must be run before driver installation
- `--install-nvidia-driver` must be run before CUDA runtime and NVIDIA container runtime setup
- `--install-cuda-container-runtime` depends on base packages + working NVIDIA drivers
- `--install-cuda-runtime` is independent of container runtime and is optional for container-first GPU nodes
- `--mode setup-cuda-runtimes` now runs the container runtime step and then the host CUDA runtime step as a convenience wrapper
- If missing, setup exits with guidance to run `--install-nvidia-driver` first and reboot

Examples:
```bash
sudo ./gpu-node-bootstrap.sh --install-base-packages
sudo ./gpu-node-bootstrap.sh --setup-all
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime

# optional host CUDA toolkit/runtime
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580 --nvidia-driver-version 580.173.02-1ubuntu1
sudo ./gpu-node-bootstrap.sh --switch-active-cuda /usr/local/cuda-12.8
sudo ./gpu-node-bootstrap.sh --mode verify
sudo ./gpu-node-bootstrap.sh --summarize-installation
sudo ./gpu-node-bootstrap.sh --nvidia-container-toolkit-version 1.17.8-1
```

Multi-version CUDA switching:
- You can keep multiple CUDA toolkit installs side-by-side.
- Use `--switch-active-cuda /usr/local/cuda-<version>` to change the active shell/runtime profile.
- The script writes per-version profiles and updates `/etc/profile.d/cuda-active-runtime.sh` symlink.
- Switching is idempotent and safe to rerun.

Container runtime vs host CUDA runtime:
- `--install-cuda-container-runtime` enables Docker/NVIDIA GPU container integration.
- It requires base packages plus a working NVIDIA driver stack.
- It does not require the host CUDA toolkit/runtime to be installed.
- `--install-cuda-runtime` installs host CUDA userspace tooling and libraries such as `nvcc` and sets the active CUDA profile.
- Many container-first GPU nodes only need the container runtime step and can defer or skip host CUDA runtime installation.

Kernel + NVIDIA compatibility and upgrade guidance:
- Run `--install-base-packages` first, then run `--help` to print dynamic host diagnostics:
	- current kernel
	- currently installed NVIDIA driver version (if available)
	- recommended NVIDIA driver package from `ubuntu-drivers`
	- current best candidate version to upgrade
	- matching kernel module package candidate availability
- Use this output to choose a branch/version that has both driver and kernel module candidates available.
- The script writes pin preferences at `/etc/apt/preferences.d/nvidia-driver-pin` and holds installed branch packages unless `--disable-nvidia-hold` is set.

How NVIDIA driver pinning works:
- The script can pin by branch or by exact package version.
- Branch pinning is enabled by `--nvidia-driver-branch <branch>`.
	- Example: `--nvidia-driver-branch 580`
	- This writes an apt preference using a version pattern like `580.*`.
	- Result: apt prefers packages from the selected branch and resists drifting to another branch.
- Exact-version pinning is enabled by also passing `--nvidia-driver-version <version>`.
	- Example: `--nvidia-driver-version 580.173.02-1ubuntu1`
	- This writes an apt preference for that exact package version.
	- Result: apt strongly prefers only that exact version for the pinned NVIDIA package set.

What the pin file does:
- The script writes `/etc/apt/preferences.d/nvidia-driver-pin`.
- That file gives a high apt pin priority to the selected NVIDIA driver package family.
- The pin covers the key driver-aligned packages used by the selected branch, including:
	- `nvidia-driver-<branch>`
	- `nvidia-kernel-common-<branch>`
	- `nvidia-utils-<branch>`
	- `libnvidia-compute-<branch>`
	- `nvidia-dkms-<branch>`
	- matching `linux-modules-nvidia-<branch>-*`
	- matching `linux-objects-nvidia-<branch>-*`
- The point is to keep the driver package family moving together, instead of allowing one NVIDIA component to advance while another stays behind.

What `apt-mark hold` adds on top of pinning:
- After a successful driver install, the script holds the installed branch packages by default.
- This protects the working driver stack from later unattended or unrelated package upgrades.
- Holding does not replace pinning.
- Pinning influences what apt prefers when resolving packages.
- Holding blocks later upgrades to already-installed key NVIDIA packages unless they are explicitly unheld.

Why both pinning and hold are used:
- Pinning helps apt choose a coherent NVIDIA package set during install or repair.
- Holding helps preserve that coherent set after the machine is working.
- Using both reduces the chance of partial upgrades creating mismatched package versions such as:
	- kernel module package from one sub-version
	- `nvidia-kernel-common` from a newer sub-version

Branch pinning vs exact-version pinning:
- Branch pinning is better when you want stability but still want controlled upgrades within the same branch.
- Exact-version pinning is better when you want reproducibility across machines or want to avoid any movement until you deliberately change the version.
- Exact-version pinning is stricter, but it also means upgrades will not happen until you intentionally update the pinned version.

How to read the help output before upgrading:
- The `--help` output shows the current kernel.
- It also shows the recommended driver package from `ubuntu-drivers`.
- It shows the apt candidate version for that package at this moment.
- It also shows whether the matching kernel module package candidate is available for the current kernel.
- A good upgrade target is one where both are true:
	- the driver package candidate exists
	- the matching kernel module candidate exists for the current kernel
- If the driver package exists but the matching kernel module candidate is missing, that is a warning sign that the repository state may be incomplete or temporarily inconsistent.

Recommended upgrade workflow:
- Inspect current state first:
	- `sudo ./gpu-node-bootstrap.sh --install-base-packages`
	- `sudo ./gpu-node-bootstrap.sh --help`
- If you want a stable branch-managed install:
	- `sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580`
- If you want an exact reproducible install:
	- `sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580 --nvidia-driver-version 580.173.02-1ubuntu1`
- Reboot after driver installation.
- Verify after reboot:
	- `sudo ./gpu-node-bootstrap.sh --mode verify`

How to intentionally upgrade later:
- Review the new candidates first with `--help`.
- If staying on the same branch, update the install command and rerun it.
- If moving to an exact new version, pass the new `--nvidia-driver-version` value explicitly.
- The script will rewrite the apt pin file to the new target.
- If package holds are active, you may need to unhold manually before a deliberate branch/version transition.
- After the new install succeeds, the script will hold the selected branch packages again unless `--disable-nvidia-hold` is used.

When `--disable-nvidia-hold` is useful:
- Use it only if you intentionally want apt to keep upgrading NVIDIA packages after installation.
- This is less stable for long-lived GPU nodes.
- It can be useful on disposable systems or short-lived experiments where strict reproducibility is less important.

### conda-node-bootstrap.sh (non-root user only)

Purpose:
- Install and configure Conda for a regular unix user with a notebook-ready base environment.

Installs/configures:
- Miniforge under `~/local/miniforge3` (default, configurable)
- Base environment Python version target: `3.12` (default, configurable)
- Base env packages: `jupyterlab`, `nb_conda_kernels`
- Conda default package policy: auto-install `ipykernel` in all newly created envs
- User shell exports for Conda and CUDA runtime paths in `~/.bashrc`

Not installed:
- No framework-specific Conda envs are created in this stage

Design notes:
- Fails fast if run as root
- Supports idempotent re-runs and safe append behavior in `~/.bashrc`
- Supports diagnostic/check modes and runbook generation

CLI modes/options:
- `--mode setup|verify|runbook` (default: `setup`)
- `--summarize-installation`
- `--miniforge-dir <path>`
- `--python-version <version>` (default: `3.12`)
- `--installer-url <url>`
- `--cuda-home <path>`

Examples:
```bash
./conda-node-bootstrap.sh --mode setup
./conda-node-bootstrap.sh --mode verify
./conda-node-bootstrap.sh --summarize-installation
./conda-node-bootstrap.sh --python-version 3.12
```

## Suggested execution order

1. Run host runtime setup as root:
```bash
sudo ./gpu-node-bootstrap.sh --install-base-packages
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime

# optional host CUDA toolkit/runtime
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime

# or use the convenience wrapper for both runtime steps
sudo ./gpu-node-bootstrap.sh --mode setup-cuda-runtimes
```

2. Run Conda setup as target user:
```bash
./conda-node-bootstrap.sh --mode setup
```

3. Run summary outputs for quick audit:
```bash
sudo ./gpu-node-bootstrap.sh --summarize-installation
./conda-node-bootstrap.sh --summarize-installation
```

## Verification suggestions

Host/runtime:
```bash
nvidia-smi
nvcc --version
docker --version
docker info --format '{{json .Runtimes}}'
docker run --rm --gpus all nvidia/cuda:12.8.1-runtime-ubuntu22.04 nvidia-smi
```

Conda/user:
```bash
conda --version
conda run -n base python --version
conda run -n base python -c "import jupyterlab, nb_conda_kernels; print(jupyterlab.__version__, nb_conda_kernels.__version__)"
conda config --show create_default_packages
```

## PATH and LD_LIBRARY_PATH defaults

Host-level script writes:
- Per-version profiles: `/etc/profile.d/cuda-<slug>-runtime.sh`
- Active profile symlink: `/etc/profile.d/cuda-active-runtime.sh`

User-level script appends to `~/.bashrc`:
- `export PATH="$HOME/local/miniforge3/bin:$PATH"`
- `export CUDA_HOME=/usr/local/cuda-12.8`
- `export PATH="$CUDA_HOME/bin:$PATH"`
- `export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/targets/x86_64-linux/lib:$LD_LIBRARY_PATH"`
