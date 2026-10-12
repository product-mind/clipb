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
   local Unix-domain socket for `clipb copy` (§2.7).
4. It is not a password manager.

Development exception: a build compiled with `-DDEV_PERSIST` (`make`)
saves history to a file on exit and reloads it on launch. Release builds
(`make release`) contain no such code.

## 2. Features

### 2.1 Clipboard monitoring

- Poll `NSPasteboard.changeCount` every 500 ms; read contents only on change.
- Only plain text is captured (images/files are out of scope for v1).
- New values are trimmed of surrounding whitespace. Empty values are ignored.
- Duplicate of an existing entry: move it to the front of the recency order
  instead of adding a second entry. Its obfuscation state is preserved.
- Capacity: 100 entries. When full, the oldest entry is evicted.

### 2.2 Menu bar (tray) menu

- Template (monochrome) clipboard icon; tooltip "Clipboard".
- Menu contents, top to bottom: disabled `ClipB` title, `Quit`, one Clear
  item per tab, separator, one row per uncategorized entry (newest first).
  Without tags the single item is `Clear`. With tags each item is
  `Clear “<tab>” (<N>)`, `Clipboard` being the uncategorized tab. Each item
  clears only its own tab, so a casual Clear never wipes tagged entries.
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
- A search field on top filters entries by case-insensitive subsequence
  match and ranks them best first: an entry containing the whole query
  beats scattered matches, longer runs of adjacent matched characters and
  word starts score higher, and ties keep recency order. Enter picks the top.
  Obfuscated entries match on their masked title, never their value.
  While the query is non-empty each tab label shows its match count, e.g.
  `link (2)`, so matches on other tabs are visible without leaving this one.
- Tabs: once any tag exists, a tab bar appears: `Clipboard` (uncategorized)
  first, then one tab per tag sorted by name. The first tab with entries is
  selected. Tab / Shift+Tab or a click switches tabs; search applies to the
  current tab. Without tags there is no tab bar.
- Each row shows action buttons only while the pointer is over it (also while
  scrolling), left to right:
  - open: only when the value is exactly one http(s) URL; routes it through the
    link router (§2.8) and closes the popup;
  - copy: puts the value on the clipboard without pasting and closes the popup;
  - obfuscate / show: toggles obfuscation, the popup stays open;
  - ✕: deletes the entry, the popup stays open. Cmd+Delete always deletes the selected entry.
  Delete (or forward Delete with the caret at the end) deletes it once the
  search text is empty, but not on key repeat and not within 0.4 s of the
  last edit, so clearing the query never eats entries.
- Right-clicking a row deletes that entry, like the ✕ button.
- Keys: Up/Down move the selection, Enter selects, Esc closes.
- Popup titles: newlines flattened to spaces, truncated to 60 bytes without
  splitting a character, suffixed `... (<N> chars)` when truncated.
  Obfuscated entries render obfuscated.
- Selecting an entry writes the full value to the clipboard, then simulates
  Cmd+V in the previously focused application.
- Dismissing (Esc / click outside / losing key status) does nothing.
- Pressing the hotkey while the popup is open closes it.

### 2.5 Paste simulation and permissions

- Simulated Cmd+V (CGEvent) requires macOS Accessibility permission.
- First run prompts for it (`AXIsProcessTrustedWithOptions`).
- Graceful degradation: without the permission the value is still on the
  clipboard — the user pastes manually.
- Paste target: on hotkey press, remember the frontmost app plus its focused
  window and field (Accessibility). On select, bring that app back to the
  front (even if the user switched away), refocus the window and field, then
  paste. If the app never comes forward, nothing is pasted and it beeps. A
  missing permission beeps instead of failing silently.

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
- Tags are kept in the history, per tag, with the same eviction rules. Each
  tag is a tab in the hotkey popup (§2.4).
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

- History: each link is pushed in memory under the tag `link` (a tab in the
  popup). It is never written to the system pasteboard, so the user's
  current clipboard survives.
- Config: `~/.config/clipb.toml`, a TOML subset (tables, string /
  integer / boolean values, `#` comments). Parsed once and cached; re-read when the file's mtime or size changes, so edits apply to the next link without a restart.
  Sample: `examples/config.toml`. Unknown sections are ignored.
- `clipb route <url>` is a dry run: it prints the browser and profile folder
  the config would pick and opens nothing.
- `[router]`: ordered `"pattern" = "target"` rules, first match wins.
  - Pattern containing `://`: glob on the full URL.
  - Pattern with `*` or `:`: glob on the host (`host:port` if it has a colon).
  - Plain domain: that host and all its subdomains. `*.x.com` needs a subdomain.
  - `*` matches any run of characters, including `/`. Case-insensitive.
- Target: `browser` or `browser:profile`. Browsers: `chrome`, `brave`, `edge`,
  `safari`, `firefox`, or a raw bundle id. Only Chromium browsers take a profile.
- `[profiles]`: optional aliases, `"chrome:personal" = "chrome:me@example.com"`.
- Profile resolution reads Chromium's `Local State` at click time and matches
  the signed-in email, then the display name, then the folder name. The config
  never holds folder numbers, so it can be shared between machines.
- Launch: with a profile, `--profile-directory=<folder> <url>` through a new
  application instance (like `open -n`); otherwise a plain open.
- Fallbacks, so a link is never lost: no matching rule, an unreadable config
  (beeps), an unknown or missing browser → Safari. A profile that matches
  nothing → the browser's default profile. A target that is ClipB itself is
  never used.
- Non-`http(s)` URLs (HTML files) go to Safari and are not recorded.

## 3. Non-functional requirements

- Bundle: `ClipB.app`, identifier `com.productmind.clipb`, `LSUIElement = true`.
- Idle footprint: negligible CPU (change-count poll, no content reads),
  a few MB of RAM.
- No crashes on: empty clipboard, huge values, rapid copy bursts,
  concurrent hotkey presses.
- Single instance: on launch, terminate other running instances with the
  same bundle identifier.
- Ad-hoc codesign the bundle with the designated requirement pinned to the
  bundle identifier, so the Accessibility grant survives rebuilds.

## 4. Architecture

Swift + AppKit, SwiftPM executable target, all state on the main thread.

| Concern | Where |
|---|---|
| History model (push/dedupe/evict/obfuscate) | `ClipboardHistory.swift` (pure, tested) |
| Title rendering + UTF-8-safe truncation | `Titles.swift` (pure, tested) |
| Pasteboard polling + writing | `ClipboardWatcher.swift` |
| Global hotkey | `HotKey.swift` (Carbon) |
| Paste simulation + Accessibility | `Paste.swift` |
| Hotkey popup (search panel) | `HistoryPanel.swift` |
| Fuzzy matching | `FuzzyMatch.swift` (pure, tested) |
| `clipb copy` client, socket server, wire format | `CopyCommand.swift`, `IPCServer.swift`, `IPC.swift` |
| TOML subset parser | `TOML.swift` (pure, tested) |
| Router rules, glob matching, Chromium profile lookup | `Router.swift` (pure, tested) |
| Opening links in the chosen browser/profile | `BrowserLauncher.swift` |
| Tray menu, wiring, link delivery | `AppDelegate.swift` |
| Entry point | `main.swift` |

## 5. Acceptance checklist

- [ ] Copy 3 strings → all 3 in tray menu and Cmd+Shift+V popup, newest first.
- [ ] Copy a duplicate → no new row; entry moves to the top.
- [ ] With an iTerm2 hotkey window up, Cmd+Shift+V → the window stays visible.
- [ ] `echo hi | clipb copy --tag t` → a `t` tab appears in the popup with `hi`.
- [ ] Tab / Shift+Tab switches tabs; tray `Clear “t”` empties just that tab.
- [ ] Hover a popup row → its buttons appear, and only on that row, also after scrolling; ✕ → entry gone, popup stays open.
- [ ] Row buttons: copy puts the value on the clipboard without pasting; obfuscate masks the row and the icon flips to show; open appears only on URL entries and opens them in the profile the config picks.
- [ ] Cmd+Delete in the popup deletes the selected entry; so does right-clicking a row.
- [ ] With two tabs, typing a query shows `Clipboard (n)` / `link (n)` counts; clearing it restores plain names.
- [ ] Type in the popup → list filters; Enter picks the top match.
- [ ] Dev build: select, then switch to another app within 1 s → the text still
  lands in the original window and field (the 1 s delay is temporary).
- [ ] Popup select → value on clipboard; with Accessibility granted it pastes itself.
- [ ] Obfuscate → `abcd****…` in tray and popup; Copy still yields the full value.
- [ ] Copy `Příliš žluťoučký kůň 🐴` → round-trips byte-identical.
- [ ] Clear empties the menu; Quit exits; relaunch starts with empty history.
- [ ] `lsof -i -p <pid>` on the running app shows no TCP/UDP sockets.
- [ ] `echo hi | clipb copy --tag t` → exit 0; `ls -l ~/.clipb` shows `0700`/`0600`.
- [ ] Quit ClipB, run `echo hi | clipb copy` → ClipB launches and takes it.
- [ ] System Settings → Default web browser lists ClipB; pick it.
- [ ] `clipb route <url>` prints the expected profile folder for a rule's URL and opens nothing.
- [ ] With a config installed, `open <url>` opens in that rule's Chrome profile, also while Chrome is already running.
- [ ] That link appears in a `link` tab of the popup; the system clipboard is unchanged.
- [ ] `open https://example.org` → matches `"*"`; with the config removed → Safari.
