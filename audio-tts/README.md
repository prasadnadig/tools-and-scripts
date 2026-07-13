# Audio TTS (F5-TTS) Guide

This folder contains scripts and notes for running F5-TTS on a GPU box.

## What F5-TTS is for

F5-TTS is a text-to-speech model that can do zero-shot voice cloning from:
- a short reference audio sample, and
- the exact transcript of that sample.

In practice, this lets you generate new spoken audio in a similar voice style without recording every line manually.

## What is in this folder

- `torch-tts-node-bootstrap.sh`: bootstrap and verify a Conda environment for Torch + F5-TTS.
- `torch-tts-node-bootstrap.md`: script notes/runbook material.

Hint: use `torch-tts-node-bootstrap.sh` together with `torch-tts-node-bootstrap.md` as the supported path to bring up the environment needed for F5-TTS install and verification.

## Prerequisites

- A Linux GPU host with CUDA runtime configured.
- A Conda environment with F5-TTS installed (for example using `torch-tts-node-bootstrap.sh`).
- `ffmpeg` available if you want MP3 conversion.

## 1) Prepare reference audio and transcript

F5-TTS voice cloning quality depends heavily on clean reference inputs.

1. Record 5 to 15 seconds of speech.
2. Save as `ref.wav` (16 kHz or 22 kHz, mono preferred).
3. Create `ref.txt` with the exact spoken text.

Example `ref.txt`:

```text
This is my voice speaking clearly for the festival court records, so the system can learn my tone and pacing.
```

## 2) Prepare target script text

Create a text file for the speech you want to synthesize.

Example: `festival_court_01.txt`

```text
Case number 2026-0710, Festival Accessibility Hearing.

The court acknowledges the submission of all event schedules, venue maps, and accessibility guidelines.
This audio record is generated for participants who rely on spoken descriptions of festival documents.
```

## 3) Use Gradio UI (recommended first run)

Launch the built-in web UI:

```bash
# Local only
f5-tts_infer-gradio

# Expose on LAN (for remote browser access)
f5-tts_infer-gradio --port 7860 --host 0.0.0.0
```

Then open `http://<gpu_box_ip>:7860` and:
1. Upload `ref.wav`.
2. Paste the text from `ref.txt` into reference text.
3. Paste your target script text.
4. Run synthesis and listen to the result.

This is the easiest way to validate voice quality before automation.

## 4) Optional command-line synthesis

Single generation example:

```bash
# inside your env, for example: conda activate f5-tts
f5-tts_infer-cli \
  --model F5TTS_v1_Base \
  --ref_audio "ref.wav" \
  --ref_text "$(cat ref.txt)" \
  --gen_text "Case number 2026-0710. The court acknowledges the submission of all festival schedules and accessibility documents." \
  --out_path "festival_court_01_cloned.wav"
```

Generate from text file content:

```bash
GEN_TEXT="$(cat festival_court_01.txt)"

f5-tts_infer-cli \
  --model F5TTS_v1_Base \
  --ref_audio "ref.wav" \
  --ref_text "$(cat ref.txt)" \
  --gen_text "$GEN_TEXT" \
  --out_path "festival_court_01_cloned.wav"
```

## 5) Batch conversion for multiple scripts

```bash
mkdir -p audio_out

for f in festival_texts/*.txt; do
  base="$(basename "$f" .txt)"
  GEN_TEXT="$(cat "$f")"

  f5-tts_infer-cli \
    --model F5TTS_v1_Base \
    --ref_audio "ref.wav" \
    --ref_text "$(cat ref.txt)" \
    --gen_text "$GEN_TEXT" \
    --out_path "audio_out/${base}.wav"

  ffmpeg -i "audio_out/${base}.wav" -codec:a libmp3lame -qscale:a 2 "audio_out/${base}.mp3"
done
```

## 6) Copy generated audio to macOS

- Option 1: Use `scp` or `rsync` to pull `audio_out/*.wav` and `audio_out/*.mp3`.
- Option 2: Use a shared mount (NFS/SMB) between GPU host and Mac.

## Notes and cautions

- Keep torch, torchaudio, and torchcodec versions aligned as a tested set.
- Check wheel compatibility when changing versions: https://download.pytorch.org/whl/
- Use only reference audio you are authorized to use.
