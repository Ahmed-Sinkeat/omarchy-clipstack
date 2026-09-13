# Plan — one clipboard plugin: multi-select + inline edit

## Decision

One plugin, id `sinkeat.clipboard`, `kinds: ["overlay"]`. The editor is inlined and
the extension slot is deleted.

`PluginExtensions` exists for one reason: to let a *separate* plugin hook into the
clipboard. With one plugin that reason is gone, and the slot is 230 lines of
indirection (`PluginExtensions.qml` 176 + `PluginExtensions.js` 54) plus the
`supports`/`activate`/`label`/`shortcut`/`host` plumbing in `ClipEdit.qml`.

Multi-select cannot be an extension anyway: it needs selection state, row
rendering and key handling, and the contract is single-entry by design
(`supports(entry)`, `activate(entry)`, `handleKey(event, entry)`).

Omarchy PR #10919 becomes independent of this plugin. Keep it as an upstream
contribution if you want it landed on its own merits; nothing here waits for it.

## Files after the merge

```text
manifest.json          id sinkeat.clipboard, kinds ["overlay"], omarchy.clonedFrom
Clipboard.qml          host + inlined editorPane Component
ClipboardHistory.js    + entryKey selection helpers, + joinSelection()
ClipboardWrite.js      renamed from ClipEditModel.js — now the writer for both paths
paste-selection.sh     new, ~10 lines
test/clipstack-test.sh + join and stable-key asserts
docs/                  kept as the record
```

Base files come from the working clone at `~/.config/omarchy/plugins/sinkeat.clipboard/`
(`Clipboard.qml`, `ClipboardHistory.js`). Delete its copied `capture.sh` — unused,
`captureScript` points at `OMARCHY_PATH/shell/plugins/clipboard/capture.sh`.

## Phase 1 — selection state

`property var selectedKeys: ({})` — a plain object used as a set, keyed by
`ClipboardHistory.entryKey(entry)` (already exists, `ClipboardHistory.js:29`).

**Keys, never indices.** History rewrites on every copy (the `wl-paste --watch`
watcher), the editor's save *prepends* a new entry, and typing in the filter
reshuffles displayed rows. An index-keyed tick silently moves to another line.

- `displayRows()` puts `key` on each row; the delegate gains `required property string key`.
- `toggleKey(key)`, `clearSelection()`, `readonly property int selectionCount`.

→ verify: tick two rows, copy something unrelated, the same two stay ticked.

## Phase 2 — keys

| Key | Selection empty | Selection non-empty |
|---|---|---|
| `Ctrl+Enter` | tick cursor row, advance | tick / untick cursor row |
| `Enter` | paste cursor entry (today) | paste the joined selection |
| `Shift+Enter` | copy-only cursor entry (today) | copy-only the joined selection |
| `Delete` | remove cursor entry (today) | remove every ticked entry |
| `Esc` | clear filter, else close (today) | clear selection first |
| `Ctrl+E` | edit cursor entry | edit cursor entry — ignores the selection |

- **`Space` cannot be the toggle.** The handler routes every printable char
  (≥32, space included) into the filter.
- `Ctrl+Enter` is also the editor's save key. No clash: the editor owns the
  keyboard while open and the list handler returns early on `root.editing`.
- Selection branches go *before* the printable-char fallthrough.

## Phase 3 — joinSelection (ClipboardHistory.js)

`joinSelection(history, keys)` → `{ text, mime }`

| Selected | Contributes |
|---|---|
| text entry | its full text (uncapped record, via `entryForAction`) |
| image entry | `file://` + encoded `path` |
| file entry (text of `file://` lines) | its lines as-is |

- Order = history order (newest first), not click order. No extra state.
- `mime` = `text/uri-list` when **every** selected entry is image/file, else `""`
  (plain text). Plain text is the default for anything mixed: every app takes it,
  and a uri-list-only payload is invisible to a text editor.
- Joined with `\n`.

## Phase 4 — the copy path

`paste-selection.sh [--copy-only] [--type MIME]`, payload on **stdin**:

```bash
wl-copy ${type:+--type "$type"}   # stdin, never argv — a join blows past MAX_ARG_STRLEN
[[ $copy_only == true ]] && exit
sleep 0.15                        # same focus settle as omarchy-clipboard-paste-text
wtype -M shift -k Insert -m shift 2>/dev/null || true
```

One `Process` serves both the joined selection and a saved edit — same
operation, text on stdin, optionally pasted afterwards — so the editor's separate
`wl-copy` process goes away. QML writes the payload through
`ClipEditModel.startCopy` / `writePendingCopy` — the exact stdin lifecycle the
editor already needed. Give that Process a `property string mime` and bind
`command: mime ? [script, "--type", mime] : [script]`.

Why a script and not `omarchy-clipboard-paste-text`: that helper takes text on
argv or a `--history-index`, and a join has neither. Bonus: the script is
testable from bash, like the existing test.

The joined copy lands in history as one new entry — the watcher files it. For a
uri-list selection it comes back as a `"N files"` row, which `filePaths()`
already understands.

## Phase 5 — the checkmark

Three affordances, because `Ctrl+Enter` is otherwise invisible: a `Select  Ctrl+Enter`
button beside `Edit  Ctrl+E` in the detail pane, a tint on ticked rows, and a footer
that names the payload (`3 selected · Enter pastes as files`) via `selectionMime()` —
which exists so a label never has to build the payload to describe it.

A leading glyph column in the row delegate, before the thumbnail: `✓` when ticked,
the house glyph from `Ui/MultiSelect.qml:570` (don't reuse the component — it's a
settings dropdown). The column claims width only while a selection exists, so a
plain single pick looks untouched. Footer hint shows `N selected` while a selection exists.

## Phase 6 — inline the editor

`ClipEdit.qml` 184 → an `editorPane` Component inside `Clipboard.qml` plus
`property bool editing` and an `Item` that replaces the preview while editing.
Drop `host`, `manifest`, `label`, `shortcut`, `supports()`, `activate()` (~30 lines).
`Ctrl+E` calls it directly; `Esc` / `Ctrl+Enter` behaviour unchanged.

Delete `PluginExtensions.qml`, `PluginExtensions.js`, and the `extensions.*`
references at `Clipboard.qml:47,58,197,262-268,386-396,568,593,606,622,640-641,649`.

## Test — extend the test script

1. `joinSelection`: all-text → newline join, plain mime; all-images → `file://`
   lines + `text/uri-list`; mixed → plain text with `file://` lines inline.
2. stable keys: tick two, prepend an entry, the same two keys resolve.
3. `paste-selection.sh --copy-only` round-trips through `wl-paste`.

Bash asserts, no framework.

## Migration

1. `omarchy plugin remove sinkeat.clipedit`
2. rewrite `manifest.json` → id `sinkeat.clipboard`, `kinds: ["overlay"]`,
   `entryPoints.overlay: "Clipboard.qml"`, `keepLoaded: true`, and **keep**
   `"omarchy": {"clonedFrom": "omarchy.clipboard"}`
3. bring the clone's `Clipboard.qml` + `ClipboardHistory.js` into the repo as the base
4. `omarchy-restart-shell` after every host change — a `keepLoaded` overlay does not hot-reload
5. `clonedFrom` does the rest: Omarchy auto-disables the built-in and routes the
   existing `Super+Ctrl+V` here; removing the plugin restores it. Never enable both
   overlays by hand — two enabled overlays means two `wl-paste` watcher pairs

## Living with the fork

The clone is the only shape with zero installer setup: `Super+Ctrl+V` runs
`omarchy-shell shell toggle omarchy.clipboard` (routed by plugin id,
`default/hypr/bindings/clipboard.lua:46`) and `omarchy-plugin-validate` accepts no
keybinding field — a companion overlay on its own id would make every installer edit
their hypr config.

The price is owning a 700-line upstream file during `4.0.0.alpha`. Two rules keep it
survivable:

1. **Surgical `Clipboard.qml` hunks.** New logic goes in `ClipboardHistory.js`,
   `ClipEditModel.js` and `paste-selection.sh`. The host file gets a property, a few
   key branches, a checkmark column and a Loader — nothing a rebase has to reason about.
2. **A drift alarm**, one line, run after each Omarchy update:
   `diff -u /usr/share/omarchy/shell/plugins/clipboard/Clipboard.qml Clipboard.qml`

## Upstreaming, later

Multi-select is ~60 generic lines and plausibly belongs in the built-in. PR it — but
**after #10919 gets a verdict**, not now: both touch `Clipboard.qml`, and #10919 adds
the very extension slot this plugin deletes. Shipping does not wait on either.

## Store submission

The clone shape is what makes this submittable. `omarchy.clonedFrom` means no
keybinding or config steps for the installer, and nothing waits on PR #10919 —
which is why ClipEdit-as-an-extension never went to the store.

Prior art to be honest about in the submission:

| Entry | Overlap |
|---|---|
| [Snippets #6273](https://github.com/omacom/omarchy-plugin-marketplace/issues/6273) | same clone-replaces-picker shape |
| [Clipboard shelf #6143](https://github.com/omacom/omarchy-plugin-marketplace/issues/6143) | pinning, bar slot |
| [Omarchy Clipboard #6482](https://github.com/omacom/omarchy-plugin-marketplace/issues/6482) | history overlay |
| [omarchy-clipboard-plus-and-shelf](https://github.com/engineer-hamas/omarchy-clipboard-plus-and-shelf) | inline text editing, shelves |

Inline editing is no longer novel. **Multi-select — tick N rows, paste them as one
payload — is the open niche.** Lead the submission with that; editing is the bonus.

## Out of scope

Sequential paste (real pixels, one item at a time), edit-the-whole-selection,
click-order joins, `Ctrl+A` select-all, pinning or shelves, a configurable
separator. Add sequential paste only when "I wanted the actual images" actually bites.

## Risks

| Risk | Answer |
|---|---|
| `Tab` swallowed by focus navigation | fall back to `Ctrl+Space` |
| uri-list paste invisible in a text editor | plain text is the default for every mixed selection |
| editor save shifts history indices | selection is content-keyed (Phase 1) |
