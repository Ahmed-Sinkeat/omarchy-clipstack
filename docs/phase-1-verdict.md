# Phase 1 verdict

> [!NOTE]
> Kept because it is why the editor lives in the clipboard's own detail pane
> rather than in a second overlay.

**Status:** Direction selected

**Winning variant:** A — In-place pane

**Why:** It keeps the existing clipboard manager recognizable, provides the shortest edit flow, and matches the already-working native proof-of-concept.

## Decisions to carry forward

- Editor layout: replace the right-side preview with a plain-text editor.
- Visible action: show Edit and its `Ctrl+E` shortcut.
- Save shortcut: `Ctrl+Enter`.
- List behavior while editing: keep history visible and unchanged.
- History behavior: save as a new entry; preserve the original.
- Save completion: close the clipboard overlay after copying.

## Deferred

- C's dedicated original-text block may be reconsidered after V1 if users need stronger before/after comparison.

## Rejected for V1

- B's collapsed context rail.
- Multiple layouts or a variant switcher.
