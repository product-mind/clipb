# ClipB modals: controls and decisions

What every ClipB panel shows, which keys do what, and **why**. `SPEC.md` is
the full behavior spec; this file records the decisions behind the modals so
they survive the session that made them. Change a decision here and in
`SPEC.md` together.

## The one editor panel

One panel serves three entry points. They look the same on purpose: the user
learns one modal.

| Entry | Opens with | Save goes to |
|---|---|---|
| Hold **⌘C** (dictation) | empty, caret blinking, grey `Listening…` | clipboard + pasted back into the field you came from, tag `voice` |
| **⌘⇧X** (cut) | the cut text, caret at the end | pasted back where it was cut, tag `edit` |
| **⌘⇧E** (edit) | the cut text, with its one-line title | pasted back, tag `edit` |

⌘⇧X used to open a list of pipes; it now opens this editor so cut, dictate
and edit are one experience. An image or file cut still gets the old pipe
list: there is no text to edit.

### Layout, top to bottom

1. **No title** in the dictation and ⌘⇧X panels: the text area says what it
   is. Only ⌘⇧E keeps its one-line title (the cut text). A running pipe shows
   `Running <name>…` at the top.
2. **Button strip**: `B` `I` `<>` `⊞` `MD` | `↶` `↷` | `⌕` `⇄` | `>` `<<` `>>`.
   Drawn as semibold SF Symbols (bold, italic, `</>`, table, undo/redo
   U-turn arrows, magnifier, ⇄, quote, the decrease/increase-indent icons Word
   and Docs use) on narrow 30 pt toolbar-bezel buttons: the user found the thin
   text glyphs unreadable and `<<` `>>` unclear. `MD` stays a bold word. The
   characters above remain the fallback when a symbol is missing.
3. **Text area**, ~84 monospaced columns (660 pt), lines wrap at the visible
   edge, never scroll sideways.
4. **Footer**: pipe buttons (`name ⌘N`) on the left, then a round **`?`**
   and **`Paste ⌘V`** on the right. **Clicking** `?` shows the keys (save,
   dictate, pipes, formatting, find, undo) as small grey text under the
   footer; the panel grows downward. Click again to hide. Not a hover
   tooltip: the user wanted it to stay put and read. It stays shown across
   panels until turned off (memory only).
5. **No key hint line.** It used to sit under the text; the user found it
   redundant, so the keys moved behind `?`. The line returns only to report a
   broken pipes config.

Everything is there from the first moment, also while listening, so nothing
jumps when the transcript lands. Buttons that need text do nothing until it
is there.

### Saving

- **⌘V (short), ⌘↩, Esc, ⌘S, the Paste button, clicking away**: all save. A
  long ⌘C puts speech in, a short ⌘V puts it back: copy and paste, by voice.
- The button says **Paste**, not Submit: it is the paste.
- Because ⌘V saves, the clipboard goes into the text only via right-click →
  Paste. A *held* ⌘V dictates into the text instead.
- Saving trims trailing spaces on every line, so the space after each take
  never reaches the app.

### Dictation inside the panel

- The mic opens at key-down (first word never clipped). The **Tink** cue
  plays only at the 200 ms hold mark, so a plain ⌘C/⌘V is silent. Exception:
  ⌘C on a field that reports an empty selection beeps at once. Tink measured
  best: audible at 4 ms, gone by 32 ms.
- The panel takes key when it opens, so the caret blinks where the words will
  land. `Listening…` (then `Transcribing…`) is grey, drawn right after the
  caret, never part of the text, **no leading space**.
- **Every take ends with a space** (unless whitespace already follows), so the
  caret and the next `Listening…` sit ready. No space is added before a take
  after a space or at a line start.
- Holding ⌘C / ⌘V again appends at the caret: the panel is one ongoing take.
- Typed text is a guardrail: an empty take, Esc, or a missing mic or model
  closes the panel **only if the text area is empty**; otherwise it stays as
  the editor with what you typed.

### Buttons and keys

| Button | Key | Does | Notes |
|---|---|---|---|
| `B` | ⌘B | `**bold**` toggle | no selection: inserts `****`, caret inside |
| `I` | ⌘I | `*italic*` toggle | same |
| `<>` | — | code | selection on one line → `` `code` ``; across lines → whole lines between ```` ``` ```` fences; toggles off when already wrapped, whether the selection is the code inside or the whole block with its fences, so repeated clicks add and remove the block. After fencing the whole block, fences included, stays selected; after unfencing the code stays selected (one line with its newline), so the next click never falls back to inline backticks |
| `⊞` | ⌘⌥T | insert a table / re-align it | outside a table: a Google Docs-style grid picker (hover to size, click); inside: re-pad. See Tables |
| `MD` | ⌘⇧M | Markdown look on/off | toggle, shown pressed while on; memory only |
| `↶` `↷` | ⌘Z, ⌘⇧Z / ⌘Y | undo, redo | |
| `⌕` `⇄` | ⌘F, ⌘⇧F or ⌘⌥F | find, find & replace | opens the standard macOS find bar above the text: type to highlight matches, ↩ / ⇧↩ next / previous, Esc closes it (not the panel). `⇄` (⌘⇧F, which the user reached for; ⌘⌥F as in Xcode and VS Code) adds a Replace field with Replace / All. Before 2026-11-03 both did nothing (the action was passed without its tag). |
| `>` | **⌘⇧9** | `> ` quote lines | enabled only with a selection; ⌘⇧9 as in Gmail. Slack documents it too, but it did not work in the user's Slack. GitHub uses ⌘⇧. (taken by ⌘>), Apple Mail ⌘' / ⌥⌘'; Word and Google Docs have none |
| `<<` | **⌘,** or ⌘[ (also ⌘<) | outdent lines | enabled only with a selection; keys act on the caret line too |
| `>>` | **⌘.** or ⌘] (also ⌘>) | indent lines | same |
| — | ⌘⇧U / ⌘⇧L | upper / lower case | keys only: the AA/aa buttons were removed |
| `name ⌘N` | ⌘1–9 | run that pipe on the edited text | output pastes back |
| `Paste ⌘V` | ⌘V, ⌘↩ | save | see Saving |

- ⌘. / ⌘, are what the user meant (they first said ⌘> / ⌘<, which still
  work). ⌘. is macOS's cancel chord and used to close the panel; the editor
  catches it first. ⌘> / ⌘< are Shift+period/comma, matched by key position. The quote moved
  from ⌘⇧. to ⌘⇧9 to free ⌘>.
- **Removed**: the Trim button (saving trims anyway) and AA/aa (rarely used,
  the row was too long). A slimmer row (`B I <> | ↶ ↷ | > << >>`, the rest
  keys only) was proposed and not yet decided.

### Markdown look (on by default)

The text is always plain Markdown: what you save, copy and paste is what you
typed. It is only *drawn* styled.

- Headings larger and bold; `**bold**`, `*italic*`, `~~strike~~`; quotes
  dimmed; links underlined.
- List markers **grey** (secondary), not the accent color: blue read as noise.
- Other markers (`#`, `**`, table pipes) faint (tertiary).
- **Code like GitHub/Slack**: inline code on a rounded grey pill; a fenced
  block as one full-width rounded box with a hairline border. Backticks (inline
  and fence) are semibold grey, brighter than other markers, so code edges
  read while typing. The language after an opening fence (```` ```json ````) is drawn with the fence: it is the block's info string, not code (GitHub, VS Code). Slack's one-line ```` ```ls``` ```` backticks draw the same.
- Fences close only on the same marker (```` ``` ```` or `~~~`); Slack's
  one-line ```` ```ls -la``` ```` opens and closes on its own line.
- Knobs: `MarkdownPainter` and `CodeLayoutManager` in `EditorTextView.swift`.

### Tables

The user asked for Google Docs-like tables that stay plain Markdown.

- **Insert**: `⊞` (or ⌘⌥T) outside a table drops an 8 × 8 grid from the
  button, in an NSMenu so the panel keeps key. The label reads `columns ×
  rows`, the first row is the header. The table goes on its own lines with
  blank lines around (GitHub runs a table into a following line), caret in
  the first header cell.
- **Columns size themselves**: every keystroke in a table re-pads all columns
  to the longest cell (min 3, the shortest `---`). Caret stays in its cell;
  a space typed after a word survives. Keystroke and re-pad are one undo
  step. Only tables with a `---` row: typing a header by hand is left alone
  until it is a table.
- **Tab / Shift+Tab**: next / previous cell (end of its text), skipping the
  `---` row; Tab in the last cell adds a row, as in Docs and Notion.
- **`+` buttons**: two small ones follow the table holding the caret; right
  edge adds a last column, under it adds a last row.
- Not done: per-row/per-column `+`, deleting rows/columns by button, keys to
  add a row/column at the caret (`MarkdownTable.addRow/addColumn` already
  support it).

### Mermaid diagrams as ASCII art

The user wants boxes and arrows in plain text. Chosen order: (2)+(3) first,
dragging boxes (1) explored later.

- A closed ```` ```mermaid ```` block is **drawn as box-drawing ASCII art
  while the caret is outside it**; put the caret in (click it, arrow into it)
  and the Mermaid source shows for editing. Leave, and it redraws.
- The text stays the Mermaid source: saving and pasting send the source, not
  the art (the editor's rule: what you see styled is what you typed). Easy to
  flip later if pasting the art turns out to be what is wanted.
- `MermaidASCII.swift`, pure Swift, no dependency (no mermaid.js, no web
  view, no network). Flowcharts only: `graph`/`flowchart` LR (RL drawn LR),
  TD/TB (BT drawn TD); nodes `[]` `()` `(())` `{}` `([])` `"…"`, `<br>`;
  links `-->` `---` `-.->` (dotted) `==>` `--o` `--x`, `|label|` and
  `-- label -->`; chains, `&`. Ignored: subgraph, style, classDef, click.
  Anything else (sequence diagrams, a parse error) stays source.
- Layout: layered (longest-path ranks, cycles reversed and drawn ◄/▲),
  dummy nodes for long links, barycenter ordering, parents centered over
  children, links bend in the middle of the gap and merge into ┬ ┴ ├ ┤ ┼.
- Drawn by `CodeLayoutManager` over the folded block: the source lines fold
  to ~0 height, the opening line grows to the art's height.

### Typing helpers (Markdown look on)

- **Enter continues lists**: `-`, `*`, `+`, `1.`, `1)`, `>`; numbers count up,
  `- [x]` continues as `- [ ]`, text after the caret moves into the new item.
  Enter on an empty item ends the list. Shift/Option+Enter: plain newline.
  Later items are not renumbered. No list continuation inside a code block.
- **Typing the third backtick** of an opening fence at the end of a line
  inserts an empty line and the closing ```` ``` ```` below, caret on the empty
  line (inside the block). A closing fence adds nothing.

## History popup (⌘⇧V)

- Search, list, pipe buttons. **No new buttons**: the user rejected a row of
  Paste / Delete / Delete all buttons as clutter that repeated "paste".
- Hint line (always shown, small, above the pipe row): `⌘V paste · ⇧⏎ paste &
  delete · ⌫ delete · ⌘H hide`. Enter also pastes; it is just not advertised.
- **⌘V (short)** pastes the highlighted entry, like Enter.
- **Hidden Delete all: ⌘⇧⌫ twice within 3 s.** It deletes what the list
  shows, so it honors the search (`#en` clears that tag). The first press
  only says `Press ⌘⇧⌫ again to delete N entries`. Not in the hint, no
  button. History is memory only, so there is no undo: hence the double press.
- Opens centered on the focused window, like the editor panels.

## Where panels open

**Always centered on the focused window of the app you came from**: the
editor panels and the ⌘⇧V popup alike. Never at the caret or the mouse: every
modal is opened from the keyboard, and the window's center is where the eyes
are. (`PanelPlacement.alwaysCenterOnWindow` in `NoticePanel.swift`.) Only
when no window is known (no Accessibility, or the app reports none) do the
older rules apply: under the caret, at the pointer inside the field, else at
the mouse. Other knobs there: `windowCenterFromTop` (0.5 = middle),
`keepInsideWindow`.

**Movable**: drag any panel by its background (the band above the buttons,
the gaps, the margins) to see the app's text under it. The next panel opens
centered again.

## Paste back to where you came from

When a modal opens, ClipB records the app, its focused window and the focused
input field (`PasteTarget`, Accessibility, memory only). On save it refocuses
that window and field and pastes there, even if you switched to other apps in
between. If the field can't be refocused it activates the app; if focus still
can't be restored, nothing is pasted and the text stays on the clipboard with
a notice. Apps that expose no focused field over Accessibility (Ghostty and
other terminals, some Electron apps) get the window, not the exact field.

## Voice keys

| Keys | Tap | Hold ≥ 200 ms |
|---|---|---|
| ⌘C | copy | dictation panel |
| ⌘V | paste | dictate and paste straight into the field, **plus a trailing space** so the next take doesn't glue on. **Typed, never on the clipboard** (`Paste.type`): the user asked for the take to go straight in. Pasting needs the clipboard; a save-paste-restore variant raced (the user got their old clipboard and a stray "v"), so the text is typed as keystrokes instead. Newlines become spaces. History keeps the take under `voice`; a failed type puts it on the clipboard with a notice |
| Right Option alone | nothing | same as a ⌘V hold; opt-in `[voice] right_option = true` |

- Right Option: any other key or modifier during the press is an Option
  chord (⌥e) and cancels silently. voxtype also uses Right Option: turn one off.
- The mic indicator shows only while recording: ClipB opens the input on
  key-down and disposes it on release (voxtype likely keeps it open).
- `[voice] languages = ["en", "cs"]`: short takes sometimes came out in a
  random language, so whisper picks only among the listed ones (one extra
  encoder pass when several are listed; one code skips detection).
- Knobs: `VoiceCopyGesture.holdThreshold`, `Cue.startOnHold`,
  `Cue.startAtOnceWhenNothingSelected`.

## Open ideas, not decided

- Slimmer strip: keep `B I <> | ↶ ↷ | > << >>` as buttons, the rest keys only.
- Renumber a numbered list after inserting an item; Tab to indent list items.
- Proportional font for prose with only code monospaced (like GitHub).
- A pipe clicked while still listening could queue and run on the transcript.
- Merge ⌘⇧E into the ⌘⇧X panel entirely.
