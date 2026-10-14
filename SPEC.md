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

- Poll `NSPasteboard.changeCount` every 500 ms; read contents only on change.
- Only plain text is captured (images/files are out of scope for v1).
- New values are trimmed of surrounding whitespace. Empty values are ignored.
- Duplicate of an existing entry: move it to the front of the recency order
  instead of adding a second entry. Its obfuscation state is preserved.
- Capacity: 100 entries. When full, the oldest entry is evicted.
- Source app: each entry remembers the app it was copied from, in memory
  only. ClipB uses the `org.nspasteboard.source` marker when the app sets it,
  else the frontmost app at poll time (a best guess within the 500 ms poll).
  A duplicate takes the new source. ClipB's own writes keep the old one.
  Pipe outputs (§2.10) take the app the text was cut from.

### 2.2 Menu bar (tray) menu

- Template (monochrome) clipboard icon; tooltip "Clipboard".
- Menu contents, top to bottom: disabled `ClipB` title, `Quit`, one Clear
  item per tab, separator, one row per uncategorized entry (newest first).
  Without tags the single item is `Clear`. With tags each item is
  `Clear “<tab>” (<N>)`, `⌘C` being the uncategorized tab. Each item
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
  The source app (pill) is searched too: `slack` finds entries copied from Slack.
  While the query is non-empty each tab label shows its match count, e.g.
  `link (2)`, so matches on other tabs are visible without leaving this one.
- Tabs: once any tag exists, a tab bar appears: `⌘C` (uncategorized)
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
- Each row with a known source shows the app name as a small pill right of
  the title, left of the hover buttons. Also on obfuscated rows: it is not
  the value.
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
- Chooser: a small centered panel that never takes focus from the frontmost app.
  - Header: `Open in:` and the link's host only. The full URL is never shown,
    since SAML and OAuth URLs carry secrets.
  - Options: one button per Chrome profile, then Safari. Profiles come from
    Chrome's `Local State`: `Default` first, then by folder name. The label is
    the profile's display name, or its folder when the name is empty.
  - At most nine options. Safari is always last, so at most eight profiles show.
  - Click a button, or press its digit (1-9), to open the link there.
  - Esc, or clicking away, closes it. Nothing opens. The link stays in the
    popup's `link` tab.
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
- Hotkey: Cmd+Shift+X, registered system-wide (Carbon). It takes the chord
  from every app, e.g. strikethrough in Slack and Google Docs.
- No pipes or an unparsable config: beep and cut nothing.
- Otherwise ClipB remembers the paste target (§2.5), simulates Cmd+X, and
  waits up to 0.5 s for the pasteboard to change. No change (nothing selected,
  or the app ignores Cmd+X, or no Accessibility grant): beep, nothing else.
- Chooser: a centered non-activating panel, like the router chooser (§2.8).
  Header `Pipe <N> chars through:`, never the text itself. One row per pipe.
  Click it or press its digit (1-9). Esc, a click elsewhere, or the hotkey
  again puts the text back. With exactly one pipe there is no list: it runs
  at once.
- Run: `$SHELL -l -c <run>` (login shell, so Homebrew's PATH applies), in the
  home directory, text on stdin, stderr discarded. The panel shows
  `Running <name>…` until it ends. Esc cancels and puts the text back.
  Timeout 30 s.
- Result:
  - Exit 0 with output: trailing newlines are dropped, the output is pasted
    in place of the cut text and stored in memory under the pipe's `<id>` as
    its tag, so each pipe gets its own popup tab (`[pipe.en]` → `en`).
  - Exit 0, no output: the text stays cut. Useful for sinks such as
    `cat >> ~/todo.md`.
  - Non-zero exit, timeout, cancel, or output that is not UTF-8: beep, the
    original text is pasted back.
- The cut text lands in the history like any copy. Neither text nor output is
  logged or written to disk by ClipB; a command may write wherever it likes.

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
| Global hotkeys (Cmd+Shift+V, Cmd+Shift+X) | `HotKey.swift` (Carbon) |
| Paste simulation + Accessibility | `Paste.swift` |
| Hotkey popup (search panel) | `HistoryPanel.swift` |
| Fuzzy matching | `FuzzyMatch.swift` (pure, tested) |
| `clipb copy` client, socket server, wire format | `CopyCommand.swift`, `IPCServer.swift`, `IPC.swift` |
| TOML subset parser | `TOML.swift` (pure, tested) |
| Router rules, glob matching, Chromium profile lookup | `Router.swift` (pure, tested) |
| Opening links in the chosen browser/profile | `BrowserLauncher.swift` |
| Chrome extension decision, native host, host installer | `ExtensionRouting.swift` (pure, tested), `NativeHost.swift` |
| Chrome extension (MV3) | `extension/chrome/` |
| Pipe config and result rules | `Pipes.swift` (pure, tested) |
| Running a pipe command | `PipeRunner.swift` (tested) |
| Pipe chooser panel | `PipeChooser.swift` |
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
- [ ] With two tabs, typing a query shows `⌘C (n)` / `link (n)` counts; clearing it restores plain names.
- [ ] Type in the popup → list filters; Enter picks the top match.
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
- [ ] That link appears in a `link` tab of the popup; the system clipboard is unchanged.
- [ ] `open https://example.org` → matches `"*"`; with the config removed → Safari.
- [ ] With no `"*"` rule, a link matching no rule shows the chooser.
- [ ] Chooser → `Remember for:` → `a.b.example.com`, pick a profile: `~/.config/clipb.toml` gains `"a.b.example.com" = "chrome:<email>"` above `"*"`; the next link to that host opens there.
- [ ] Remember `https://x.example.com/oauth/authorize?x=1`, option 3: the rule is `"https://x.example.com/oauth/*"`; the query is absent from the file.
- [ ] With `[router]` pointing at a missing browser (`"*" = "nosuchbrowser"`), the chooser shows the problem line and `Continue anyway`; no Remember section.
- [ ] Config file renamed away: the chooser shows `Can't read ~/.config/clipb.toml`, no beep, no Safari open.
- [ ] With `"*" = "ask"`, `open https://example.org` shows the chooser with `example.org` only; digit 1 opens it in the first profile, Esc closes it and opens nothing.
- [ ] With `[pipe.upper] run = "tr a-z A-Z"`, select `hello` in TextEdit, Cmd+Shift+X, press 1 → `HELLO` replaces it; the popup has an `upper` tab with `HELLO`.
- [ ] Cmd+Shift+X, then Esc → the selection comes back.
- [ ] A pipe with `run = "exit 1"` → beep, the original text is pasted back.
- [ ] A pipe with `run = "cat >> /tmp/todo.md"` → the text leaves the app and is appended to the file.
- [ ] No `[pipe.*]` tables → Cmd+Shift+X beeps and cuts nothing.
- [ ] Copy text in Safari, then in Slack → the popup rows show `Safari` and `Slack` pills.
