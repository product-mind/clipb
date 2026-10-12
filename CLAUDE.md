# ClipB — agent notes

In-memory clipboard history manager for macOS. Swift + AppKit, zero
third-party dependencies. Read `SPEC.md` before changing behavior — it is
the source of truth for features and edge cases.

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
  The dev build also delays pasting by 1 s (temporary, simulates the future
  LLM pipeline; see `AppDelegate.debugPasteDelay`).
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
- `PopupTabs.swift` — pure tab model for the popup (tested).
- `HistoryPanel.swift` — hotkey popup: non-activating `NSPanel`. Never call
  `NSApp.activate` there; it would steal focus from the frontmost app.
- `AppDelegate.swift` — tray menu (rebuilt in `menuNeedsUpdate`), hotkey
  popup, wiring. Menu items hold the entry value in `representedObject`.

## Known AppKit constraint

Menu items with submenus don't fire click actions, so tray entries use a
Copy/Obfuscate/Delete submenu instead of click-to-copy (SPEC.md §2.2).
Don't "fix" this by removing the submenu.

## History

Rewrite of github.com/VojtechVitek/clippy (Go + getlantern/systray + cgo),
built from that repo's `REBUILD.md` spec with no code carried over.
