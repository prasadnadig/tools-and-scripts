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
- Global CUDA shell exports via `/etc/profile.d/cuda-12-8-runtime.sh`

Not installed:
- No Conda or Python environment setup
- No FFmpeg installation

Design notes:
- Uses CUDA major/minor stream from the repeatable setup script (12.8 defaults)
- Supports idempotent re-runs (checks package presence and safely rewrites config)
- Supports idempotent NVIDIA driver re-install via explicit action for repair workflows
- Supports diagnostic/check modes and runbook generation

Action requirement:
- You must pass an explicit action option: `--mode`, `--install-nvidia-driver`, `--switch-active-cuda`, or `--summarize-installation`
- Running with no options prints help only

CLI modes/options:
- `--mode setup|verify|runbook`
- `--install-nvidia-driver` (idempotent; safe to rerun)
- `--switch-active-cuda <path>` (idempotent; safe to rerun)
- `--summarize-installation`
- `--nvidia-container-toolkit-version <version>` (default: `latest`)
- `--cuda-toolkit-apt-package <name>`
- `--cuda-home <path>`
- `--skip-docker-install`

Setup precondition:
- `--mode setup` now checks host NVIDIA driver readiness (`nvidia-smi` and `libnvidia-ml.so.1`)
- If missing, setup exits with guidance to run `--install-nvidia-driver` first and reboot

Examples:
```bash
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --mode setup
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
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
sudo reboot

# after reboot
sudo ./gpu-node-bootstrap.sh --mode setup
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
