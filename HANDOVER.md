# ClipB handover: link router, Chrome extension, popup actions

State when written: branch `link-router`, not pushed, not merged to `master`.
`make test` passes (110 tests). The Chrome parts were tested by hand in one
profile only. Read `SPEC.md` (§2.8, §2.9) and `CLAUDE.md` first; they are the
source of truth. This file is the story and the open items.

## What was built

### 1. Link router (ClipB as the default browser)

macOS hands every link clicked outside a browser to the default browser.
ClipB registers for `http(s)` (`appInfo/Info.plist`), receives them in
`AppDelegate.application(_:open:)`, records each under the `link` tab (memory
only, never the system pasteboard) and opens it in the browser and Chrome
profile the config picks.

- Config: `~/.config/clipb.toml`, a TOML subset parsed by our own
  `TOML.swift` (no dependencies). Sample: `examples/config.toml`.
- `[router]` is a flat ordered map, `"pattern" = "target"`, first match wins.
  - Pattern with `://`: glob on the full URL. With `*` or `:`: glob on the host
    (`host:port` if it has a colon). A plain domain matches itself and all
    subdomains; `*.x.com` needs a subdomain.
  - Target: `browser` or `browser:profile`. Browsers: chrome, brave, edge,
    safari, firefox, or a bundle id. `[profiles]` holds optional aliases.
- A Chromium profile is named by its signed-in email (then display name, then
  folder). Resolved at click time from Chrome's `Local State`
  (`profile.info_cache.<folder>.user_name`). This is why the config can be
  shared between machines whose profile folders differ.
- The config is parsed once and re-read when its mtime or size changes
  (`RouterConfigCache`).
- Fallbacks: no rule, broken config (beeps) or unknown browser goes to Safari;
  an unmatched profile goes to the browser's default profile; ClipB is never
  its own target.
- `clipb route <url>` is a dry run: prints the browser and profile folder,
  opens nothing.

### 2. Popup changes (Cmd+Shift+V)

- While searching, each tab label shows its match count, e.g. `link (2)`.
- Hover buttons per row: open (single http(s) URLs, through the router), copy
  without pasting, obfuscate/show, delete. Right-click deletes.
- The 1 s dev-only paste delay was removed.

### 3. Chrome extension (`extension/chrome/`, MV3)

Covers links clicked inside Chrome, which the default-browser hook never sees.
The extension holds no rules. It calls `clipb` as a Native Messaging host.

```
extension ──(stdin/stdout frames)──► clipb (host) reads ~/.config/clipb.toml
   op decide   → move or stay, reason, target, rule text
   op open     → host sends the URL over ~/.clipb/clipb.sock to the app,
                 which records it and routes it (BrowserLauncher)
   op arrived  → "was this link just redirected here?" (asks the app)
```

- Profile identity: `chrome.identity.getProfileUserInfo()` returns the signed-in
  email; the host maps it to a folder with the same lookup as the router. An
  unsigned profile can't be identified and never moves.
- Rules differ from the router in one way: a bare `*` catch-all is ignored, so
  unlisted sites are not ejected from the profile they are in.
- Only user-started navigations in normal windows count (link, typed,
  generated, keyword). Redirects, back/forward, reloads, form posts and popups
  are ignored so OAuth/SSO flows don't bounce.
- On a move: ClipB opens the URL in the target profile first, then the extension
  closes the fresh tab, or goes back if it left a page. Any error means "stay".
- Target profile feedback: `RedirectLedger` keeps moved links in memory for
  60 s. Every fresh tab asks the host `arrived`; a hit turns that tab's icon
  green. The popup explains it (link as host and path, source profile, the rule
  as written, why, and `~/.config/clipb.toml`). Idle icon is a plain grey dot;
  only a failure turns it red.
- Extension id is pinned by the `key` in `manifest.json`:
  `hiimoliolcnghhceefngpikhdkglecnp`. It is mirrored in
  `NativeHostInstaller.devExtensionID`. Change both together.

## Run it

1. `make` (rebuild, relaunch). `make test` runs the unit tests.
2. `make install-cli`, then `clipb install-native-host`. This writes
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.productmind.clipb.json`
   (path to the app binary; rerun after moving the app).
3. `chrome://extensions` → Developer mode → Load unpacked → `extension/chrome`,
   once per profile. Reload the extension after code changes.
4. System Settings → Desktop & Dock → Default web browser → ClipB.
5. Real config: `~/.config/clipb.toml` (kept outside the repo; it holds real
   emails and internal hosts). It was generated from the old SwitchBar JSON,
   grouped by profile aliases, golang.cz first so its GitHub URLs beat plain
   `github.com`.

Claude Code sandbox note: `swift test`, `git commit` and `make` need the Bash
sandbox off. Launching apps (`open`) is blocked inside it.

## Verified and not verified

- Verified: unit tests, including a real Unix socket round trip for the
  `arrived` query; the native host driven by hand over stdin/stdout against the
  real config and Chrome profile data; the router resolving the right folder
  for sample URLs.
- Verified by the user: a link opened in the Personal profile moved to the
  golang.cz profile.
- Not verified: the green per-tab icon and popup in Chrome (relies on Chrome
  resetting tab icons on navigation), `goBack` after an in-page click,
  per-navigation cost of starting the host, the default-browser picker on a
  clean machine.

## Known limits

- Tab flash: the tab opens, then closes. Chrome's extension model offers no way
  to pause a navigation for a native answer.
- Single-page sites (GitHub): in-site link clicks use the history API and don't
  trigger the check. New tabs, typed URLs and cross-site clicks do.
- One manual install per Chrome profile. Chrome only, not Brave/Edge.
- `Local State` is an undocumented format; both sides fail safe if it changes.

## Auto-install research (why it is manual)

- Force-install for all profiles is Chrome's `ExtensionInstallForcelist` policy.
  On this Mac it comes from the MDM (`/Library/Managed Preferences/com.google.Chrome.plist`,
  an extension that is probably Malwarebytes). Root-owned; IT would have to add
  ours, and it needs a Web Store listing.
- Apps like Claude drop `<id>.json` with `external_update_url` into
  `~/Library/Application Support/Google/Chrome/External Extensions/`. Web Store
  extensions only, and Chrome asks the user to enable them.
- `--load-extension` is removed in branded Chrome 137+; local `.crx` installs
  are blocked on macOS. Unpacked can't be automated.
- Sources: <https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions>,
  <https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ>.

## Before shipping to customers

1. Developer ID signing and notarization (the app is ad-hoc signed).
2. Web Store listing; add its id to the host manifest (`--extension-id`).
3. In-app "Enable Chrome extension" that writes the host manifest, and rewrites
   it on every launch (app moves, App Translocation).
4. First-run config and a safe default; with no config every link goes to Safari.
5. Handle single-page navigations; measure host latency; Brave/Edge hosts.

## Deferred ideas

- Popup: preview pane first (plain AppKit `NSTextView`, never show an obfuscated
  value), then side-by-side columns. SwiftUI only as a hybrid for the columns;
  not a WebView (network rule, memory, focus). Auto-jump to the first tab with
  matches.
- From the original sketch: `[clipboard]`, `[pipe]` (LLM transform on a hotkey),
  `[voice]`, `[shortcuts]`. Unknown config sections are already ignored.
