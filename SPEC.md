# ClipB — Product Specification

ClipB is a minimalistic, in-memory clipboard history manager for macOS,
built with Swift + AppKit and zero third-party dependencies.

## 1. Product summary

- Runs as a menu bar app with no Dock icon and no windows (`LSUIElement`).
- Watches the system clipboard and keeps a history of copied text.
- Global hotkey (Cmd+Shift+V) opens a search popup at the mouse cursor.
- Selecting an entry copies it to the clipboard and pastes it into the
  frontmost app.

### Privacy guarantees (hard requirements)

1. All history lives in memory only. Nothing is ever written to disk.
2. Quitting the app loses all history. This is by design.
3. The app makes zero network connections. The only socket it opens is a
   local Unix-domain socket for `clipb copy` (§2.7). Pipe commands (§2.10)
   are the user's own programs; whatever they reach is up to them.
4. It is not a password manager.

Development exception: a build compiled with `-DDEV_PERSIST` (`make`)
saves history to a file on exit and reloads it on launch. Release builds
(`make release`) contain no such code.

## 2. Features

### 2.1 Clipboard monitoring

- Poll `NSPasteboard.changeCount` every 500 ms; the pasteboard is read once
  per change, whichever kind of content it holds.
- Priority: non-empty text, else an image, else copied Finder file refs.
  Nothing to capture leaves the history untouched.
- Images: a PNG or TIFF is stored as PNG bytes, TIFF converted through
  `NSBitmapImageRep`. One image above 8 MB is skipped silently. The entry
  shows as `[image] 1200×800`, dimensions parsed from the PNG header.
- File refs: a Finder copy stores the file URLs, never the file bytes, plus
  the first file's name, shown as `[file] Report.pdf`. Directories included.
  A moved file becomes a dead reference — accepted, history never touches disk.
- Text values are trimmed of surrounding whitespace. Empty values are ignored.
- History is one shared array of up to 1000 entries, globally newest-first.
  Tags are filters over that array, not separate lists.
- Duplicate of an existing (value, tag, payload) entry: move it to the front
  of the recency order instead of adding a second entry. Its obfuscation state
  is preserved. The same value under a different tag is a separate entry, and
  two different images are separate entries despite the shared `[image]` value.
- Capacity: 1000 entries total. When full, the globally oldest entry is
  evicted. A 64 MB byte budget (image bytes included) additionally drops the
  largest entry outside the 10 newest until the total fits.
- Images are capped separately: at most 10 image entries and 50 MB of image
  bytes; pushing over either drops the oldest image first.
- Source app: each entry remembers the app it was copied from, in memory
  only. ClipB uses the `org.nspasteboard.source` marker when the app sets it,
  else the frontmost app at poll time (a best guess within the 500 ms poll).
  A duplicate takes the new source. ClipB's own writes keep the old one.
  Pipe outputs (§2.10) take the app the text was cut from.

### 2.2 Menu bar (tray) menu

- Template (monochrome) clipboard icon; tooltip "Clipboard".
- Menu contents, top to bottom: disabled `ClipB` title, `Quit`, one Clear
  item per list, separator, one row per uncategorized entry (newest first).
  Without tags the single item is `Clear`. With tags the uncategorized item is
  `Clear (<N>)` and each tag gets `Clear “<tag>” (<N>)`. Each item clears
  only its own entries, so a casual Clear never wipes tagged entries.
- Entry row title: value truncated to 20 bytes (UTF-8 safe), suffixed
  `... (<N> chars)` when truncated. Tooltip shows the full value —
  except for obfuscated entries, whose tooltip shows the obfuscated title.
- Each entry row has a submenu:
  - `Copy` — copies the full value to the clipboard.
  - `Obfuscate Password` — toggles obfuscation (checkmark reflects state).
  - `Delete` — removes the entry.

Note: AppKit menu items with submenus don't fire a click action, so copy
lives in the submenu. The primary copy flow is the hotkey popup anyway.

### 2.3 Obfuscation

For screen-sharing safety when a password was copied:

- Display: first 4 characters shown, the rest replaced by `*`, capped at
  the row's truncation length.
- The underlying value is untouched — copying still yields the full value.
- Applies everywhere the entry is displayed (tray menu and popup).

### 2.4 Global hotkey popup

- Cmd+Shift+V registered system-wide (Carbon `RegisterEventHotKey`).
- On press: a non-activating `NSPanel` at `NSEvent.mouseLocation`, entries
  most-recent-first. No-op when the history is empty. ClipB is never
  activated, so the frontmost app (e.g. an iTerm2 hotkey window) keeps focus.
- The list is one flat list of every entry across every tag, in global recency
  order — never one tag's entries after another's.
- A search field on top filters the list by case-insensitive subsequence
  match and ranks the matches best first: an entry containing the whole query
  beats scattered matches, longer runs of adjacent matched characters and
  word starts score higher, and ties keep recency order. Enter picks the top.
  Obfuscated entries match on their masked title, never their value.
  The source app (pill) is searched too: `slack` finds entries copied from Slack.
- `#`-prefixed tokens filter by tag OR source app, fuzzily, and several of
  them AND: `#q` matches the `quote` tag, `#saf` matches entries copied from
  Safari, `#quote #saf` needs both. A row with no tag and no source is never
  matched by a `#` token; a bare `#` matches rows that have any tag or source. The text outside the `#` tokens fuzzies the title
  and source as always, so `#en alp` narrows the `en` tag to `alpha` matches.
  Without `#` tokens the query behaves exactly as before.
- Pinned to the very bottom of the panel, under the list, sit the pipe
  buttons whenever pipes are configured: one horizontal row of rounded
  buttons labeled with the pipes' `name`s and their key, `name ⌘N`, on one
  line truncating in the middle (at most ~200 pt wide), the key in the
  name's ink one step quieter (0.65 black in light mode, `labelColor` in
  dark; monospaced digits, a size down). Option 1 is the first
  `[pipe.<id>]` table in file order (§2.10), option 2 the second, and so on,
  at most nine; the config is read fresh on every popup open. Directly above
  the bar sits a tertiary 11 px hint line, `⏎ paste · ⇧⏎ paste & delete ·
  ⌫ delete · ⌘H hide`, which stays put while a run swaps the bar for
  `Running <name>…`. The Cmd+Shift+X chooser shares the widget and reads the
  same way. No pipes configured, or a config that does not parse:
  the bar and the hint line are both absent.
- Clicking a button or pressing its Cmd+digit runs that pipe at once on the
  highlighted row — no selection state, no Enter. Plain Enter still pastes.
  Buttons never accept first responder, so clicking one never pulls focus out
  of the search field. A Cmd+digit with no matching pipe does nothing.
- Digits always type into the query, pipes or not: `3.11` is searchable, `|`
  is an ordinary character, and Up/Down/Left/Right/Tab/Cmd+A behave as always.
  There is no digit-paste veto.
- While a pipe runs the button row gives way to `Running <name>…` in the same
  bottom slot, so the search field does not move, and the value is piped
  through that command with the panel still open (§2.10). On success the
  output is pasted and filed under the pipe's `<id>` with the target app as its
  source; exit 0 with no output closes the popup and pastes nothing, the pipe
  having consumed the entry (a `cat > file` sink for an image does exactly
  this); a failure, a timeout, or output that is not UTF-8
  closes the popup, pastes the original value, which stays in history, and
  shows a notice naming the pipe, `Pipe <name> failed — original pasted back`
  (no beep: the notice is the signal).
  While a pipe runs, Enter, Shift+Enter, clicks, Cmd+digits, deletes, and
  obfuscation do nothing: the run owns the panel.
- Each row shows action buttons only while the pointer is over it (also while
  scrolling), left to right:
  - open: only when the value is exactly one http(s) URL; routes it through the
    link router (§2.8) and closes the popup;
  - copy: puts the value on the clipboard without pasting and closes the popup;
  - obfuscate / show: toggles obfuscation (Cmd+H, or the button), the popup stays open;
  - ✕: deletes the entry, the popup stays open. Cmd+Delete always deletes the selected entry.
  Delete (or forward Delete with the caret at the end) deletes it once the
  search text is empty, but not on key repeat and not within 0.4 s of the
  last edit, so clearing the query never eats entries.
- Right-clicking a row deletes that entry, like the ✕ button.
- Keys: Up/Down move the selection, Enter selects, Shift+Enter pastes and
  deletes (below). Tab and Shift+Tab do nothing. Esc peels one layer at a
  time: a running pipe is cancelled, otherwise the popup closes. Cancelling a
  run restores the button row and pastes nothing.
- Each row shows its tag as a `#tag` pill and its source app as a `#App` pill,
  tag first, both flush against the row's right edge (source outermost, the tag
  to its left); a missing tag or source is simply omitted. The title truncates
  to the space left of them. While the pointer is over a row its hover buttons
  take the pills' slot: the pills hide and the title shrinks clear of the
  buttons; they return once the pointer leaves. Also on obfuscated
  rows: a pill is a name, never the value.
- Popup titles: newlines flattened to spaces, truncated to 60 bytes without
  splitting a character, suffixed `... (<N> chars)` when truncated.
  Obfuscated entries render obfuscated. Image entries render title-only for
  now, `[image] 1200×800`, with no thumbnail; file entries render their name.
- Every row pipes, images and files included: the bytes, or the URL, ride
  stdin (§2.10). Enter and Shift+Enter still paste those rows through the
  same clipboard-and-Cmd+V path, and the row's copy button writes the real
  payload.
- Selecting an entry writes the full value to the clipboard, then simulates
  Cmd+V in the previously focused application.
- Shift+Enter pastes the highlighted entry and deletes it in one action, for
  values that should not be kept: a one-time secret leaves neither the history
  nor the pasteboard. Works on obfuscated entries, whose stored value is the
  real one. The paste is sent first; only then is the entry deleted — a
  focus race that skips the paste skips the delete too, the entry stays and
  the clipboard still holds it. The clipboard is cleared 2 s after the paste
  went out, and only while it still holds exactly that value — anything the
  user copied in between stays.
  Deleting a tag's last entry drops its pill from every row and lets `#tag`
  match nothing, like the ✕ button.
- Dismissing (Esc / click outside / losing key status) does nothing: no
  paste, no clipboard change. Key focus returns to the window that held it
  before the popup — Esc and the hotkey-toggle reassert it via Accessibility,
  a click outside gives it to the clicked window.
- Pressing the hotkey while the popup is open closes it. While it is open
  Cmd+Shift+X and Cmd+Shift+C do nothing at all: no cut, no chooser, no capture.

### 2.5 Paste simulation and permissions

- Simulated Cmd+V (CGEvent) requires macOS Accessibility permission.
- First run prompts for it (`AXIsProcessTrustedWithOptions`).
- Graceful degradation: without the permission the value is still on the
  clipboard — the user pastes manually.
- Paste target: on hotkey press, remember the app that holds key focus
  (Accessibility's focused window, not NSWorkspace's frontmost — a
  non-activating panel like the Ghostty quick terminal holds key while
  another app stays frontmost) plus its focused window and field. On
  select, refocus that window and field via Accessibility, without
  activating the app, then paste: CGEvent Cmd+V lands in the key window,
  so frontmost status never matters. Activating the target app is only a
  fallback when the AX refocus fails; if focus cannot be restored, nothing
  is pasted and it beeps. A missing permission beeps instead of failing
  silently.

### 2.6 Text handling edge cases

- All clipboard text must round-trip as UTF-8; non-ASCII (diacritics, CJK,
  emoji) must never be mangled. Native `NSPasteboard` guarantees this —
  never shell out to `pbpaste`/`pbcopy`.
- Byte-level truncation must never split a UTF-8 character
  (`Titles.truncateUTF8`, covered by tests).
- NUL bytes and carriage returns are stripped from display titles.

### 2.7 `clipb copy` command

- `<text> | clipb copy [--tag <tag>]` adds stdin to the history under the tag.
  No tag means uncategorized. The binary doubles as the client: the app's own
  executable handles the `copy` subcommand and exits without starting a UI.
- Text comes from stdin only, never from arguments (they show up in `ps`).
- Transport: Unix-domain socket `~/.clipb/clipb.sock` (directory `0700`,
  socket `0600`). One JSON message per connection, answered with `ok`.
  Messages over 64 MB are rejected.
- Tags are a property of each entry in the one shared history. Each tag
  filters the hotkey popup through `#<tag>` (§2.4).
- The listener reads on a background thread and hands each message to the
  main thread before touching history.
- App not running: the client starts it (`open -b`) and retries for 3 s. If
  that fails it exits 1 and prints the text to stderr so it is not lost.
- Exit codes: 0 delivered (or blank input), 1 delivery failed, 2 usage.
- On quit the app removes its socket, unless a newer instance replaced it.

### 2.8 Link router

ClipB can be the default web browser. macOS then hands it every clicked
`http(s)` link (Apple Event → `application(_:open:)`); it records the link
and forwards it to the browser and profile the config picks. Links clicked
inside a browser never reach ClipB.

- History: each link is pushed in memory under the tag `link` (reachable in
  the popup through `#link`). It is never written to the system pasteboard, so
  the user's current clipboard survives.
- Config: `~/.config/clipb.toml`, a TOML subset (tables, string /
  integer / boolean values, `#` comments). Parsed once and cached; re-read when the file's mtime or size changes, so edits apply to the next link without a restart.
  Sample: `examples/config.toml`. Unknown sections are ignored.
- `clipb route <url>` is a dry run: it prints the browser and profile folder
  the config would pick and opens nothing. For `ask` it prints `browser: ask`,
  plus a `note:` line with any problem. It exits 1 when there is a problem.
- `[router]`: ordered `"pattern" = "target"` rules, first match wins.
  - Pattern containing `://`: glob on the full URL.
  - Pattern with `*` or `:`: glob on the host (`host:port` if it has a colon).
  - Plain domain: that host and all its subdomains. `*.x.com` needs a subdomain.
  - `*` matches any run of characters, including `/`. Case-insensitive.
- Target: `browser` or `browser:profile`. Browsers: `chrome`, `brave`, `edge`,
  `safari`, `firefox`, or a raw bundle id. Only Chromium browsers take a profile.
- Target `ask`: ClipB shows a chooser instead of opening the link (see below).
  Example: `"*" = "ask"`. `ask` has no profile.
- Chooser: a small centered panel that never activates ClipB. It takes key
  focus while open; Esc hands it back to the window that held it, like the
  popup (§2.4).
  - Header: `Open in:` and the link's host only. The full URL is never shown,
    since SAML and OAuth URLs carry secrets.
  - Options: one button per Chrome profile, then Safari. Profiles come from
    Chrome's `Local State`: `Default` first, then by folder name. The label is
    the profile's display name, or its folder when the name is empty.
  - At most nine options. Safari is always last, so at most eight profiles show.
  - Click a button, or press its digit (1-9), to open the link there.
  - Esc, or clicking away, closes it. Nothing opens. The link stays in the
    popup's `#link` entries.
  - A new link while the chooser is open replaces it.
  - Chrome missing or no `Local State`: only Safari is listed.
  - Problem line (secondary text under the header), when a config or rule
    problem blocks the target. It never shows the URL. `Continue anyway`
    appears only when Safari can open the link; it is not digit-bound.
  - `Remember for:` (hidden while a problem shows). Radio buttons, one choice:
    - `Don't remember` (default): saves nothing.
    - The host, with `:port` when the port is not the default. Example: `a.b.example.com`.
    - `*.parent` when the host has a subdomain. Parent = last two labels.
      Skipped for public suffixes (`co.uk`, `com.au`) and IP addresses.
    - `scheme://host/first/*` when the path has two or more segments.
      Example: `/oauth/authorize` gives `https://x.glean.com/oauth/*`.
    - Only host and path are saved. Query and fragment never are.
  - Keys: `↑`/`↓` move the radio choice (wraps). Digits pick a profile. Hint
    line: `↑↓ remember · 1-9 open · Esc cancel`.
  - Picking a profile or Safari with a remember choice first writes the rule,
    then opens the link. The rule goes before the `"*"` rule (or after the
    last rule when there is none), and replaces the target if the pattern
    already exists. The target is `chrome:<email>`, else `chrome:<display
    name>`, else `chrome:<folder>`, or the matching `[profiles]` alias.
    A failed write beeps, and the link still opens.
  - The write touches only `~/.config/clipb.toml` (through a symlink, if any).
    An unparsable file is left alone. A missing file is created.
- `[profiles]`: optional aliases, `"chrome:personal" = "chrome:me@example.com"`.
- Profile resolution reads Chromium's `Local State` at click time and matches
  the signed-in email, then the display name, then the folder name. The config
  never holds folder numbers, so it can be shared between machines.
- Launch: with a profile, `--profile-directory=<folder> <url>` through a new
  application instance (like `open -n`); otherwise a plain open.
- No matching rule (and no `"*"` rule) → the chooser, never a guessed profile.
  A `"*"` rule is the default and always wins over asking.
- Problems never guess a browser. An unreadable or missing config → the
  chooser with a problem line (`Can't read ~/.config/clipb.toml: …`). A rule
  whose browser is unknown, not installed, or ClipB itself → the chooser with
  a problem line, plus `Continue anyway` (opens Safari). No rule is saved
  while a problem shows. A profile that matches nothing → the browser's
  default profile.
- Non-`http(s)` URLs (HTML files) go to Safari and are not recorded.

### 2.9 Chrome extension (ClipB Router)

The link router (§2.8) only sees links clicked outside a browser. The
extension in `extension/chrome/` covers navigations inside Chrome by moving a
tab to the profile the same config picks. It holds no rules.

- Native messaging: the extension calls `clipb` as a native host (stdin/stdout
  frames, no network). `clipb install-native-host` writes the host manifest to
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` and
  allows the extension id pinned by the `key` in `manifest.json`
  (`--extension-id <id>` adds more, e.g. a Web Store id).
- Ops: `decide` (url, current profile email → move or stay, reason, target)
  and `open` (the host forwards the URL to the running app over the §2.7
  socket as an `open` message; the app records it under `link` and routes it).
- The extension reads its own profile's signed-in email
  (`chrome.identity.getProfileUserInfo`); the host maps it to a profile folder
  with the same lookup as §2.8. An unsigned profile can't be identified and
  never moves.
- The `decide` rules differ from §2.8 in one way: a bare `*` catch-all is
  ignored, so unlisted sites stay where they are.
- Only navigations the user started (link click, typed, generated) in normal
  windows are considered. Redirects, back/forward, reloads, form posts and
  popup windows are ignored, so OAuth/SSO flows are never bounced.
- On a move the extension first waits for `open` to succeed, then closes the
  tab if it was freshly opened, or goes back if it navigated away from a page.
- The target profile shows the redirect. On `open` the extension passes the
  source profile's email, target and rule; the app keeps them in memory for 60 s
  (`RedirectLedger`, never on disk). Every fresh tab in any profile asks the host
  `arrived` (the host asks the app, without launching it); a hit turns that
  tab's icon green, and Chrome resets it when the tab navigates. The popup then
  explains it: link as host and path, from which profile, the matching rule
  exactly as written in the config, why, and that the rules live in
  `~/.config/clipb.toml`.
- Otherwise the icon is a plain quiet grey dot with no arrow. Only a failure
  turns it red (popup shows the cause, then it goes grey again).
- A failed host call, an unreadable config or an unknown profile always means
  "stay": the extension never moves a tab on an error.

### 2.10 Pipes (Cmd+Shift+X)

Cut the selection, pipe it through a command from the config, paste the output back.

- Config: `[pipe.<id>]` tables in `~/.config/clipb.toml`, in file order. `run`
  is the command (required). `name` is the label, defaulting to `<id>`. Only
  the first nine pipes are offered. Read on every hotkey press.
- `timeout` is optional: whole seconds before the command is killed, defaulting
  to 600. `0` means no limit — the command runs until it exits on its own, which
  is what an interactive pipe needs (e.g. one that opens an editor in a
  terminal window).
- `hotkey` is optional: one letter (`a-z`, `A-Z`), matched
  case-insensitively. It bound the pipe to Cmd+Shift+<letter>, which ran it on
  a copy with no chooser; Cmd+Shift+C is the screencapture now (§2.11), so the
  key still parses but no chord is registered today. The first pipe in file
  order with a matching `hotkey` wins.
- Hotkey: Cmd+Shift+X, registered system-wide (Carbon). It takes the chord
  from every app, e.g. strikethrough in Slack and Google Docs.
- No pipes or an unparsable config: cut nothing. A notice says `No pipes
  configured` (its hint names `~/.config/clipb.toml`) or `Pipes config
  error`, which also goes to stderr. No beep: the notice is the signal.
- Otherwise ClipB remembers the paste target (§2.5), simulates Cmd+X, and
  waits up to 0.5 s for the pasteboard to change. No change (nothing selected,
  or the app ignores Cmd+X): a notice says `Nothing was cut — nothing
  selected`, nothing else. No Accessibility grant: a notice says `Can't send
  ⌘X — check ClipB in Accessibility settings`. Neither path beeps.
- A cut of a non-text item — an image or a copied file — pipes too: the
  chooser opens the same way and the item's bytes or URL ride stdin, so
  `cat > /tmp/clipb-$(date +%s).png` saves a screenshot to disk. The item is
  filed in history like any copy.
- Chooser: a non-activating panel at the selection's lower edge, like the
  popup (§2.4). When Accessibility cannot locate the selection, it opens at
  the mouse cursor instead. The header shows the cut text on one line,
  truncated to 60 bytes, with a `… (<N> chars)` suffix when it was cut; an
  image cut shows `[image] 1200×800`, a file cut its name. The full value
  never appears elsewhere. One horizontal row of options, the same
  `name ⌘N`-button widget the popup's bottom bar uses (§2.4), so the two
  cannot drift apart, and the hint line `Esc put back` above them. Click a
  button or press its Cmd+digit (1-9): it runs at once; a bare digit still
  works. Esc, a click elsewhere, or the hotkey again puts the text back. With
  exactly one pipe there is no list: it runs at once.
- Run: `$SHELL -l -c <run>` (login shell, so Homebrew's PATH applies), in the
  home directory, the clipboard entry on stdin, stderr discarded. The panel
  shows `Running <name>…` until it ends. Esc cancels and puts the entry back.
  Killed after the pipe's `timeout` seconds; `timeout = 0` never kills it.
- stdin is the entry itself: a text entry sends its bytes, an image entry its
  PNG bytes, a file-ref entry its URLs joined by newlines. Pipes are text
  programs, so a file ref is a URL and an image is raw bytes, not a path.
- Saving the last clipboard item to disk is therefore a pipe — any content:
  the item's bytes land in the temp file and the path rides stdout, so the popup pastes it, e.g. `[pipe.shot]`:
  `run = 'f=$(mktemp /tmp/clipb-XXXXXX); cat > "$f"; echo "$f"'`.
- Result:
  - Exit 0 with output: trailing newlines are dropped, the output is pasted
    in place of the cut text and stored in memory under the pipe's `<id>` as
    its tag, so each pipe's output is reachable in the popup as `#en`. If
    focus cannot be restored at paste time, a notice says the output is on
    the clipboard.
  - Exit 0, no output: the entry stays cut and nothing is pasted, text and
    image alike. Useful for sinks such as `cat >> ~/todo.md` or a screenshot
    pipe that echoes nothing.
  - Non-zero exit, timeout, cancel, or output that is not UTF-8: the original
    entry is pasted back and a notice names the pipe, `Pipe <name> failed — text
    is back`. No beep: the notice is the signal.
- The cut text lands in the history like any copy. Neither text nor output is
  logged or written to disk by ClipB; a command may write wherever it likes.

### 2.11 Screencapture (Cmd+Shift+C)

Shoot a selection, get the image on the clipboard.

- Hotkey: Cmd+Shift+C, registered system-wide (Carbon). While the popup
  (§2.4) or the pipe chooser is open the chord does nothing. A capture already
  in flight is not stacked: the second press is ignored.
- ClipB waits for the chord's Shift and C to be released, then runs
  `/usr/sbin/screencapture -i -c` on a background queue — the crosshair
  blocks and the main thread stays free for the popup, the menu and the
  timers. `-i` is interactive selection, `-c` writes the result straight to
  the clipboard; the capture writes no file. Esc at the crosshair is a
  quiet no-op. No `-x`, so the usual capture sound still plays.
- ClipB does not write the pasteboard: the system tool does. The watcher's
  500 ms poll then sees the new image and files it in history like any copy
  (§2.1), so it shows up in the popup as `[image] 1200×800` and pastes into
  any image target. No notice, no beep: the clipboard is the signal.
- Screen Recording permission may be needed for the child process. A denied or
  failed capture (non-zero exit) shows a notice, `Can't capture the screen —
  check Screen Recording in Privacy & Security`. The clipboard, the selection
  and the history are untouched, and nothing beeps.
- Sending the shot to a file is a pipe (§2.10), not a capture mode:
  `[pipe.shot] run = 'f=$(mktemp /tmp/clipb-XXXXXX); cat > "$f"; echo "$f"'`
  writes the PNG bytes from the clipboard entry and pastes back the path.
- CLI: `clipb shot` runs the same capture and exits immediately. Exit codes:
  0 captured, 1 no capture (`clipb: no capture — check Screen Recording in
  Privacy & Security` on stderr), 2 usage. Nothing is printed: the image is on
  the clipboard.
- The pipe `hotkey` key (§2.10) parses, but no letter is registered today:
  Cmd+Shift+C is this capture.

## 3. Non-functional requirements

- Bundle: `ClipB.app`, identifier `com.productmind.clipb`, `LSUIElement = true`.
- Idle footprint: negligible CPU (change-count poll, no content reads),
  a few MB of RAM.
- No crashes on: empty clipboard, huge values, rapid copy bursts,
  concurrent hotkey presses.
- Single instance: a launch probes the IPC socket and exits without touching
  it when a live instance keeps answering; an instance that was just told to
  quit (dev handoff) or a leftover socket file from a crash does not block
  startup (the file is unlinked and rebound).
- Ad-hoc codesign the bundle with the designated requirement pinned to the
  bundle identifier, so the Accessibility grant survives rebuilds.

## 4. Architecture

Swift + AppKit, SwiftPM executable target, all state on the main thread.

| Concern | Where |
|---|---|
| History model (push/dedupe/evict/obfuscate) | `ClipboardHistory.swift` (pure, tested) |
| Title rendering + UTF-8-safe truncation | `Titles.swift` (pure, tested) |
| Pasteboard polling + writing | `ClipboardWatcher.swift` |
| Global hotkeys (Cmd+Shift+V, Cmd+Shift+X, Cmd+Shift+C) | `HotKey.swift` (Carbon) |
| Paste simulation + Accessibility | `Paste.swift` |
| Hotkey popup (search panel) | `HistoryPanel.swift` |
| Popup entry list + `#tag`/`#source` search | `HistoryFilter.swift` (pure, tested) |
| Fuzzy matching | `FuzzyMatch.swift` (pure, tested) |
| Full-screen screencapture to the clipboard | `Shot.swift` (tested) |
| `clipb copy` / `clipb shot` clients, socket server, wire format | `CopyCommand.swift`, `ShotCommand.swift`, `IPCServer.swift`, `IPC.swift` |
| TOML subset parser | `TOML.swift` (pure, tested) |
| Router rules, glob matching, Chromium profile lookup | `Router.swift` (pure, tested) |
| Opening links in the chosen browser/profile | `BrowserLauncher.swift` |
| Chrome extension decision, native host, host installer | `ExtensionRouting.swift` (pure, tested), `NativeHost.swift` |
| Chrome extension (MV3) | `extension/chrome/` |
| Pipe config, stdin payload, result rules | `Pipes.swift` (pure, tested) |
| Running a pipe command | `PipeRunner.swift` (tested) |
| Pipe chooser panel | `PipeChooser.swift` |
| Pipe options state (digits, labels, running label) | `PipeStrip.swift` (pure, tested) |
| Pipe option widget (buttons; digits optional, chooser only) | `PipeOptionsRow.swift` |
| Tray menu, wiring, link delivery | `AppDelegate.swift` |
| Entry point | `main.swift` |

## 5. Acceptance checklist

- [ ] Copy 3 strings → all 3 in tray menu and Cmd+Shift+V popup, newest first.
- [ ] Copy a duplicate → no new row; entry moves to the top.
- [ ] With an iTerm2 hotkey window up, Cmd+Shift+V → the window stays visible.
- [ ] `echo hi | clipb copy --tag t` → typing `#t` in the popup filters down to `hi`.
- [ ] Tab / Shift+Tab do nothing in the popup; tray `Clear “t”` empties just that tag.
- [ ] Hover a popup row → its buttons appear in that row's pills' place (the pills hide) and only on that row, also after scrolling; ✕ → entry gone, popup stays open.
- [ ] Row buttons: copy puts the value on the clipboard without pasting; obfuscate masks the row and the icon flips to show; open appears only on URL entries and opens them in the profile the config picks.
- [ ] Cmd+Delete in the popup deletes the selected entry; so does right-clicking a row.
- [ ] Type in the popup → list filters; Enter picks the top match.
- [ ] Tag and source pills: `echo hi | clipb copy --tag t` → the row shows `#t`; copying in Safari shows `#Safari`; an untagged, sourceless row shows neither.
- [ ] Entries from different tags interleave in true recency order, not tag by tag.
- [ ] Type `#q` → only rows whose tag or source fuzzily matches `q` remain; `#saf` finds Safari entries; `#t #saf` needs both; a `#` token never matches a row with neither tag nor source; `#t alp` narrows to that tag's `alpha` matches.
- [ ] With `[pipe.en] name = "English" run = "tr a-z A-Z"` in the config, Cmd+Shift+V → a rounded `English ⌘1` button sits at the very bottom (the key in the name's ink, monospaced digits) and the hint line `⏎ paste · ⇧⏎ paste & delete · ⌫ delete · ⌘H hide` sits just above it; clicking it (or pressing `⌘1`) immediately uppercases the highlighted entry, pastes it, and the popup shows it under `#en`. Plain Enter pastes without piping.

- [ ] With pipes configured, Esc during a run cancels it and the buttons come back; the next Esc closes the popup.
- [ ] With `[pipe.en]` and `[pipe.quote]` configured, pressing `⌘2` runs `quote` on the highlighted entry and the query stays empty; typing `3.11` types those digits and filters on them, in the popup and with no pipes alike.
- [ ] With no `[pipe.*]` tables → no bottom row, `|` is typed as an ordinary character, and typing `3.11` → the query holds `3.11` and the list filters on it.
- [ ] While the popup is open, Cmd+Shift+X and Cmd+Shift+C do nothing: no cut, no chooser, no capture, no clipboard change.
- [ ] Shift+Enter on an entry → it is pasted and gone from history; 2 s after the paste the clipboard no longer holds it. Copy something else in between → that value survives. With focus unrestorable (e.g. target window closed) → beep, the entry stays in history and on the clipboard.
- [ ] Shift+Enter on a tag's last entry → its `#tag` pill disappears and `#tag` matches nothing.
- [ ] Popup select → value on clipboard; with Accessibility granted it pastes itself.
- [ ] Obfuscate → `abcd****…` in tray and popup; Copy still yields the full value.
- [ ] Copy `Příliš žluťoučký kůň 🐴` → round-trips byte-identical.
- [ ] Clear empties the menu; Quit exits; relaunch starts with empty history.
- [ ] `lsof -i -p <pid>` on the running app shows no TCP/UDP sockets.
- [ ] `echo hi | clipb copy --tag t` → exit 0; `ls -l ~/.clipb` shows `0700`/`0600`.
- [ ] Quit ClipB, run `echo hi | clipb copy` → ClipB launches and takes it.
- [ ] System Settings → Default web browser lists ClipB; pick it.
- [ ] `clipb install-native-host` writes the manifest; load `extension/chrome` unpacked in a profile.
- [ ] In the personal profile open a work-rule URL in a new tab → the tab closes and the URL opens in the work profile; a link clicked inside a page returns the tab to that page.
- [ ] In the work profile the arrived tab's icon is green; clicking it shows the link, the source profile, the rule and `~/.config/clipb.toml`. Navigating the tab away restores the grey dot.
- [ ] On ordinary pages the icon is a plain grey dot with no arrow.
- [ ] Unlisted sites and login redirects never move.
- [ ] `clipb route <url>` prints the expected profile folder for a rule's URL and opens nothing.
- [ ] With a config installed, `open <url>` opens in that rule's Chrome profile, also while Chrome is already running.
- [ ] That link appears among the popup's `#link` entries; the system clipboard is unchanged.
- [ ] `open https://example.org` → matches `"*"`; with the config removed → Safari.
- [ ] With no `"*"` rule, a link matching no rule shows the chooser.
- [ ] Chooser → `Remember for:` → `a.b.example.com`, pick a profile: `~/.config/clipb.toml` gains `"a.b.example.com" = "chrome:<email>"` above `"*"`; the next link to that host opens there.
- [ ] Remember `https://x.example.com/oauth/authorize?x=1`, option 3: the rule is `"https://x.example.com/oauth/*"`; the query is absent from the file.
- [ ] With `[router]` pointing at a missing browser (`"*" = "nosuchbrowser"`), the chooser shows the problem line and `Continue anyway`; no Remember section.
- [ ] Config file renamed away: the chooser shows `Can't read ~/.config/clipb.toml`, no beep, no Safari open.
- [ ] With `"*" = "ask"`, `open https://example.org` shows the chooser with `example.org` only; digit 1 opens it in the first profile, Esc closes it and opens nothing.
- [ ] With `[pipe.upper] run = "tr a-z A-Z"`, select `hello` in TextEdit, Cmd+Shift+X → the chooser opens just under the selected text and its header shows `hello`; press `⌘1` (or a bare `1`) → `HELLO` replaces it; typing `#upper` in the popup shows `HELLO`.
- [ ] With Accessibility unavailable, or in an app AX cannot read, Cmd+Shift+X opens the chooser at the mouse cursor instead of the selection.
- [ ] Cmd+Shift+X, then Esc → the selection comes back.
- [ ] A pipe with `run = "exit 1"` → the original text is pasted back and a `Pipe <name> failed — text is back` notice appears.
- [ ] Cmd+Shift+C → the crosshair appears, a dragged region is captured with the usual sound, the image lands on the clipboard, and the popup shows it as `[image] WxH`; Esc at the crosshair → quiet no-op, clipboard unchanged; no beep, no notice.
- [ ] Cmd+Shift+C with Screen Recording denied → a `Can't capture the screen — check Screen Recording in Privacy & Security` notice; the clipboard and history are unchanged.
- [ ] `clipb shot` → exit 0, nothing on stdout or stderr; the clipboard holds the screenshot and `pbpaste -Prefer png > /tmp/x.png` writes it.
- [ ] `clipb shot` with Screen Recording denied → exit 1, stderr says `clipb: no capture — check Screen Recording in Privacy & Security`.
- [ ] `[pipe.shot] run = 'f=$(mktemp /tmp/clipb-XXXXXX); cat > "$f"; echo "$f"'` → Cmd+Shift+C, then the popup's `⌘N` on the image row writes the bytes to `/tmp` and pastes the path.
- [ ] `[pipe.quote] hotkey = "c"` in the config → parses, no chord is registered for it, and the popup's pipe buttons still work.
- [ ] Cmd+Shift+X on an image in Google Docs → the chooser opens, its header reads `[image] 1200×800`, and a `run = "cat > /tmp/x.png"` pipe saves the PNG bytes there; Esc puts the image back.
- [ ] A pipe with `run = "cat >> /tmp/todo.md"` → the text leaves the app and is appended to the file.
- [ ] No `[pipe.*]` tables → Cmd+Shift+X shows `No pipes configured`, no beep, and cuts nothing.
- [ ] An unparsable config → Cmd+Shift+X shows `Pipes config error` (plus the reason on stderr), no beep, nothing cut.
- [ ] Cmd+Shift+X with nothing selected → `Nothing was cut — nothing selected` notice, no beep.
- [ ] Accessibility revoked → Cmd+Shift+X shows `Can't send ⌘X — check ClipB in Accessibility settings`, no beep.
- [ ] `[pipe.quote] hotkey = "c" run = "sed 's/^/> /'"` → parses and still runs from the chooser and the popup button; no chord is registered for it.
- [ ] Copy text in Safari, then in Slack → the popup rows show `Safari` and `Slack` pills.
- [ ] Copy an image in Safari → the tray and popup show `[image] 1200×800`; selecting it pastes the image into a target app; copying a second image keeps both.
- [ ] Copy 11 images → the oldest image entry is gone, 10 remain; an image over 8 MB is not captured.
- [ ] Copy a file in Finder → the row shows `[file] Report.pdf`; selecting it pastes the file ref; a folder copies the same way.
- [ ] Highlight an image row and press `⌘1` (or click a pipe button) with `run = "cat > /tmp/x.png"` → the PNG bytes land in the file, nothing is pasted, the popup closes; Enter still pastes the image.
- [ ] `make` (dev build) → restart ClipB and the image/file rows are still there, image bytes included.
