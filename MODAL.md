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
- Layout: layered (longest-path ranks, cycles reversed and drawn ◀/▲),
  dummy nodes for long links, barycenter ordering, parents centered over
  children, links bend in the middle of the gap and merge into ┬ ┴ ├ ┤ ┼.
- Drawn by `CodeLayoutManager` over the folded block: the source lines fold
  to ~0 height, the opening line grows to the art's height.
- **Dragging within a layer** (`%% clipb-order`) was built and removed the
  same day: the preview did not redraw during the drag, and the user wanted
  free drawing instead (next section).

### Drawings (ASCII canvas)

The user asked for a canvas: click to make a box, type its title, drag from a
side to pull an arrow to another box, labels in the middle of arrows,
multi-line with Shift+Enter, "make this really easy to work with". Decided
with the user: saved as ASCII art (not Mermaid + positions); click = box,
drag = sized box; arrows auto-routed with elbows; the panel grows to fit and
resizes by its corner.

- The block's text is the art (`AsciiDiagram`: model, render, router,
  parse). Boxes `┌─┐`, text centered on each line (by its visible part:
  spaces around a line are dropped when read back) and top aligned; arrows bend with rounded
  `╭╮╰╯` so they never read as box corners, leave a box through `├┤┬┴`, end
  in a head, cross with `┼`. Labels sit beside the middle of their arrow,
  never over a line.
- A ``` block is a drawing only when `parse` → `render` gives back exactly
  its text, so psql tables and other art are left alone. Fence language
  empty, `text`, `txt`, `ascii` or `diagram`.
- `DiagramCanvas` (editor): mouse down on a drawing is the canvas's, never a
  caret. Redesigned with the user (second round): **double-click** empty
  space for a box (title caret ready; left empty, it goes away again); a
  single click there just deselects. **Drag on empty space**: a blue
  selection rectangle; every box it touches is picked, and dragging any
  picked box moves them all. **Click in a box's text**: a caret where you
  clicked; ←→ (across line ends), ↑↓, Home/End move it, typing, Backspace,
  ⌥⌫ and ⇧↩ act at it (`CaretText`). **Click an edge**: the box is picked
  (ring, no caret); arrow keys nudge, Backspace/⌘⌫ delete, Enter types at
  the end of its text, typing starts there too. **Drag an edge or the text
  area**: moves the box; an edge drag released over another box makes an
  arrow to it instead (the user wanted both "click the edge to move it"
  and "drag from the edge to another box for an arrow"; the drop target
  decides, the preview shows which). Corner drag: resize. Shift-click adds
  or removes a box. Click an arrow: picked; in ClipB's own drawings its
  label takes a caret too. Hit order: corner, edge, text, line, empty.
  Previews during a drag are written without undo; the drop restores the
  start and writes the result as one undo step. Boxes keep a free cell
  between them.
- `CanvasDrawing` hides which kind of drawing it is (ClipB's own layout,
  re-rendered; or hand-drawn art, edited in place); the canvas is written
  once against it.
- While something is selected, every other text command is swallowed (it
  would type into the art). The real caret parks hidden at the block start;
  Esc, Enter in text, or a click on empty space finishes and puts it after
  the block; Esc does not close the panel then.
- `⇄ ASCII` / `⇄ Mermaid` button at a block's top right switches forms; the
  Mermaid a drawing came from is remembered (memory only) and given back
  while the art is unchanged; otherwise Mermaid is generated (`graph TD`/
  `LR`, ids A, B, …).
- Wide drawings: the editor asks the panel for the width (`onWantsWidth`),
  which grows up to the screen and never shrinks by itself. Asked on every
  text change and when the editor opens, for any box art in a drawing
  fence, not only once edited: wrapped art can't be read or clicked. The corner grip
  (`ResizeGrip`) resizes the text area; the size is kept in UserDefaults
  (a size, never text).
- Hand-drawn art (the user pasted a gateways diagram: free-text headers,
  footnotes, a stacked box split by `├──┤`, one branching bus line to eleven
  compartments) is edited **in place**, decided with the user over "import
  and redraw": `AsciiArt` scans the grid for closed `┌┐└┘` boxes (stacked:
  one box, several compartments) and connected lines (trees too), and an
  edit rewrites only the moved box and the branches attached to it, from
  the box to the nearest junction; every other character stays as drawn.
  Used when a block is not ClipB's own layout (`AsciiDiagram.parse` fails)
  and holds at least one closed box. Typing goes into the clicked
  compartment; its lines have no labels, so typing on a selected line does
  nothing. No `⇄ Mermaid` for it. An edit that would overlap a box or text,
  or finds no route, is refused (beep) and the art is left as it was.
- Centered text, asked for by the user for all boxes: hand-drawn boxes
  are re-centered only in the compartment you type into; untouched art
  keeps its own alignment. The caret is placed through
  `CanvasDrawing.lineStart`, since every line starts at its own column.
- Not yet: copy/paste of boxes, arrow re-targeting by dragging its end,
  box shapes, selecting text with the mouse inside a box.

### Box zones (third round)

Asked for by the user after the second round; it replaces the second
round's edge/text rules above. The open hand shows on nearly the whole box,
everything but its text (the user: "pretty much the whole box ... except
the very center"). A box is split into zones; each has its own cursor on
hover, click and drag:

```
      handle            corner
        ✛                 ↘
  ┌─────────┬─────────┐
  │  move  side  move │   side: border cells that are not a corner or handle
✛ ┤   ┌─────────┐     ├ ✛ handle: the middle cell of each side
  │   │  text   │     │   text: the box's text lines, the whole row width
  │   └─────────┘     │   move: the rest of the inside
  └─────────┴─────────┘
        ✛
```

| Zone | Hover cursor | Click | Drag |
| --- | --- | --- | --- |
| Corner | diagonal resize | picks the box | resizes the box |
| Side handle (middle of each side) | crosshair ✛, the handle drawn | picks the box | pulls a new arrow out of that side; release over another box: an arrow from that side to it |
| Side (rest of the border) | open hand | picks the box: blue ring, no caret | moves the box |
| Text (centre) | I-beam | edits the text: blinking caret | moves the box |
| Inside, not text | open hand | edits the text: blinking caret at the end | moves the box |
| Empty space | arrow | single: deselect; double: new box | blue selection rectangle |

- A click is a press and release without moving a cell; any move turns it
  into the drag of that zone. Dragging inside a picked box moves every
  picked box.
- The text zone is exactly the cells the text covers (its rows, from the
  leftmost line start to the longest line's end; an empty text: its middle
  cell), so padding around it is "inside".
- The caret blinks (0.53 s, shown again on every change), at the end of the
  text when the click lands off the text, and where clicked when it lands
  on a character (the second round's ask, kept unless the user says
  otherwise).
- The handles (a small circled ✛ per side) show on hover of the box only,
  so a drawing at rest looks like its text. Dragging one draws a dashed
  line to the pointer and a dashed ring on the box under it. Not yet: the
  arrow leaving through the handle's side; the router still picks the side.
- Arrow released on empty space: nothing happens (open: a new box there).
- Small boxes: on a 3-row box the left and right handle is the only side
  cell, so those sides have no plain "side" zone; corners win over
  handles, handles over sides.
- Replaces the second round's "edge drag released over another box makes
  an arrow": arrows come from the handles only.
- Open, to confirm with the user: whether the caret should always go to
  the end, even on a character click.

### Lines, free text, sides (fourth round)

Asked for by the user with a before/after of the gateways art (the vertical
run under oms-api slid three columns left, the branch shortening to fit).

- **Drag a line's straight run** (resize cursor across it): it slides
  across; the runs on either side stretch or shrink, ends slide along their
  box side (never onto a corner), heads and tees go with them. In ClipB's
  own drawings this turns the drawing into hand-drawn art (the router would
  undo a hand-placed route); moving it back restores the text exactly.
- **Click anywhere** in a drawing off boxes and lines: a caret there (the
  empty-space cursor is the I-beam). Typing writes into free space; inside a
  run of text it inserts, pushing the run's tail right, but only into free
  space (else a beep); Backspace pulls it back; Enter goes down a row to the
  column typing started at; arrows move the caret freely. A drawing grows
  rows and columns as needed. Esc leaves.
- **Free text is background for typing and an object for dragging**,
  decided with the user over "only one or the other": a run of words (single
  spaces inside, two or more split runs; a title, a footnote) drags as one
  piece with the open hand.
- **Pulling an arrow**: the box under the pointer shows its ✛ handles too;
  dropping on one enters through that side, and the arrow leaves through the
  side of the handle dragged from. When no route fits those sides, the
  target's side alone, then any side.
- **Trimming**: every write leaves no spaces at line ends and no blank lines
  at the end of the drawing.

### Styles (double-click)

The target is `docs/ascii-diagram-style-guide.md`, the user's style guide,
kept as they wrote it. Double-click a box's border (or corner or handle):
the next box style, light → heavy → double → rounded → dashed → dotted.
Double-click a line: the next line style, solid → heavy → double → dashed →
dotted. Double-click an arrow's end or head: the next heads, forward →
backward → both → none. Each is one undo step, in ClipB's drawings and in
hand-drawn art (art: only that box's border or that line's glyphs change).

- Glyphs not in the guide, ClipB's choice: tees follow the box (light,
  rounded, dashed `├┬┤┴`; heavy `┣┳┫┻`; double `╠╦╣╩`; dotted none, the line
  starts beside the border). Bends: `╭╮╰╯` for solid, dashed and dotted
  (Unicode has no dashed corners), `┏┓┗┛` heavy, `╔╗╚╝` double. Crossings
  keep each stroke's weight (`┼ ┿ ╂ ╋ ╪ ╫ ╬`; heavy against double: `┼`).
- A rounded corner is a box only when it closes a rectangle; otherwise a bend.
- "Backward" is forward with the ends swapped; "forward" means from the box
  earlier in reading order. Both/none arrows keep the earlier box as `from`.
- Art reads but ClipB never draws: dotted with `·` corners, block, block
  thin inset. Not yet: the database cylinder, the user figure, devices,
  stacked replicas, labels inside a line (`──HTTPS─▶`), heads on a bus, and
  Mermaid export of styles.

### Typing helpers (Markdown look on)

- **Enter continues lists**: `-`, `*`, `+`, `1.`, `1)`, `>`; numbers count up,
  `- [x]` continues as `- [ ]`, text after the caret moves into the new item.
  Enter on an empty item ends the list. Shift/Option+Enter: plain newline.
  Later items are not renumbered. No list continuation inside a code block.
- **Typing the third backtick** of an opening fence at the end of a line
  inserts an empty line and the closing ```` ``` ```` below, caret on the empty
  line (inside the block). A closing fence adds nothing.

## Standalone editor window (`clipb edit <file>`)

The same `EditorTextView` in an ordinary titled window, for editing ASCII
drawings in a file without the clipboard app. No strip, footer, pipes or
panel chrome: just the text, Markdown look on, the drawing canvas live. The
window widens to fit wide drawings (`onWantsWidth`, `fitDrawings`) up to the
screen. ⌘S/Esc save, close and ⌘Q save a changed buffer silently (the point
is no dialog), title is the file name with the edited dot. A file that is one
bare box drawing (no fence, has `┌`) is shown wrapped in a ``` block so the
canvas sees it, and unwrapped on save. It is its own process: it never talks
to the running app (SPEC §2.13, CLI notes).

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
| ⌘V | paste | dictate and paste straight into the field, **plus a trailing space** so the next take doesn't glue on. **Typed, never on the clipboard** (`Paste.type`): the user asked for the take to go straight in. Pasting needs the clipboard; a save-paste-restore variant raced (the user got their old clipboard and a stray "v"), so the text is typed as keystrokes instead. Newlines become spaces. It is not filed in history either (the user saw it there and did not want it); a failed type puts it on the clipboard with a notice |
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
