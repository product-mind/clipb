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
  Keep the ad-hoc codesign step: it keeps the user's Accessibility grant
  stable across rebuilds.
- `make` (= `make dev`) — dev-only build to `bin/ClipB.app`, kills the
  previous instance, launches. History is saved to `~/.clipb-dev/history.json`
  on exit and reloaded on launch (`--persist-file <path>` overrides).
  `make test` also compiles with `-DDEV_PERSIST`.
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
