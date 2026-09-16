import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory
import "ClipboardWrite.js" as ClipboardWrite

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  // Resolved from this file's own URL so the paste helper beside it runs
  // wherever the plugin happens to be installed.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool clearConfirmOpen: false
  property var history: []
  // Ticked entries, as a set of ClipboardHistory.entryKey() values. Keys rather
  // than indices: the watcher rewrites history on every copy and saving an edit
  // prepends an entry, so an index would quietly point at something else.
  property var selectedKeys: ({})
  readonly property int selectionCount: ClipboardHistory.selectionCount(root.selectedKeys)
  property bool editing: false
  property string editorSeed: ""

  property string historyPath: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history.json"
  property string captureScript: root.pluginDir + "capture.sh"
  // Every helper starts from nothing but this. The fixed PATH keeps a shadow
  // executable in a user-writable PATH directory from standing in for a tool a
  // copy passes through, and clearing the rest leaves behind LD_PRELOAD,
  // BASH_ENV and PERL5OPT, each a way into the bash and perl that read one.
  // HOME and XDG_STATE_HOME locate the history and the image directory,
  // WAYLAND_DISPLAY and XDG_RUNTIME_DIR reach the compositor, and the last four
  // date-stamp a capture in the user's own timezone and language.
  readonly property var helperEnv: {
    var env = { "PATH": "/usr/local/bin:/usr/bin" }
    var names = ["HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "WAYLAND_DISPLAY",
      "TZ", "LANG", "LC_ALL", "LC_TIME"]
    for (var i = 0; i < names.length; i++) {
      var value = Quickshell.env(names[i])
      if (value) env[names[i]] = value
    }
    return env
  }
  // False until history has loaded, and for good if it could not be read: a save
  // before then would write a partial history over the real one.
  property bool historyWritable: false
  // The last copy was too large to keep. Cleared by the next copy that is kept.
  property bool lastCopySkipped: false
  // Shares the [menu] surface tokens — themes that style the menu also
  // style the clipboard. Selected-row colors composed in the
  // singleton so consumers drop them straight into Rectangle bindings.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int historyLimit: 500

  function open(payloadJson) {
    root.opened = true
    root.editing = false
    root.selectedKeys = ({})
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.cancelClearHistory()
    root.editing = false
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function normalizeEntry(value) {
    return ClipboardHistory.normalizeEntry(value)
  }

  function entryKey(entry) {
    return ClipboardHistory.entryKey(entry)
  }

  function loadHistory(raw) {
    var loaded = ClipboardHistory.parseHistory(raw, root.historyLimit)
    root.history = loaded || []
    root.historyWritable = loaded !== null
    if (root.opened) root.rebuildDisplay()
  }

  function saveHistory() {
    if (!root.historyWritable) return
    historyFile.setText(JSON.stringify(root.history.slice(0, root.historyLimit), null, 2) + "\n")
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = ClipboardHistory.addEntry(root.history, normalized, root.historyLimit)
    root.lastCopySkipped = false
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    var result = ClipboardHistory.captureResult(line)
    if (result.kind === "skipped") root.lastCopySkipped = true
    else if (result.kind === "entry") root.addClipboardEntry(result.entry)
  }

  function requestClearHistory() {
    if (root.history.length === 0) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmClearHistory() {
    root.history = ClipboardHistory.clearHistory()
    root.saveHistory()
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    root.clearConfirmOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeDisplayIndex(index) {
    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    root.history = ClipboardHistory.removeEntryAt(root.history, row.historyIndex)
    root.saveHistory()

    if (displayModel.count <= 1) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count - 1) {
      root.selectedIndex = displayModel.count - 2
    }

    root.disarmPointer()
    root.rebuildDisplay()
  }

  function rebuildDisplay() {
    var rows = ClipboardHistory.displayRows(root.history, root.filterText, 50)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      displayModel.append({
        entryType: row.entryType,
        fullText: row.fullText,
        previewText: row.previewText,
        previewImage: row.previewImage ? Util.fileUrl(row.previewImage) : "",
        path: row.path,
        mime: row.mime,
        key: row.key,
        historyIndex: row.index
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (root.editing) return
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  // A plain snapshot rather than the ListModel row, so an extension holding on
  // to it cannot be surprised by the next rebuild. ClipboardHistory recovers
  // the original record because the row's renderable text may be capped.
  function selectedEntry() {
    if (!root.cursorActive) return null
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return null

    var row = displayModel.get(root.selectedIndex)
    return ClipboardHistory.entryForAction(root.history, row.historyIndex)
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.applySelected(row)
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.copySelected(row)
  }

  function openIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.openSelected(row)
  }

  function applySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-file", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--shift-insert", "--history-index", String(row.historyIndex)])
    }
  }

  function copySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-file", "--copy-only", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--copy-only", "--history-index", String(row.historyIndex)])
    }
  }

  function openSelected(row) {
    if (!row) return
    root.opened = false
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
  }

  // Ticking advances the cursor: a selection is usually built by running down
  // consecutive rows.
  function toggleSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return

    var row = displayModel.get(root.selectedIndex)
    root.selectedKeys = ClipboardHistory.toggleSelection(root.selectedKeys, row.key)
    if (root.selectedIndex < displayModel.count - 1) root.select(1)
  }

  function clearSelection() {
    root.selectedKeys = ({})
  }

  // A Wayland clipboard holds one item, so the selection collapses into one
  // payload. The helper takes it on stdin: a join can exceed MAX_ARG_STRLEN.
  function applySelection(copyOnly) {
    var joined = ClipboardHistory.joinSelection(root.history, root.selectedKeys)
    if (joined.count === 0 || joined.text.length === 0) return

    copyProc.mime = joined.mime
    copyProc.copyOnly = !!copyOnly
    if (!ClipboardWrite.startCopy(copyProc, joined.text)) return
    root.close()
  }

  function removeSelection() {
    if (root.selectionCount === 0) return

    root.history = ClipboardHistory.removeSelected(root.history, root.selectedKeys)
    root.saveHistory()
    root.clearSelection()
    if (root.history.length === 0) {
      root.selectedIndex = 0
      root.cursorActive = false
    }
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function openEditor() {
    var entry = root.selectedEntry()
    if (!entry || entry.type !== "text" || String(entry.text || "").length === 0) return

    root.editorSeed = String(entry.text)
    root.editing = true
  }

  function closeEditor() {
    root.editing = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Saving copies the edited text instead of rewriting the entry: the watcher
  // then files it as a new entry, so the original stays one row below as a free
  // undo and nothing here has to touch history.json.
  function saveEdit(text) {
    copyProc.mime = ""
    copyProc.copyOnly = true
    if (!ClipboardWrite.startCopy(copyProc, text)) return false

    root.close()
    return true
  }

  Component.onCompleted: loadProc.running = true

  ListModel { id: displayModel }

  // One writer for both paths — a joined selection and a saved edit are the
  // same operation: text on stdin, optionally pasted afterwards.
  Process {
    id: copyProc

    property string payload: ""
    property string mime: ""
    property bool copyOnly: false

    command: {
      var argv = [root.pluginDir + "paste-selection.sh"]
      if (copyProc.copyOnly) argv.push("--copy-only")
      if (copyProc.mime.length > 0) argv.push("--type", copyProc.mime)
      return argv
    }
    onStarted: ClipboardWrite.writePendingCopy(copyProc)
    clearEnvironment: true
    environment: root.helperEnv
  }

  Component {
    id: editorPane

    Item {
      id: pane

      Component.onCompleted: {
        editor.text = root.editorSeed
        editor.forceActiveFocus()
        editor.cursorPosition = editor.length
      }

      Text {
        id: kicker

        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        text: "Editing selected text"
        color: Color.menu.text
        opacity: 0.58
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Flickable {
        id: scroll

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: kicker.bottom
        anchors.topMargin: Style.spacing.sm
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.spacing.md
        contentWidth: width
        contentHeight: editor.contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        TextEdit {
          id: editor

          width: scroll.width
          textFormat: TextEdit.PlainText
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          wrapMode: TextEdit.WrapAnywhere
          selectByMouse: true
          selectionColor: Color.menu.selectedBackground
          selectedTextColor: Color.menu.selectedText

          // Flickable does not follow the caret on its own, so a long entry
          // would type off the bottom of the pane.
          onCursorRectangleChanged: {
            if (cursorRectangle.y < scroll.contentY)
              scroll.contentY = cursorRectangle.y
            else if (cursorRectangle.y + cursorRectangle.height > scroll.contentY + scroll.height)
              scroll.contentY = cursorRectangle.y + cursorRectangle.height - scroll.height
          }

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.closeEditor()
              event.accepted = true
            } else if ((event.modifiers & Qt.ControlModifier)
                && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
              root.saveEdit(editor.text)
              event.accepted = true
            }
          }
        }
      }

      Item {
        id: footer

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(hint.implicitHeight, buttons.implicitHeight)

        Text {
          id: hint

          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: buttons.left
          anchors.rightMargin: Style.spacing.controlGap
          anchors.verticalCenter: parent.verticalCenter
          text: editor.length > 0 ? "Original kept" : "Enter text to copy"
          color: Color.menu.text
          opacity: 0.55
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          id: buttons

          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.controlGap

          Button {
            text: "Cancel  Esc"
            foreground: Color.menu.text
            fontFamily: Style.font.menuFamily
            fontSize: Style.font.body
            onClicked: root.closeEditor()
          }

          Button {
            text: "Copy new  Ctrl+Enter"
            bordered: true
            enabled: editor.length > 0 && !copyProc.running
            opacity: enabled ? 1 : 0.45
            foreground: Color.menu.text
            fontFamily: Style.font.menuFamily
            fontSize: Style.font.body
            onClicked: root.saveEdit(editor.text)
          }
        }
      }
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // Write-only. Reading goes through load-history.sh, which bounds and checks the
  // file first; nothing else writes it, so there is nothing to watch for.
  FileView {
    id: historyFile
    path: root.historyPath
    preload: false
    atomicWrites: true
    printErrors: false
  }

  // Watchers start only once history has loaded, so no copy can be saved over a
  // history that has not been read yet.
  Process {
    id: loadProc
    command: ["/usr/bin/bash", root.pluginDir + "load-history.sh", root.historyPath, String(ClipboardHistory.historyFileLimit)]
    stdout: StdioCollector { id: loadOutput; waitForEnd: true }
    clearEnvironment: true
    environment: root.helperEnv
    onExited: function(exitCode) {
      if (exitCode === 0) root.loadHistory(loadOutput.text)
      else console.warn("clipboard: history could not be read (load-history.sh exited " + exitCode + "), not saving over it")
      initProc.running = true
    }
  }

  // Reap watchers left behind by a previous shell instance, then start our
  // own. The pdeathsig on the watchers makes the kernel kill them whenever
  // the shell exits, however it exits, so no further lifecycle management.
  Process {
    id: initProc
    command: ["/usr/bin/pkill", "-f", "wl-paste .*--watch (.*/shell/plugins/clipboard/capture\\.sh|"
      + root.captureScript.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")"]
    clearEnvironment: true
    environment: root.helperEnv
    onExited: {
      currentProc.running = true
      textWatchProc.running = true
      imageWatchProc.running = true
    }
  }

  Process {
    id: currentProc
    command: [root.captureScript]
    clearEnvironment: true
    environment: root.helperEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.addClipboardJson(text)
    }
  }

  Process {
    id: textWatchProc
    command: ["/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    clearEnvironment: true
    environment: root.helperEnv
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: ["/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    clearEnvironment: true
    environment: root.helperEnv
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  // A watcher that dies takes clipboard history with it, silently: copying still
  // works, the picker still opens, and the old entries are all still there, so
  // nothing recorded until the next shell reload. Bring it back instead.
  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!textWatchProc.running) textWatchProc.running = true
      if (!imageWatchProc.running) imageWatchProc.running = true
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (root.editing) {
            // The editor owns the keyboard. Escape is the way back out if it
            // never took focus.
            if (event.key === Qt.Key_Escape) {
              root.closeEditor()
              event.accepted = true
            }
            return
          }

          if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_E) {
            root.openEditor()
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.selectionCount > 0) root.clearSelection()
            else if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
            else if (root.selectionCount > 0) root.removeSelection()
            else root.removeDisplayIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ControlModifier) root.toggleSelected()
            else if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
            else if (root.selectionCount > 0 && (event.modifiers & Qt.ShiftModifier)) root.applySelection(true)
            else if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.copyIndex(root.selectedIndex)
            else if (root.selectionCount > 0) root.applySelection(false)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: clearConfirm

          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete entire clipboard history?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClearHistory()
          onConfirmed: root.confirmClearHistory()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search clipboard…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                // Where the copy would have appeared, a quiet note that it was not kept.
                // Its height comes from font metrics rather than from laying the text
                // out, so the layout can never feed back into the note's own size.
                header: Item {
                  width: resultList.width
                  height: root.lastCopySkipped ? skippedMetrics.height + Style.space(8) : 0

                  FontMetrics {
                    id: skippedMetrics
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: skippedNote
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.lastCopySkipped
                    text: "Last copy not saved · too large or too slow"
                    color: root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage
                  required property string key

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                  readonly property bool ticked: !!root.selectedKeys[row.key]

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    // Only claims width once something is ticked, so a plain
                    // single-entry pick looks exactly as it did before.
                    Text {
                      id: check
                      textFormat: Text.PlainText
                      visible: root.selectionCount > 0
                      width: visible ? Style.space(16) : 0
                      height: parent.height
                      text: row.ticked ? "✓" : ""
                      // The accent, never the row foreground: the cursor row owns the
                      // only background wash, so a tick has to read on its own.
                      color: root.selectedText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      verticalAlignment: Text.AlignVCenter
                    }

                    Image {
                      visible: parent.parent.previewImage.length > 0
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: parent.parent.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                        - (row.previewImage.length > 0 ? parent.height + parent.spacing : 0)
                        - (check.visible ? check.width + parent.spacing : 0)
                      height: parent.height
                      text: parent.parent.previewText
                      color: parent.parent.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      opacity: parent.parent.entryType === "image" || parent.parent.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      verticalAlignment: Text.AlignVCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: {
                      if (root.editing) return
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }
                }
              }
            }

            Item {
              id: detailPane
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null

              readonly property var entry: {
                // selectedEntry() reads the cursor and the model; the filter is
                // the one input it cannot see, and refiltering can change what
                // sits at the selected index without changing the row count.
                var filterText = root.filterText
                return root.selectedEntry()
              }
              readonly property bool canEdit: !!detailPane.entry && detailPane.entry.type === "text"
                && String(detailPane.entry.text || "").length > 0
              readonly property bool cursorTicked: detailPane.activeRow
                ? !!root.selectedKeys[detailPane.activeRow.key] : false
              readonly property int actionsInset: actionRow.visible ? actionRow.height + root.contentSpacing : 0

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Text {
                textFormat: Text.PlainText
                visible: !root.editing && parent.activeRow && !parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: detailPane.actionsInset
                text: parent.activeRow ? parent.activeRow.fullText : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
              }

              Image {
                visible: !root.editing && parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: detailPane.actionsInset
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }

              // The editor stands in for the preview while it is open.
              Loader {
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                active: root.editing
                sourceComponent: editorPane
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: root.contentMargin
                anchors.right: actionRow.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: actionRow.verticalCenter
                visible: !root.editing && root.selectionCount > 0
                text: ClipboardHistory.selectionOverflows(root.history, root.selectedKeys)
                  ? root.selectionCount + " selected  ·  too large to paste, unselect some"
                  : root.selectionCount + " selected  ·  Enter pastes "
                    + (ClipboardHistory.selectionMime(root.history, root.selectedKeys) === "text/uri-list"
                      ? "as files" : "as text")
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Row {
                id: actionRow
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: Style.spacing.controlGap
                visible: !root.editing && !!detailPane.entry

                Button {
                  text: (detailPane.cursorTicked ? "Unselect" : "Select") + "  Ctrl+Enter"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.toggleSelected()
                }

                Button {
                  visible: detailPane.canEdit
                  text: "Edit  Ctrl+E"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.openEditor()
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              textFormat: Text.PlainText
              text: "󰅌"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.history.length === 0 ? "Clipboard is empty" : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
