---
name: run
description: Build, launch, and smoke-test ClipB. Use when asked to run the app, verify a change works, or check the app after edits.
---

# Run and smoke-test ClipB

## Launch

```sh
make open    # release build → bin/ClipB.app, kills previous instance, opens
```

`open` handles the kill-previous step; the app also terminates other
instances of `com.productmind.clipb` at launch.

## Verify it's healthy

1. Process is up: `pgrep -lf clipb`
2. UTF-8 round-trip: `printf 'Příliš žluťoučký kůň 🐴' | pbcopy`, wait ~1 s,
   confirm the process is still running (`pgrep -x clipb`).
3. No network sockets (privacy invariant):
   `lsof -i -a -p "$(pgrep -x clipb)"` must output nothing.
4. Unit tests: `make test` (never raw `swift test` — see CLAUDE.md).

## Manual checks (need a human)

- Menu bar clipboard icon shows copied entries, newest first.
- Cmd+Shift+V pops the history menu at the cursor; selecting pastes
  (requires Accessibility permission, else it only copies).
- Full acceptance checklist: SPEC.md §5.

## Gotchas

- First launch after a signature change prompts for Accessibility again;
  the Makefile's ad-hoc codesign keeps it stable across rebuilds.
- The app is `LSUIElement` — no Dock icon. "Nothing happened" usually means
  it launched fine; look at the menu bar.
- Quit via the tray menu or `killall clipb`.
