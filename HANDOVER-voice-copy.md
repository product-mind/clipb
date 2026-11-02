# ClipB handover: "copy your voice" (hold Cmd+C to dictate)

Scratch note, not committed. Idea handed over from the voxtype session on 2026-10-20.
See `~/.dotfiles/voxtype/handover.md` for the wider EN+CZ dictation context.
The other handover in this repo, `HANDOVER.md` (link router), is separate active
work — do not merge or confuse the two.

## Goal

Hold Cmd+C with nothing selected → record voice → transcript lands on the
clipboard. Cmd+V pastes your voice. Tap Cmd+C = normal copy, always.

## Why ClipB is the host

Everything the feature needs is already here:

- `ClipboardWatcher.swift` polls `NSPasteboard.changeCount`, including a
  "wait until changeCount moves past X or deadline" helper (line 31) —
  exactly the selection detector.
- `Paste.swift` posts synthetic keystrokes via CGEvent.
- The app already holds Accessibility permission.
- It is a menu bar app, so a recording indicator fits naturally.

## Design: passive observation, no interception

We never swallow or delay Cmd+C. That is what makes this safe: if ClipB
hangs or dies, copy keeps working. (The Hammerspoon-bind-Cmd+C variant was
rejected for exactly that risk.)

State machine:

1. Observe Cmd+C key-down (`NSEvent.addGlobalMonitorForEvents`, keyDown +
   keyUp; ignore `isARepeat`).
2. Poll `changeCount` for ~200–300 ms (tune; Electron apps write slowly).
3. Changed → it was a real copy. Ignore everything until key-up.
4. Unchanged and key still held → start recording (sound cue).
5. Key-up → stop, transcribe, write transcript to the pasteboard.
   ClipB's own history picks it up as a normal entry.
6. Tap with no selection (released before the threshold) → no-op.
   This kills the stray-text-on-accidental-tap problem for free.

Three outcomes: copy (selection), voice-copy (hold, no selection), no-op
(tap, no selection).

Decided defaults (from the chat, Engineer-approved):

- Hold-to-talk, not toggle. Esc cancels a recording (discard).
- Output goes to the clipboard only. No auto-typing, no Hammerspoon.
- Coexists with the existing voxtype push-to-talk; does not replace it yet.
- One model for both languages: `large-v3-turbo` with language auto-detect.
  The clipboard flow tolerates the slower decode, and it removes the
  EN/CZ switching problem entirely.

## Models

On disk at `~/Library/Application Support/voxtype/models/` (reusable, no
re-download needed):

| File | Size | Notes |
|---|---|---|
| `ggml-small.en.bin` | 466 MB | English-only, fast. Current EN daemon model. Known decode-collapse on long/hard clips (Whisper autoregressive degeneracy) — see rescue.sh below. |
| `ggml-large-v3-turbo.bin` | 548 MB | Multilingual. This is the q5_0 quant (voxtype downloaded and renamed it; the fp16 original is ~1.5 GB). Current CZ model. |
| `ggml-silero-vad.bin` | 865 KB | Silero VAD. Its absence caused "Thank you." hallucinations — always ship it alongside. |

Download sources (HuggingFace, `ggerganov/whisper.cpp`):

- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin` (466 MB)
- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin` (547 MB)
- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin` (1.5 GB, full precision)
- The whisper.cpp repo also ships `models/download-ggml-model.sh`.

Repo rule: the Engineer manages `whisper.model` in voxtype's config
personally. ClipB gets its own model setting; changing voxtype's needs
explicit approval.

## Running them

Today:

- `whisper-cpp` is NOT installed. Planned: `brew install whisper-cpp`
  (gives `whisper-cli` and `whisper-server`).
- One-shot decode already works via voxtype:
  `voxtype -c ~/.dotfiles/voxtype/config-cs.toml transcribe` (large-v3-turbo,
  `language = "cs"`). `czech-dictate.sh` shows the full pattern: ffmpeg
  avfoundation → 16 kHz mono WAV → decode → output.
- ffmpeg mic capture details live in `~/.dotfiles/voxtype/czech-dictate.sh`
  (`-fflags nobuffer -probesize 32 -analyzeduration 0`, device
  "MacBook Pro Microphone").

Target (option C in the voxtype handover, spike still pending):

- `whisper-server` per model, held in RAM as launchd agents. Plain local
  HTTP (default `:8080`, `POST /inference`). Acceptance gate from the
  voxtype handover: a real 10 s clip must decode in under ~1 s.

For the agent (Claude) running this as background tasks:

- The servers are plain local HTTP, so an agent can launch them as
  background tasks, poll the health endpoint, and watch memory.
- Memory watching: copy the pattern from
  `~/.dotfiles/voxtype/memcheck-restart.sh`. Use `top -stats mem` — it
  counts compressed pages and matches Activity Monitor. `ps -o rss=`
  under-reports badly (once read 200 MB while the real footprint was
  14 GB). `vmmap`/`footprint` need the target's task port and fail on
  hardened-runtime binaries without sudo.
- Rough expected footprints, to be measured in the spike: small.en
  ~0.5–0.7 GB resident, turbo q5_0 ~0.6–0.9 GB.

## Post-processing to reuse

- `~/.dotfiles/voxtype/rescue.sh`: drops known hallucinations ("thank
  you", "thanks for watching", bare "you", "bye") and reruns a
  punctuation-only transcript (decode collapse) through large-v3-turbo.
  Note: it returns a single space instead of empty output only because
  voxtype ignores empty post_process output — ClipB owns its pipeline and
  can discard properly.
- The sed cleanup in voxtype's `[output.post_process]` (e.g. `get`→`git`).
  Voice-copy output should pass through the same filters before touching
  the pasteboard.
- Sound cues: `~/.dotfiles/voxtype/sounds/start.wav`, `stop.wav`.

## Update 2026-11-02: GPU + streaming (from the voxtype session)

Scope grew: ClipB becomes the full voxtype replacement, written in Swift,
not just voice-copy. Requirements from the Engineer: runs on GPU / Neural
Engine, `large-v3-turbo`-class model, EN + CZ, and it must *feel* like
streaming — text ready the moment the key is released.

### Findings

- voxtype now runs `large-v3-turbo` as its main model (was `small.en`).
  Czech decodes fine even with `language = "en"`.
- **voxtype is NOT on the GPU.** The Cask prebuilt (0.7.5, `gpu-metal`, links
  Metal) logs `ggml_metal_device_init: GPU name: Apple M4 Pro`, then
  `whisper_backend_init_gpu: no GPU found` → `using BLAS backend` (CPU).
  Hypothesis, unverified: ggml types Apple Metal as `IGPU`; the vendored
  whisper.cpp only accepts `GPU`. A patched source build is being tested;
  results go in `~/.dotfiles/voxtype/handover.md`.
- CPU speed today: 1.6 s take → 0.74 s; 16 s take → 1.26 s wall.
- Lesson for ClipB: log which backend actually ran, every decode. "Metal
  linked" proved nothing.

### Where latency hides

1. Mic opens on key press: ~1 s lost (voxtype's record-buffer misses each
   take's first second).
2. Decode starts only after release.
3. Shell post-process per take (`rescue.sh`, sed).
4. Keystroke typing grows with text length.

### Design for "feels like streaming"

- **Always-on mic.** AVAudioEngine runs all day into an in-memory ring
  buffer (~30 s, never on disk — matches ClipB's privacy rule). Key down
  takes ~300 ms of pre-roll, so the first word is never clipped.
- **Model always warm.** Load at launch, prewarm with a silent decode. No
  per-take load, no subprocess, no HTTP hop.
- **Decode while the key is held.** Benchmark both:
  - *Streaming re-decode:* every ~0.5–1 s, decode audio since the last
    confirmed text. Text two passes agree on is confirmed (WhisperKit's
    local-agreement approach). On release only the short tail remains.
  - *VAD chunking:* close a chunk at each speech pause, hard cap ~10 s,
    decode it at once. Cut at pauses, not a fixed 10 s, so words never
    split. Feed previous chunk text as the prompt.
- Whisper's encoder always runs a 30 s padded window, so shorter chunks
  don't make each pass cheaper. The win is doing the work during speech.
- **Target:** key release → text ready in under ~300 ms, any take length.
- **Language:** constrain detection to en/cs; detect on the first ~2 s,
  or per chunk for mixed takes.
- **Post-process in Swift:** port voxtype's sed rules, `[text.replacements]`,
  `initial_prompt` vocabulary, hallucination list, collapse re-decode.
- **Optional live preview** overlay near the menu bar while speaking.

### Engines to benchmark (GPU / ANE, Czech) — all unverified until measured

1. WhisperKit `large-v3-turbo` (CoreML on the Neural Engine). Lead
   candidate: Swift-native, has streaming built in, fits SwiftPM.
2. whisper.cpp with Metal + CoreML encoder, if the IGPU fix works.
3. Apple SpeechAnalyzer / SpeechTranscriber (macOS 26). Czech unknown.
4. mlx-whisper turbo (Metal). Python — would need a sidecar; last resort.
5. Parakeet v3 (MLX/CoreML). Czech unverified.

Benchmark on one real 15–20 s mixed EN + CZ clip: time to text after
release, word accuracy, which backend ran.

### Supersedes

- The `whisper-server` over HTTP plan (option C) and its spike: an in-process
  warm model beats an HTTP hop. Keep it only as the fallback if no Swift
  engine hits the target.

## Open questions

- Hotkey: Right Option hold (voxtype's today) vs. hold Cmd+C (this doc's
  design)? Or both — Right Option types/pastes, Cmd+C to clipboard?
- Live typing of confirmed text while speaking, or paste once on release?
- Esc-to-cancel vs. release-to-cancel-only: confirm Esc discards.
- Small English fast path later (small.en when the take is clearly EN)?
  Adds a language-detection step; probably not worth it at first.
- Retire the Karabiner/Hammerspoon Czech flow once voice-copy ships?
- Auto-paste after transcription, or clipboard only? (Default: clipboard
  only.)
- ClipB will trigger a one-time mic-permission (TCC) prompt on first
  recording.
- Whisper.cpp can do VAD internally (`--vad` with the silero model);
  decide whether to rely on that or record the full hold duration (the
  hold itself is already a hard start/stop, so VAD may be unnecessary
  here — unlike the tap-driven voxtype flow).

## Next step

Superseded 2026-11-02: start with the engine benchmark (WhisperKit first),
then the always-on mic ring buffer. The list below is the original plan.

1. `brew install whisper-cpp`.
2. Spike: start `whisper-server` on `small.en`, time a real 10 s clip
   over HTTP. Under ~1 s → the server design is viable.
3. Prototype the Cmd+C observer in ClipB alone (no whisper): log
   "would record" / "was copy". This validates the state machine and the
   200–300 ms poll against real apps, especially Electron ones.
4. Wire ffmpeg + decode + pasteboard write.
