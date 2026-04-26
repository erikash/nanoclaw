---
name: add-whisper
description: Add offline voice-message transcription to NanoClaw. Builds whisper.cpp on the host, downloads a Whisper model, and wires automatic transcription into the WhatsApp adapter so voice notes arrive at the agent as text. Fully offline — no external API. Use when the user wants the assistant to read voice messages.
---

# /add-whisper — Voice transcription

Adds offline voice-message transcription. Voice notes arriving on a channel that supports it (WhatsApp today) are auto-transcribed on the host before the message is routed to any agent. The agent sees:

```
[audio: voicenote-1234.ogg — saved to /workspace/attachments/voicenote-1234.ogg, transcript: "buy bread on the way home"]
```

No agent action, no MCP tool, no extra latency for non-audio messages. Works for every group — no per-group config needed.

## Architecture

```
WhatsApp adapter (host)
  ↓ downloads voice note → data/attachments/voicenote.ogg
  ↓ transcribeAudio(path)  ──→  ffmpeg → 16kHz WAV
  ↓                              ↓
  ↓                              whisper-cli (host CPU)
  ↓ ←── transcript text ─────────┘
  ↓ message written to inbound.db with attachment.transcript field
container agent-runner formatter renders [..., transcript: "..."]
```

The host code (`src/transcribe.ts`, hooks in `src/channels/whatsapp.ts` and `container/agent-runner/src/formatter.ts`) is committed to the codebase and **gated by env vars** — without `NANOCLAW_WHISPER_BIN` and `NANOCLAW_WHISPER_MODEL` set, transcription is a silent no-op. This skill does the host-side ops (binary + model + env) to turn it on.

## Phase 1: Pre-flight

Check whether transcription is already configured:

```bash
grep -q '^NANOCLAW_WHISPER_BIN=' .env && grep -q '^NANOCLAW_WHISPER_MODEL=' .env && \
  test -x "$(grep '^NANOCLAW_WHISPER_BIN=' .env | cut -d= -f2- | tr -d '"')" && \
  test -f "$(grep '^NANOCLAW_WHISPER_MODEL=' .env | cut -d= -f2- | tr -d '"')" && \
  echo INSTALLED || echo NOT_INSTALLED
```

If `INSTALLED` and the user just wants a model swap, jump to **Phase 4 (Model)** with a different `WHISPER_MODEL_NAME`. Otherwise continue.

Check ffmpeg is available:

```bash
command -v ffmpeg >/dev/null && echo OK || echo MISSING
```

If `MISSING`, ask the user to run:

```bash
sudo apt-get update && sudo apt-get install -y ffmpeg
```

…and re-invoke the skill. Do not try to `sudo` automatically.

## Phase 2: Build whisper.cpp

Clone, build, install. Pinned to a known-good tag for reproducibility — bump deliberately.

```bash
WHISPER_TAG="v1.7.6"
WHISPER_SRC="$HOME/.cache/nanoclaw/whisper.cpp"
WHISPER_BIN_DIR="$HOME/.local/bin"

mkdir -p "$WHISPER_BIN_DIR" "$(dirname "$WHISPER_SRC")"
if [ ! -d "$WHISPER_SRC" ]; then
  git clone --depth=1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WHISPER_SRC"
else
  git -C "$WHISPER_SRC" fetch --depth=1 origin "$WHISPER_TAG":refs/tags/"$WHISPER_TAG" 2>/dev/null || true
  git -C "$WHISPER_SRC" checkout -q "$WHISPER_TAG"
fi

cmake -S "$WHISPER_SRC" -B "$WHISPER_SRC/build" -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_EXAMPLES=ON >/dev/null
cmake --build "$WHISPER_SRC/build" --config Release -j --target whisper-cli >/dev/null
install -m 0755 "$WHISPER_SRC/build/bin/whisper-cli" "$WHISPER_BIN_DIR/whisper-cli"
"$WHISPER_BIN_DIR/whisper-cli" --help >/dev/null
```

If `cmake` is missing, ask the user to install build tools (`sudo apt-get install -y build-essential cmake`) and retry.

## Phase 3: Choose model

Default: **`ggml-small-q5_1.bin`** (~190MB, multilingual, ~real-time on a low-power CPU like Intel N150 for short voice notes). Override by setting `WHISPER_MODEL_NAME` before invoking.

| Model | Size | Quality | N150 speed |
|---|---|---|---|
| `ggml-tiny-q5_1.bin` | ~30MB | English ok, other langs poor | Very fast |
| `ggml-base-q5_1.bin` | ~60MB | Decent for clear English | Fast |
| **`ggml-small-q5_1.bin`** | ~190MB | Good multilingual incl. Hebrew | ~real-time |
| `ggml-medium-q5_0.bin` | ~540MB | Strong multilingual | ~3–5× slower than realtime |

Avoid `large-*` on the N150 — too slow.

## Phase 4: Download the model

```bash
MODEL_NAME="${WHISPER_MODEL_NAME:-ggml-small-q5_1.bin}"
MODEL_DIR="$HOME/.local/share/nanoclaw/whisper-models"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

mkdir -p "$MODEL_DIR"
if [ ! -s "$MODEL_PATH" ]; then
  curl --fail --location --show-error --silent \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME" \
    -o "$MODEL_PATH.tmp"
  mv "$MODEL_PATH.tmp" "$MODEL_PATH"
fi
```

## Phase 5: Wire into .env

Add the env vars if not already present. Idempotent — replaces existing lines on re-run.

```bash
WHISPER_BIN="$HOME/.local/bin/whisper-cli"

# Remove any prior entries
sed -i.bak -E '/^(NANOCLAW_WHISPER_BIN|NANOCLAW_WHISPER_MODEL|NANOCLAW_WHISPER_LANG)=/d' .env && rm -f .env.bak

cat >> .env <<EOF
NANOCLAW_WHISPER_BIN=$WHISPER_BIN
NANOCLAW_WHISPER_MODEL=$MODEL_PATH
NANOCLAW_WHISPER_LANG=auto
EOF
```

`NANOCLAW_WHISPER_LANG=auto` lets whisper detect language per clip. Override with a specific code (`he`, `en`) if auto-detect mis-fires.

## Phase 6: Restart and verify

```bash
# Use the installed unit name, not a hardcoded one
UNIT=$(systemctl --user list-units --all --no-legend 'nanoclaw-v2-*.service' | awk 'NR==1{print $1}')
test -n "$UNIT" && systemctl --user restart "$UNIT"
sleep 3
systemctl --user is-active "$UNIT"
```

Verify with a tiny synthetic clip:

```bash
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=1000:duration=1" -ar 16000 /tmp/whisper-smoke.wav
"$WHISPER_BIN" -m "$MODEL_PATH" -l auto -nt --no-prints -f /tmp/whisper-smoke.wav
rm -f /tmp/whisper-smoke.wav
```

That should print empty (it's a sine tone) but exit 0. End-to-end test: send a voice note from WhatsApp and check logs:

```bash
tail -f logs/nanoclaw.log | grep -i transcrib
```

You should see `Audio transcribed { path: ..., durationMs: ..., chars: ... }` within seconds of the voice note arriving.

## Reinstall / upgrade

Re-running the skill is safe:
- whisper.cpp build: skipped if the tag is already checked out and binary exists
- model download: skipped if the file is non-empty
- .env: prior entries replaced
- service: restarted

To upgrade whisper.cpp, bump `WHISPER_TAG` and re-run. To swap models, set `WHISPER_MODEL_NAME` and re-run.

## Uninstall

```bash
sed -i.bak -E '/^(NANOCLAW_WHISPER_BIN|NANOCLAW_WHISPER_MODEL|NANOCLAW_WHISPER_LANG)=/d' .env && rm -f .env.bak
rm -f "$HOME/.local/bin/whisper-cli"
rm -rf "$HOME/.local/share/nanoclaw/whisper-models"
rm -rf "$HOME/.cache/nanoclaw/whisper.cpp"
# Restart the service
```

The committed code stays — without the env vars, `transcribeAudio` short-circuits and behavior reverts to the pre-skill state.
