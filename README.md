# asana-whisperer

Paste an Asana ticket URL, discuss it in your meeting, press Enter — the conversation gets summarized and written back to the ticket automatically.

Two modes:

- **Requirements** (default) — extracts concrete requirements and prepends them to the ticket description
- **Discovery** (`--discover`) — surfaces open questions, context, and next steps, then posts the result as a comment on the ticket

## How it works

1. Run the tool with an Asana task URL (and optionally `--discover`)
2. It records your microphone and system audio (Google Meet participants) as two separate streams
3. Press **Enter** or **Ctrl+C** to stop
4. Both streams are transcribed via OpenAI Whisper (`gpt-4o-mini-transcribe`)
5. Claude analyzes the discussion using the prompt for the active mode
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

Edit `.env` and fill in all three keys:

| Variable | Where to get it |
|---|---|
| `OPENAI_API_KEY` | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `ANTHROPIC_API_KEY` | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| `ASANA_ACCESS_TOKEN` | app.asana.com/0/my-apps → Personal Access Tokens |

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

## Usage

```bash
# Requirements mode (default) — extracts requirements, prepends to ticket description
aw https://app.asana.com/0/PROJECT_ID/TASK_ID

# Discovery mode — surfaces open questions and next steps, posts as a ticket comment
aw --discover https://app.asana.com/0/PROJECT_ID/TASK_ID
```

Paste the URL of the ticket you're about to discuss, start the meeting, then press **Enter** or **Ctrl+C** when the discussion is done.

---

## What you'll see

```
Fetching ticket... done

  Ticket : Add OAuth login support
  Project: Engineering Backlog
  Mode   : Requirements

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

60-minute meeting:
- Transcription: ~$0.36 (120 min audio × $0.003/min)
- Summarization: ~$0.10–$0.15 (Claude Sonnet)
- **Total: under $0.55 per meeting**
