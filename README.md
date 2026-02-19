# asana-whisperer

Paste an Asana ticket URL, discuss it in your meeting, press Enter — the conversation gets summarized and written back to the ticket automatically.

Two modes:

- **Requirements** (default) — extracts concrete requirements and prepends them to the ticket description
- **Discovery** (`--discover`) — surfaces open questions, context, and next steps, then posts the result as a comment on the ticket

## Quick start — cloud

Requires `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `ASANA_ACCESS_TOKEN` in `.env`.

```bash
aw https://app.asana.com/0/PROJECT_ID/TASK_ID
```

## Quick start — local models

Requires [initial setup](#local-models-optional). Once done, start the services and pass `--local`:

```bash
# Terminal 1 — Whisper transcription
source ~/faster-whisper-env/bin/activate && faster-whisper-server --config ~/whisper-config.yaml

# Terminal 2 — Ollama LLM (if not already running)
ollama serve

# Terminal 3 — Run the tool
aw --local https://app.asana.com/0/PROJECT_ID/TASK_ID
```

---

## How it works

1. Run the tool with an Asana task URL (and optionally `--discover`)
2. It records your microphone and system audio (Google Meet participants) as two separate streams
3. Press **Enter** or **Ctrl+C** to stop
4. Both streams are transcribed via OpenAI Whisper (`gpt-4o-mini-transcribe`) or a local Whisper server
5. An LLM (Claude by default, or a local model via Ollama) analyzes the discussion using the prompt for the active mode
6. The summary is written back to the Asana ticket (prepended to the description in Requirements mode, posted as a comment in Discovery mode)

---

## Setup

### 1. Install system dependencies

```bash
sudo apt-get install -y ffmpeg pulseaudio-utils
```

Verify both audio streams are available:

```bash
pactl list sources short
```

You should see two sources — one for your mic (`RDPSource`) and one for system audio (`RDPSink.monitor`). Both will be `SUSPENDED` until recording starts; that's normal.

**How WSL2 audio works:** WSLg (the GUI layer included with WSL2) bridges Windows audio into the Linux environment via an RDP audio channel. `RDPSink` represents your Windows audio output, and `RDPSink.monitor` is a loopback of everything playing on Windows — meaning any audio from Google Meet, a browser, or any other Windows app will be captured automatically. You don't need a virtual audio cable.

If you don't see `RDPSink.monitor`, run `wsl --update` in a Windows terminal and restart WSL. WSLg requires WSL version 2.0+, which ships with Windows 11 and is available on Windows 10 via Windows Update.

### 2. Add user gem bin to your PATH

The system Ruby gem directory isn't user-writable, so gems install to your home directory. Add this to your `~/.zshrc` (or `~/.bashrc`):

```bash
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
```

Then reload: `source ~/.zshrc`

### 3. Install Bundler and project gems

```bash
cd ~/Projects/asana-whisperer
gem install bundler --user-install
bundle install
```

### 4. Configure API keys

```bash
cp .env.example .env
```

Edit `.env` and fill in the keys you need:

| Variable | Required | Where to get it |
|---|---|---|
| `OPENAI_API_KEY` | Cloud mode (default) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `ANTHROPIC_API_KEY` | Cloud mode (default) | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| `ASANA_ACCESS_TOKEN` | Always | app.asana.com/0/my-apps → Personal Access Tokens |

When using `--local`, neither cloud key is required. See [Local models](#local-models-optional) below.

### 5. Make it available as `aw` from anywhere

```bash
mkdir -p ~/.local/bin
ln -s ~/Projects/asana-whisperer/aw ~/.local/bin/aw
```

Make sure `~/.local/bin` is in your PATH (add to `~/.zshrc` if not):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

---

## Local models (optional)

Both the transcription and summarization steps can run locally instead of hitting the cloud APIs. Benefits: faster round-trips (no network), no per-request cost, offline operation, and privacy.

Each service is configured independently — you can run one locally and keep the other on the cloud.

### LLM summarization via Ollama

[Ollama](https://ollama.com) runs LLMs locally and exposes an OpenAI-compatible API.

```bash
# Install Ollama (Linux / WSL2)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model — llama3.2 is a good starting point (~2 GB)
ollama pull llama3.2

# Ollama starts automatically; verify it's running
curl http://localhost:11434/api/tags
```

Add to `.env`:

```
LLM_API_URL=http://localhost:11434/v1/chat/completions
LLM_PROVIDER=openai
LLM_MODEL=llama3.2
```

**Model recommendations:**

| Model | Size | Notes |
|---|---|---|
| `llama3.2` | ~2 GB | Good default, fast |
| `qwen2.5:7b` | ~4.7 GB | High quality structured output |
| `mistral` | ~4.1 GB | Good balance of speed and quality |

### Transcription via faster-whisper-server

[faster-whisper-server](https://github.com/fedirz/faster-whisper-server) runs Whisper locally with an OpenAI-compatible API (same `/v1/audio/transcriptions` endpoint).

**1. Install uv and Python 3.12** (faster-whisper-server requires Python 3.11+):

```bash
# Install uv (fast Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc  # or restart your terminal

# Install Python 3.12 via uv
uv python install 3.12
```

**2. Create a virtual environment and install:**

```bash
uv venv --python 3.12 ~/faster-whisper-env
source ~/faster-whisper-env/bin/activate
uv pip install faster-whisper-server
```

**3. Fix a packaging bug** (the package is missing a required file):

```bash
cat > ~/faster-whisper-env/lib/python3.12/site-packages/pyproject.toml << 'EOF'
[project]
name = "faster-whisper-server"
version = "0.0.2"
EOF
```

**4. Create a config file** (optional but recommended for CPU optimization):

```bash
cat > ~/whisper-config.yaml << 'EOF'
models:
  - name: default
    path: Systran/faster-whisper-base
    batch_size: 1
    model_options:
      device: cpu
      cpu_threads: 12      # adjust to your CPU core count (use `nproc`)
      compute_type: int8   # faster CPU inference
    transcribe_options: {}
    translate_options: {}
EOF
```

**5. Start the server:**

```bash
source ~/faster-whisper-env/bin/activate

# With config (recommended for CPU)
faster-whisper-server --config ~/whisper-config.yaml

# Or without config (simpler, auto-downloads model)
faster-whisper-server Systran/faster-whisper-base
```

The first run downloads the model (~150 MB for base, ~3 GB for large-v3).

**6. Add to `.env`:**

```
WHISPER_API_URL=http://localhost:8000/v1/audio/transcriptions
WHISPER_MODEL=default   # must match the 'name' field in config, or use full model path if no config
```

**Model recommendations:**

| Model | Accuracy | Speed | Notes |
|---|---|---|---|
| `Systran/faster-whisper-base` | Low | Very fast | Good for clear audio (~150 MB) |
| `Systran/faster-whisper-medium` | Medium | Fast | Decent quality |
| `Systran/faster-whisper-large-v3` | High | Slower | Best accuracy (~3 GB) |

> **GPU acceleration:** faster-whisper auto-detects CUDA (NVIDIA only). For WSL2, ensure your Windows NVIDIA driver is version 470.76+, then run `wsl --shutdown` from PowerShell and restart WSL. Verify with `nvidia-smi`. AMD GPUs are not supported.

### Running fully local

To run the entire pipeline without any cloud API keys:

**1. Start the services** (two terminal tabs, or add to a startup script):

```bash
# Terminal 1 — Ollama (LLM)
ollama serve   # or it may already be running as a systemd service

# Terminal 2 — faster-whisper-server (transcription)
source ~/faster-whisper-env/bin/activate
faster-whisper-server --config ~/whisper-config.yaml
```

**2. Set `.env`:**

```
# Asana (still required)
ASANA_ACCESS_TOKEN=...

# Local transcription
WHISPER_API_URL=http://localhost:8000/v1/audio/transcriptions
WHISPER_MODEL=default

# Local LLM
LLM_API_URL=http://localhost:11434/v1/chat/completions
LLM_PROVIDER=openai
LLM_MODEL=llama3.2
```

**3. Run with `--local`:**

```bash
aw --local https://app.asana.com/0/PROJECT_ID/TASK_ID
aw --local --discover https://app.asana.com/0/PROJECT_ID/TASK_ID
```

`OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are not required in this mode.

---

## Usage

```bash
# Cloud mode (default) — uses OpenAI Whisper + Claude
aw https://app.asana.com/0/PROJECT_ID/TASK_ID

# Local mode — uses faster-whisper-server + Ollama (no cloud API keys needed)
aw --local https://app.asana.com/0/PROJECT_ID/TASK_ID

# Discovery mode (works with either)
aw --discover https://app.asana.com/0/PROJECT_ID/TASK_ID
aw --local --discover https://app.asana.com/0/PROJECT_ID/TASK_ID
```

Paste the URL of the ticket you're about to discuss, start the meeting, then press **Enter** or **Ctrl+C** when the discussion is done.

---

## What you'll see

```
Fetching ticket... done

  Ticket : Add OAuth login support
  Project: Engineering Backlog
  Mode   : Requirements
  Backend: cloud

Detecting audio sources... done
  Microphone : RDPSource
  System audio: RDPSink.monitor

Recording — press Enter or Ctrl+C to stop.

  ● 04:12  mic: 0.8 MB | monitor: 0.7 MB

Stopping recording... done
  Duration: 04:12
  Mic file: 0.8 MB
  System file: 0.7 MB

Transcribing your audio... done
Transcribing meeting audio... done

Summarizing with Claude... done

────────────────────────────────────────────────────────────
## Requirements
- OAuth login must support Google and GitHub providers
- Token refresh must happen silently in the background
- Logout must revoke the token server-side

## Key Context & Background
- Decided to defer Apple Sign-In to a follow-up ticket
- Must reuse the existing session cookie infrastructure

## Open Questions
- None
────────────────────────────────────────────────────────────

Updating Asana ticket... done

Updated: https://app.asana.com/0/123/456
```

---

## Cost estimate

Cloud APIs, 60-minute meeting:
- Transcription: ~$0.36 (120 min audio × $0.003/min)
- Summarization: ~$0.10–$0.15 (Claude Sonnet)
- **Total: under $0.55 per meeting**

With local models (Ollama + faster-whisper-server): **$0.00 per meeting**
