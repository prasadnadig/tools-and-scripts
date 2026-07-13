# Torch + TTS Node Bootstrap Guide

This guide describes how to use `torch-tts-node-bootstrap.sh` to set up and verify a repeatable Torch + TTS environment on a Linux GPU box.

The script is intentionally explicit about CUDA runtime ownership and avoids hidden assumptions that can cause dynamic library (`.so`) loading issues.

## What This Script Does

- Uses explicit action flags instead of mode values:
  - `--install`
  - `--verify`
  - `--runbook`
  - `--installation-summary`
- Requires `--env-name` for all operational actions.
- Creates the conda env only when `--create-conda-env` is provided.
- Requires `CUDA_HOME` to be set for operational actions.
- Ensures CUDA runtime paths are present in `PATH` and `LD_LIBRARY_PATH` for the current process.
- Installs:
  - `ffmpeg` from conda-forge
  - torch family from `cu128` index as pinned group
  - `f5-tts==1.1.21` via pip (default pin)
- Generates runbook and installation-summary docs when requested.

## Why This Design

This approach is based on previous failures caused by mixed runtime libraries and mismatched torch-family versions.

Key lessons applied:
- Keep `torch`, `torchaudio`, and `torchcodec` aligned as a tested group.
- Treat `CUDA_HOME` as an explicit runtime contract.
- Make path assumptions visible and logged.
- Avoid silently installing or changing CUDA toolkit in bootstrap logic.

## Prerequisites

- Linux GPU box with NVIDIA driver installed.
- Conda installed and available in `PATH`.
- `CUDA_HOME` exported to intended toolkit root.

Example:

```bash
export CUDA_HOME=/usr/local/cuda-12.8
```

## Script Location

- `torch-tts-node-bootstrap.sh`

## Help (Default if no args)

```bash
./torch-tts-node-bootstrap.sh --help
```

## Common Workflows

### 1) Fresh install (create env + install stack)

```bash
./torch-tts-node-bootstrap.sh \
  --install \
  --env-name f5-tts \
  --create-conda-env
```

Optional override for F5-TTS version:

```bash
./torch-tts-node-bootstrap.sh \
  --install \
  --env-name f5-tts \
  --create-conda-env \
  --f5-tts-version 1.1.21
```

### 2) Install into existing env

```bash
./torch-tts-node-bootstrap.sh \
  --install \
  --env-name f5-tts
```

### 3) Verify environment

```bash
./torch-tts-node-bootstrap.sh \
  --verify \
  --env-name f5-tts
```

### 4) Generate runbook doc

```bash
./torch-tts-node-bootstrap.sh --runbook
```

Custom output:

```bash
./torch-tts-node-bootstrap.sh \
  --runbook \
  --runbook-out ./my-runbook.md
```

### 5) Generate installation summary doc

```bash
./torch-tts-node-bootstrap.sh \
  --installation-summary \
  --env-name f5-tts
```

Custom output:

```bash
./torch-tts-node-bootstrap.sh \
  --installation-summary \
  --env-name f5-tts \
  --summary-out ./my-install-summary.md
```

## Version Strategy Used by Script

The script writes a temporary requirements file with the torch-family group pinned at top:

```text
torch==2.9.1+cu128
torchaudio==2.9.1+cu128
torchcodec==0.9.1+cu128
```

Then installs with:

```bash
pip install -r <temp-file> --index-url https://download.pytorch.org/whl/cu128
```

Rationale:
- These packages are version-sensitive with each other.
- Pinning as a group reduces runtime ABI mismatch risk.
- Wheel index and version compatibility must be cross-checked before upgrades.

F5-TTS pin:

```text
f5-tts==1.1.21
```

The script installs this pin by default and allows override with `--f5-tts-version`.

Reference:
- https://download.pytorch.org/whl/

## Runtime Path Handling

For operational actions, script ensures these are present:

- `PATH`: `$CUDA_HOME/bin`
- `LD_LIBRARY_PATH`:
  - `$CUDA_HOME/lib64`
  - `$CUDA_HOME/targets/x86_64-linux/lib`

It logs whether paths were already present or added.

## Important Operational Warning

At install/verify time, script prints a runtime notice:
- It assumes your selected `CUDA_HOME` toolkit should drive runtime loading.
- If that is not your intent, change `CUDA_HOME` first.
- `.so` issues can appear if toolkit/runtime and torch-family versions are mismatched.

## What to Do Before Upgrading torch* Modules

If changing `torch`, `torchaudio`, or `torchcodec`:
1. Pick versions as a compatible group.
2. Confirm wheel availability on the chosen index.
3. Re-run verify action.
4. Regenerate installation summary if needed.

Do not upgrade one torch-family package in isolation unless you have tested compatibility.

## Troubleshooting Quick Notes

- Missing `--env-name` for install/verify/summary will error by design.
- If env does not exist, provide `--create-conda-env`.
- If `CUDA_HOME` is unset or invalid, script stops early.
- If runtime issues persist, verify your selected CUDA toolkit and torch-family compatibility against wheel index.

## Related Files

- `external-gpu-box-f5-tts-cuda-voice-cloning.md`
- `system-setup-repeatable.sh`
