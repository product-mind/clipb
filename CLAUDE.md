# ClipB — agent notes

In-memory clipboard history manager for macOS. Swift + AppKit. One
third-party dependency: whisper.cpp (prebuilt xcframework, voice copy); keep
it that way unless a dependency clearly earns its place. Read `SPEC.md` before changing behavior — it is
the source of truth for features and edge cases.

Commit directly to `master`. Do not create branches yet.

## Hard invariants — never break these

1. History is in-memory only. Never write clipboard values to disk,
   UserDefaults, logs, or crash reports. The only exception is
   `DevPersistence.swift`, compiled solely under `-DDEV_PERSIST`
   (`make`). Never add file I/O for history outside that flag.
2. Zero network connections. Do not add any networking dependency or call.
   The one local Unix socket for `clipb copy` (`IPCServer.swift`) is fine.
3. Obfuscated entries must never render their full value anywhere visible
   (menu title, tooltip, popup) — only via Copy.
4. All state (`ClipboardHistory`) is main-thread only. No locks; keep it
   that way. Timers and menu callbacks already run on the main run loop.

## Build & test

- `make test` — NOT `swift test`. This machine has Command Line Tools only
  (no Xcode); the Makefile adds `-F`/`-rpath` flags so Swift Testing links.
  Tests use Swift Testing (`import Testing`), not XCTest — XCTest is
  unavailable here.
- `make bundle` — release build + ad-hoc codesign into `bin/release/ClipB.app`.
  Keep the codesign step and its `-r` requirement (identifier-only): plain
  ad-hoc signing pins the cdhash, so every rebuild invalidates the user's
  Accessibility grant while System Settings still shows it as on.
- `make` (= `make dev`) — dev-only build to `bin/ClipB.app`, kills the
  previous instance, launches. History is saved to `~/.clipb-dev/history.json`
  on exit and reloaded on launch (`--persist-file <path>` overrides).
  `make test` also compiles with `-DDEV_PERSIST`.
- After committing any change, ALWAYS run `make` so the running app picks
  it up. The kill-and-relaunch is the point, not a side effect; history
  survives via the DEV_PERSIST save/restore. Never leave the running binary
  older than HEAD.
- `make dist` — the downloadable build (`scripts/dist.sh`): arm64, Developer
  ID signed with the hardened runtime and `appInfo/ClipB.entitlements`
  (microphone), DMG in `bin/dist/`, notarized and stapled. Needs a
  "Developer ID Application" cert and a `clipb` notarytool profile;
  `DIST_IDENTITY=-` makes an ad-hoc test DMG, `DIST_MODEL=<path>` bundles the
  speech model. The script refuses a binary that links `DevPersistence`.
  Anything new that executes inside the app (a helper, a dylib) must be
  signed inside-out before the app, or notarization fails.
- `make install-cli` — symlinks `clipb` into `~/.local/bin` (must be on PATH).
- `make reset-accessibility` — paste only beeps although Accessibility shows
  as on? The grant is stale (the signing requirement was once per-build).
  Run this, `make`, accept the prompt once. Never run it from other targets:
  it wipes the user's grant.
- `make release` — production bundle (`bin/release/ClipB.app`) + launch. After
  touching the persistence code, check `nm .build/release/clipb | grep
  DevPersistence` is empty for the plain release build.

## Architecture

- `ClipboardHistory.swift`, `Titles.swift` — pure logic, fully unit-tested.
  Put any new testable logic here, not in AppDelegate.
- `ClipboardWatcher.swift` — polls `NSPasteboard.changeCount` every 500 ms;
  reads content only on change. Never shell out to `pbpaste`/`pbcopy`
  (that path caused UTF-8 mojibake in the Go predecessor).
- `HotKey.swift` — Carbon `RegisterEventHotKey` for Cmd+Shift+V.
- `Paste.swift` — CGEvent Cmd+V; degrades gracefully without Accessibility.
- `CopyCommand.swift`, `IPCServer.swift`, `IPC.swift` — `clipb copy` client
  and its Unix-socket server. The server reads off the main thread and must
  hop to main before touching `ClipboardHistory`. Text comes from stdin only.
- `TOML.swift`, `Router.swift` — pure, tested: config parser, rule matching,
  Chromium profile lookup. `BrowserLauncher.swift` does the `NSWorkspace`
  launch; `RouteCommand.swift` (`clipb route <url>`) is its dry run. ClipB is the default browser; links arrive in
  `AppDelegate.application(_:open:)`. Never write a link to the system
  pasteboard, and never make ClipB a routing target (loop).
- `ExtensionRouting.swift`, `NativeHost.swift`, `extension/chrome/` — Chrome
  extension. `clipb` doubles as the native messaging host (Chrome passes
  `chrome-extension://…` as argv[1]; see `main.swift`), so stdout carries
  protocol frames only: never print to it. Errors must mean "stay", never move.
  `RedirectLedger` holds moved links in memory for 60 s; never persist it.
  The extension id is pinned by the `key` in `manifest.json` and mirrored in
  `NativeHostInstaller.devExtensionID`; change them together. Every commit
  touching `extension/` bumps the patch version in `manifest.json`, and the
  popup's note line shows it.
- `Pipes.swift`, `PipeRunner.swift`, `PipeChooser.swift` — Cmd+Shift+X pipes
  (SPEC §2.10) and the Cmd+Shift+C copy pipe bound via `hotkey` (SPEC §2.11).
  Errors and Esc must put the cut text back: a cut never loses text.
- `HistoryFilter.swift` — pure merged-entry list and `#tag`/`#source` search
  for the popup (tested).
- `HistoryPanel.swift` — hotkey popup: non-activating `NSPanel`. Never call
  `NSApp.activate` there; it would steal focus from the frontmost app. It also
  owns the bottom pipe buttons and Shift+Enter paste-and-delete;
  `PipeStrip.swift` holds their pure state (digits, labels, running label)
  and `PipeOptionsRow.swift` is the shared digit-above-button widget, used by
  the popup and the `PipeChooser` modal too.
- `VoiceCopyGesture.swift`, `VoiceCopyMonitor.swift`, `PasteKeyTap.swift`, `Cue.swift`,
  `AudioRecorder.swift`, `Microphone.swift`, `VoiceConfig.swift`,
  `MicsCommand.swift`, `WhisperTranscriber.swift`, `Transcript.swift` —
  hold Cmd+C / Cmd+V (or Right Option, opt-in) to dictate (SPEC §2.13). Cmd+C and Right Option are observed only:
  never intercept, swallow or delay it. Plain Cmd+V is the one key ClipB
  holds back (`PasteKeyTap.swift`, own thread, replays a tap); keep that tap
  minimal and mark every synthetic key event with `syntheticMarker`. Record only from `[voice] microphones`
  (default `["built-in", "default"]`); never follow the system default
  unless "default" is listed. Audio stays in memory, never on disk;
  never log transcripts. whisper calls run on its own serial queue and hop
  to main. `make` embeds `whisper.framework` in `Contents/Frameworks`.
- `AppDelegate.swift` — tray menu (rebuilt in `menuNeedsUpdate`), hotkey
  popup, wiring. Menu items hold the entry value in `representedObject`.

## Known AppKit constraint

Menu items with submenus don't fire click actions, so tray entries use a
Copy/Obfuscate/Delete submenu instead of click-to-copy (SPEC.md §2.2).
Don't "fix" this by removing the submenu.

## History

Rewrite of github.com/VojtechVitek/clippy (Go + getlantern/systray + cgo),
built from that repo's `REBUILD.md` spec with no code carried over.
