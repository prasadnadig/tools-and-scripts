# Golden Path Install Guide

This guide is the recommended command sequence for bringing up a brand-new Ubuntu GPU node using the current bootstrap scripts in this folder.

## Goal

Use the lowest-risk order of operations so that:
- NVIDIA drivers are installed before CUDA runtime/container wiring
- required reboot happens at the correct boundary
- driver health is verified before continuing
- container runtime setup happens only after the driver stack is healthy
- host CUDA runtime remains optional and can be installed separately when needed
- user-level Conda setup happens only after host GPU runtime setup is complete

## Golden Path

You have two equivalent ways to execute the flow:
- explicit step-by-step actions
- the resumable `--setup-all` action

### 1. Inspect current compatibility state first

First install the Ubuntu-side prerequisite packages:

```bash
sudo ./gpu-node-bootstrap.sh --install-base-packages
```

Then inspect the current compatibility state:

Run:

```bash
sudo ./gpu-node-bootstrap.sh --help
```

Check the output for:
- current kernel
- recommended NVIDIA driver package (maps to `--nvidia-driver-branch`)
- candidate driver version (maps to `--nvidia-driver-version`)
- matching kernel-module candidate availability

What you want:
- a driver package candidate exists
- a matching kernel module candidate exists for the current kernel

If both are present, the node is in a good state to proceed.

### 2. Install the NVIDIA driver stack first

Run:

```bash
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
```

With current script defaults, this means:
- driver branch `580`
- apt pin preferences are written for that branch
- installed NVIDIA branch packages are held after install

Alternative:

```bash
sudo ./gpu-node-bootstrap.sh --setup-all
```

Behavior of `--setup-all`:
- runs base packages step
- runs driver install step
- stops and asks for reboot
- after reboot, rerun `--setup-all`
- resumes with container runtime, optional host CUDA runtime, and verification
- stops at the first failing step and tells you what to rerun

### 3. Reboot immediately

Run:

```bash
sudo reboot
```

Do not continue with CUDA toolkit/runtime or Docker GPU runtime setup before this reboot.

### 4. Verify the driver stack after reboot

Run:

```bash
sudo ./gpu-node-bootstrap.sh --mode verify
```

What you want to see:
- `nvidia-smi` works
- `libnvidia-ml.so.1` is visible
- no clear NVIDIA driver readiness warnings

If this step is not clean, stop and fix the driver state before doing toolkit/runtime setup.

### 5. Install NVIDIA container runtime integration

Run:

```bash
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
```

This step configures:
- NVIDIA container toolkit
- Docker GPU runtime integration
- Docker default runtime set to `nvidia`

### 6. Optionally install host CUDA runtime/toolkit

Run:

```bash
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
```

This step configures:
- CUDA toolkit/runtime package
- active CUDA shell/runtime profile

### 7. Verify the full host/runtime/container setup

Run:

```bash
sudo ./gpu-node-bootstrap.sh --mode verify
```

What you want to see:
- `nvidia-smi` works
- CUDA runtime libraries are visible
- Docker runtime is present
- Docker default runtime is `nvidia`
- NVIDIA container runtime is configured
- Docker GPU smoke test works

### 8. Print a final audit summary

Run:

```bash
sudo ./gpu-node-bootstrap.sh --summarize-installation
```

Use this to capture:
- installed package versions
- detected runtime/tool versions
- active CUDA profile
- held NVIDIA packages
- current upgrade guidance

### 9. Install user-level Conda tooling as the target unix user

Run:

```bash
./conda-node-bootstrap.sh --mode setup
```

This should be done only after host GPU runtime setup is healthy.

### 10. Verify the user-level Conda and notebook tooling

Run:

```bash
./conda-node-bootstrap.sh --mode verify
```

## Conservative Variation: Exact Driver Version Pinning

If you want maximum reproducibility across fresh nodes, use an exact NVIDIA driver version after checking `--help`.

Example:

```bash
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver --nvidia-driver-branch 580 --nvidia-driver-version <exact-version-from-help>
sudo reboot
sudo ./gpu-node-bootstrap.sh --mode verify
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
sudo ./gpu-node-bootstrap.sh --mode verify
```

Why this is safer:
- avoids accidental drift within the driver branch
- improves reproducibility across machines
- reduces the chance of partial repo state causing unexpected sub-version mismatches

## Operational Rule

For fresh GPU nodes, use this order:
- base packages install
- driver install
- reboot
- driver verify
- CUDA container runtime install
- optional host CUDA runtime install
- runtime verify
- user-level Conda setup

That sequence gives the lowest chance of landing in a mixed or partially configured GPU state.

## Quick Copy/Paste Sequence

```bash
sudo ./gpu-node-bootstrap.sh --install-base-packages
sudo ./gpu-node-bootstrap.sh --help
sudo ./gpu-node-bootstrap.sh --install-nvidia-driver
sudo reboot

# after reconnecting
sudo ./gpu-node-bootstrap.sh --mode verify
sudo ./gpu-node-bootstrap.sh --install-cuda-container-runtime
sudo ./gpu-node-bootstrap.sh --install-cuda-runtime
sudo ./gpu-node-bootstrap.sh --mode verify
sudo ./gpu-node-bootstrap.sh --summarize-installation
./conda-node-bootstrap.sh --mode setup
./conda-node-bootstrap.sh --mode verify
```

## setup-all Variant

```bash
sudo ./gpu-node-bootstrap.sh --setup-all
sudo reboot

# after reconnecting
sudo ./gpu-node-bootstrap.sh --setup-all
./conda-node-bootstrap.sh --mode setup
./conda-node-bootstrap.sh --mode verify
```
