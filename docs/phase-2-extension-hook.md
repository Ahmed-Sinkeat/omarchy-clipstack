# Phase 2 — the extension hook

> [!NOTE]
> This documents the **upstream** contribution in [Omarchy PR #10919](https://github.com/omacom/omarchy/pull/10919),
> which is still open. The shipped plugin no longer uses the slot: multi-select needs
> selection state in the host, so the editor moved into the overlay instead. See
> [plan.md](../plan.md).

**Status:** Decided and implemented. The upstream change is on the
`clipboard-extension-point` branch of the Omarchy fork.

## What we inspected

`shell/plugins/clipboard/Clipboard.qml`, `shell/services/PluginRegistry.qml`,
`shell/shell.qml`, `shell/README.md`, and `bin/omarchy-plugin-validate` in
Omarchy Quattro `4.0.0.alpha`.

Three facts decided the design:

1. The registry already validates and stores arbitrary manifests, resolves
   entry-point URLs safely, and answers `isEnabled(id)`. It does not need to
   learn anything about extensions.
2. `shell.qml` only loads plugins whose `kinds` include `bar`, `bar-widget`,
   `panel`, `overlay`, `menu`, or `service`. A new kind is inert to the shell
   core, so nothing double-loads and nothing else has to change.
3. Panel plugins already receive `pluginRegistry` by property injection, which
   is exactly what a host needs to find its own extensions.

So the hook is not a new plugin system. It is one component plus one manifest
kind that the existing registry already carries.

## The contract

An extension declares its host in its manifest:

```json
"kinds": ["extension"],
"entryPoints": { "extension": "ClipEdit.qml" },
"extension": { "host": "omarchy.clipboard" }
```

Its entry point declares what it offers and what it acts on:

```qml
property var host: null                       // injected on load
readonly property string label: "Edit"
readonly property string shortcut: "Ctrl+E"   // optional
function supports(entry) { return entry && entry.type === "text" }
function activate(entry) { host.openPane(editorComponent, entry) }
```

A host offers a slot by naming itself:

```qml
PluginExtensions {
  id: extensions
  hostId: "omarchy.clipboard"
  pluginRegistry: root.pluginRegistry
  onCloseRequested: root.close()
}
```

and renders three things: `available(entry)` as actions,
`handleKey(event, entry)` for contributed shortcuts, and `paneComponent` when
`paneOpen`. The host never learns what an extension does.

The entry passed to an extension contains the complete source value even when the host caps or reshapes text for display. A host must construct action entries from its source record, not from its rendered preview.

## Why this shape

| Goal | How it is met |
|---|---|
| Small | One QML component, one JS helper, one manifest kind. No registry change. |
| Generic | Nothing in the slot mentions editing, clipboards, or text. |
| Optional | With none installed, every host binding collapses to the old behavior. |
| Safe | A failed load, a throwing `supports()`, or a throwing `activate()` drops that extension, never the host. |
| Discoverable | The host draws `label` and `shortcut` itself, in its own style. |
| Context-aware | `supports(entry)` gates per entry; images offer no Edit action. |

## Rejected

**A clipboard-specific action list.** `clipboardActions` in the manifest would
have been smaller still, but it buys nothing reusable and the next host would
add a second one.

**A general plugin-to-plugin RPC.** The shell already has `call` over IPC; the
missing piece was never message passing, it was a place on screen.

**Extensions as `panel` plugins summoned by the host.** A panel is its own
window. The whole point of Variant A is that the editor is *not* a second
surface.

**Passing the host plugin itself as `host`.** The clipboard root exposes
history mutation. A slot object with four methods is the same size and says
what the contract actually is.

## Known limits

- One pane at a time per host. A second `openPane` replaces the first.
- Shortcut specs are `Modifier+…+Key` with `Ctrl`/`Shift`/`Alt`/`Super`; an
  unreadable spec loses its shortcut, not its button.
- Two extensions claiming one shortcut resolve by plugin id, deterministically,
  and neither is warned about it.
- A `keepLoaded` host does not pick up its own QML changes on plugin
  hot-reload; `omarchy-restart-shell` is required. Extensions *are* picked up
  live.
