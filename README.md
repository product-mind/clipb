# ClipB

A minimalistic, in-memory clipboard history manager for macOS.

Menu bar app. Global hotkey **Cmd+Shift+V** opens your clipboard history
as a popup menu at the mouse cursor — pick an entry and it pastes itself.

## Privacy

1. All history lives **in memory only**. Nothing is ever written to disk.
   Quit the app and the history is gone.
2. The app makes **zero network connections**.
3. It is **not a password manager**. Don't treat it as one.

## Features

- Watches the clipboard and keeps the last 100 text entries, newest first.
- Duplicates aren't re-added; they move to the top.
- **Cmd+Shift+V** popup at the cursor: click an entry to copy *and* paste it.
- Menu bar menu: per-entry **Copy**, **Obfuscate Password**, **Delete**,
  plus **Clear** for everything.
- Obfuscate shows `abcd****…` everywhere the entry is displayed —
  handy while screen-sharing. Copying still yields the full value.

## Install

Requires Xcode command line tools.

```sh
make        # builds bin/ClipB.app and opens it
```

On first run, grant **Accessibility** permission
(System Settings → Privacy & Security → Accessibility) so the popup can
paste for you. Without it, selecting an entry still copies — just press
Cmd+V yourself.

## Develop

```sh
make test   # unit tests (history, truncation, obfuscation)
make clean
```

The full product spec lives in [SPEC.md](SPEC.md).

## License

MIT
