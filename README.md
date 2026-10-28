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

- Watches the clipboard and keeps the last 1000 text entries in one shared
  recency list, newest first. Copied images and Finder file references are
  remembered too, and paste back the same way.
- Duplicates aren't re-added; they move to the top.
- **Cmd+Shift+V** popup at the cursor: click an entry to copy *and* paste it.
- One flat list across all tags, newest first. Type `#tag` or `#App` to filter
  by tag or source app (`#q` for the `quote` tag, `#saf` for Safari entries);
  several `#` tokens must all match.
- **Cmd+Shift+X** cuts the selection and pipes it through a command from
  `~/.config/clipb.toml`. Pipes read the clipboard entry on stdin: text bytes,
  an image's PNG bytes, or file URLs one per line. Output is pasted back;
  empty output means the pipe consumed it. Save any clipboard item — text, image, file refs — to disk with
  `[pipe.shot] run = 'f=$(mktemp /tmp/clipb-XXXXXX); cat > "$f"; echo "$f"'`.
- **Cmd+Shift+C** takes a screenshot straight to the clipboard; it
  shows up in the history like any copied image. `clipb shot` does the same
  from the command line, exit 1 when the capture fails.
- With pipes configured, the popup shows them as buttons along the bottom:
  each button's label is the pipe's `name` with its key, `name ⌘N`, inline.
  A click, or the digit, pipes the
  highlighted entry through it at once; plain Enter still pastes. While it
  runs, `Running <name>…` takes the buttons' place and Esc cancels.
- **Shift+Enter** in the popup pastes the entry *and* deletes it — a one-time
  secret survives neither in the history nor on the clipboard.
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
