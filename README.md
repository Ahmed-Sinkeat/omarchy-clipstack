# Clipstack for Omarchy

A replacement for Omarchy's clipboard overlay that adds two things to it: **tick
several entries and act on them together**, and **edit a text entry in place**.

Select entries with `Ctrl+Enter`, then `Enter` pastes them as one payload. Text
entries join with newlines; images contribute their `file://` path; a selection of
nothing but images or files is copied as `text/uri-list`, so file managers and
image editors receive it as files.

`Ctrl+E` opens the selected text entry in the detail pane, `Ctrl+Enter` copies the
edit as a new entry, and `Esc` cancels with the original untouched.

## Install

```bash
omarchy plugin add https://github.com/Ahmed-Sinkeat/omarchy-clipstack.git
omarchy plugin enable sinkeat.clipboard
```

The manifest declares `omarchy.clonedFrom = omarchy.clipboard`, so the existing
`Super+Ctrl+V` binding routes here and Omarchy disables the built-in overlay. No
keybinding or config changes are required.

## Remove

```bash
omarchy plugin remove sinkeat.clipboard
```

That re-enables the built-in clipboard overlay and hands `Super+Ctrl+V` back to it.
Clipboard history in `~/.local/state/omarchy/` is Omarchy's own and is left alone.

## Dependencies

Everything it calls ships with Omarchy: `wl-clipboard`, `wtype`, `jq`, and the
`omarchy-clipboard-*` helpers. No network access, no elevated privileges.

## Shortcuts

| Action | Shortcut |
|---|---|
| Tick the entry under the cursor | `Ctrl+Enter` |
| Paste every ticked entry as one payload | `Enter` |
| Copy them without pasting | `Shift+Enter` |
| Remove every ticked entry | `Delete` |
| Drop the selection | `Esc` |
| Edit the entry under the cursor | `Ctrl+E` |
| Copy the edit as a new entry | `Ctrl+Enter` (in the editor) |
| Cancel the edit | `Esc` |

Nothing has to be memorised: both actions are buttons in the detail pane
(`Select  Ctrl+Enter` and `Edit  Ctrl+E`), a ticked row is tinted and marked `✓`,
and the footer reads `3 selected · Enter pastes as files` — so the payload a paste
will produce is visible before you press it.

With nothing ticked every key keeps its stock behaviour: `Enter` pastes,
`Shift+Enter` copies, `Alt+Enter` opens, `Delete` removes, `Shift+Delete` clears.

A selection is tracked by entry content, not by row: the clipboard watcher rewrites
history on every copy and saving an edit prepends an entry, so ticks stay on the
entries you picked. An empty edit is not saved. Images offer no Edit action.

## Layout

```text
manifest.json          plugin manifest, cloned from omarchy.clipboard
Clipboard.qml          overlay, selection state, and the editor pane
ClipboardHistory.js    history model, selection set, and payload join
ClipboardWrite.js      the wl-copy stdin lifecycle, shared by both writers
paste-selection.sh     copies a joined selection and pastes it
test/                  regression tests
docs/                  design records and the upstream proposal
plan.md                the multi-select merge plan
```

## Verification

```bash
./test/clipstack-test.sh                            # selection, join, copy lifecycle
qmllint Clipboard.qml                               # QML parses
omarchy plugin validate ~/Projects/omarchy/plugins  # manifest
```

After a change to `Clipboard.qml`, run `omarchy-restart-shell`: a `keepLoaded`
overlay does not hot-reload.

Because the plugin is a clone, upstream changes to
`/usr/share/omarchy/shell/plugins/clipboard/Clipboard.qml` do not arrive on their
own. After an Omarchy update, check what moved:

```bash
diff -u /usr/share/omarchy/shell/plugins/clipboard/Clipboard.qml Clipboard.qml
```

## History

Clipstack began as **ClipEdit** — hence the repository name — an `extension` plugin
hosted by the built-in clipboard through
the slot proposed in [Omarchy PR #10919](https://github.com/omacom/omarchy/pull/10919),
which is still open. Multi-select cannot be expressed by that contract — it needs
selection state, row rendering and key handling in the host — so the editor moved
into the overlay and the extension slot was deleted. Nothing here waits on the PR
any more; it stands on its own merits upstream. See [plan.md](plan.md) for the
decision and [docs/](docs) for the earlier phases.

## License

Clipstack is available under the [MIT License](LICENSE).
