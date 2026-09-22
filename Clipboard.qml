import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool clearConfirmOpen: false
  property var history: []

  property string historyPath: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history.json"
  // Use this plugin's own capture script (resolved relative to this QML file)
  // instead of the packaged one, so the bounded capture path shipped here is
  // the one that runs.
  property string captureScript: String(Qt.resolvedUrl("capture.sh")).replace(/^file:\/\//, "")
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
  property int displayRevision: 0

  // Host-injected: the shell root and this plugin's manifest, used to read
  // this plugin's own settings from shell.json's `plugins[]`.
  property var shell
  property var manifest

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "protoavatar.clipbook"
  property var pluginConfig: root.readPluginConfig(shell ? shell.shellConfig : null)

  readonly property int historyLimit: {
    var value = Number(root.pluginConfig.historyLimit)
    return (isFinite(value) && value > 0) ? Math.floor(value) : 500
  }
  readonly property string externalEditor: root.pluginConfig.externalEditor === undefined
    ? "omawrite" : String(root.pluginConfig.externalEditor)
  readonly property bool markdownPreview: root.pluginConfig.markdownPreview !== false
  readonly property bool showCategoryColors: root.pluginConfig.showCategoryColors !== false

  readonly property string runtimeDir: {
    var base = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    if (base.length === 0) base = String(Quickshell.env("HOME") || "/tmp") + "/.cache"
    return base + "/protoavatar.clipbook"
  }
  property string externalEditPath: ""
  property int externalEditHistoryIndex: -1
  property string externalEditSeed: ""
  property bool externalEditArmed: false
  property string externalEditLast: ""
  property string lastSavedJson: ""

  property var themePalette: ({})
  property bool editing: false
  property string editKind: ""
  property int editRowIndex: -1
  property int editHistoryIndex: -1
  property string editSeed: ""
  property string editTitle: ""

  function readPluginConfig(shellConfig) {
    var list = shellConfig && Array.isArray(shellConfig.plugins) ? shellConfig.plugins : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (entry && String(entry.id) === root.pluginId) return entry
    }
    return {}
  }

  // The theme's named colours (red, green, blue, …) live in colors.toml, which
  // the Color singleton does not expose. Read them here so row accents follow
  // whatever theme is active instead of hardcoding hex.
  function loadThemePalette(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!match) continue
      next[match[1]] = match[2]
    }
    root.themePalette = next
  }

  function paletteColor(name, fallback) {
    var value = root.themePalette[name]
    return (typeof value === "string" && value.length > 0) ? value : fallback
  }

  function categoryColor(category) {
    switch (category) {
      case "note": return root.paletteColor("orange", Color.accent)
      case "link": return root.paletteColor("blue", Color.accent)
      case "email": return root.paletteColor("green", Color.accent)
      case "code": return root.paletteColor("orange", Color.urgent)
      case "file": return root.paletteColor("cyan", Color.accent)
      case "image": return root.paletteColor("yellow", Color.urgent)
      case "color": return root.paletteColor("magenta", Color.accent)
      default: return Color.muted
    }
  }

  function categoryGlyph(category) {
    switch (category) {
      case "note": return "󰎞"
      case "image": return "󰋩"
      case "file": return "󰈙"
      case "link": return "󰌷"
      case "color": return "󰏘"
      case "email": return "󰇮"
      case "code": return "󰅩"
      default: return "󰅌"
    }
  }

  // A hex-colour entry renders its own colour instead of a glyph.
  function entrySwatch(category, text) {
    if (category !== "color") return ""
    var value = String(text || "").trim()
    return /^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value) ? value : ""
  }

  // Small self-report for bug reports and to confirm which build is loaded.
  function statusInfo() {
    var first = displayModel.count > 0 ? displayModel.get(0) : null
    return "clipbook rows=" + displayModel.count
      + " palette=" + Object.keys(root.themePalette).length
      + " limit=" + root.historyLimit
      + " editor=" + (root.externalEditor.length > 0 ? root.externalEditor : "(system)")
      + " md=" + root.markdownPreview
      + " colors=" + root.showCategoryColors
      + " first=" + (first ? (first.category + ":" + String(first.previewText).slice(0, 24)) : "none")
  }

  // --------------------------------------------------------------- editing
  //
  // One inline editor serves three purposes: editing a text entry, writing a
  // new note, and annotating any entry. The key catcher steps aside while it
  // is open (see `if (root.editing) return` below) so the TextEdit gets keys.

  function beginEdit(kind, rowIndex, historyIndex, seedText, buffer, title) {
    root.editKind = kind
    root.editRowIndex = rowIndex
    root.editHistoryIndex = historyIndex
    root.editSeed = seedText
    root.editTitle = title
    root.editing = true
    root.cursorActive = false
    Qt.callLater(function() {
      editorField.text = buffer
      editorField.cursorPosition = editorField.length
      editorField.forceActiveFocus()
    })
  }

  // New clipboard captures prepend entries and shift the display while the
  // editor is open, so the row index captured at edit start can go stale.
  // Re-localize the target by its original text before writing.
  function resolveEditIndex() {
    var idx = root.editHistoryIndex
    if (idx >= 0 && idx < root.history.length) {
      var entry = ClipboardHistory.normalizeEntry(root.history[idx])
      if (entry && entry.type === "text" && entry.text === root.editSeed) return idx
    }
    return root.findHistoryIndexByText(root.editSeed)
  }

  function startEditEntry() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (row.entryType === "image") return
    root.beginEdit("entry", root.selectedIndex, row.historyIndex, row.fullText, row.fullText, "Edit entry")
  }

  function startNewNote() {
    root.beginEdit("note", -1, -1, "", "", "New note")
  }

  function startAnnotation() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.beginEdit("annotation", root.selectedIndex, row.historyIndex, row.fullText, String(row.annotation || ""), "Annotation")
  }

  function commitEdit() {
    var text = editorField.text
    if (root.editKind === "entry") {
      var idx = root.resolveEditIndex()
      if (idx >= 0) root.history = ClipboardHistory.updateText(root.history, idx, text)
    } else if (root.editKind === "note") {
      if (String(text).trim().length > 0)
        root.history = ClipboardHistory.addEntry(root.history, { type: "text", text: text, source: "note" }, root.historyLimit)
    } else if (root.editKind === "annotation") {
      var annotatedIdx = root.resolveEditIndex()
      if (annotatedIdx >= 0) root.history = ClipboardHistory.setAnnotation(root.history, annotatedIdx, text)
    }
    root.saveHistory()
    root.editing = false
    root.editKind = ""
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelEdit() {
    root.editing = false
    root.editKind = ""
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Paste the live system clipboard into the editor. Read through the
  // Quickshell singleton: it is populated while a quickshell window (this
  // overlay) has focus, and reading it never triggers the capture watchers.
  function insertClipboardText() {
    var clip = String(Quickshell.clipboardText || "")
    if (clip.length === 0) return
    editorField.insert(editorField.cursorPosition, clip)
  }

  function toggleSelectedPin() {
    if (!root.cursorActive || displayModel.count === 0) return
    var row = displayModel.get(root.selectedIndex)
    var historyIndex = row.historyIndex
    root.history = ClipboardHistory.togglePin(root.history, historyIndex)
    root.saveHistory()
    root.rebuildDisplay()
    root.selectByHistoryIndex(historyIndex)
  }

  function selectByHistoryIndex(historyIndex) {
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).historyIndex === historyIndex) {
        root.selectedIndex = i
        root.cursorActive = true
        resultList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  function open(payloadJson) {
    root.editing = false
    root.editKind = ""
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.editing = false
    root.editKind = ""
    root.cancelClearHistory()
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
    var text = String(raw || "")
    var parsed = ClipboardHistory.parseHistory(text)
    var corrupt = parsed.length === 0 && text.trim().length > 2 && text.trim() !== "[]"
    root.lastSavedJson = text
    // A corrupt main file must not blank the UI (or get persisted as empty)
    // before the sidecar is checked. Keep the in-memory history until then.
    if (corrupt) {
      historyBackupFile.reload()
      return
    }
    root.history = parsed
    if (root.opened) root.rebuildDisplay()
  }

  function loadBackup(raw) {
    if (root.history.length > 0) return
    var parsed = ClipboardHistory.parseHistory(raw)
    if (parsed.length === 0) return
    root.history = parsed
    root.rebuildDisplay()
    root.lastSavedJson = "" // do not overwrite the good backup with corrupt text
    root.saveHistory()
  }

  function saveHistory() {
    // Enforce the cap on every save: addEntry is not the only mutation path
    // (updateText/setAnnotation/loadHistory can leave the array above the
    // limit, e.g. after the user lowers historyLimit). trimHistory keeps every
    // protected entry and caps only the unprotected ones.
    root.history = ClipboardHistory.trimHistory(root.history, root.historyLimit)
    var next = JSON.stringify(root.history, null, 2) + "\n"
    // Keep the previous content in a sidecar so a bad write never loses
    // everything: `clipboard-history.json.bak` always holds the last state.
    if (root.lastSavedJson.length > 0 && root.lastSavedJson !== next)
      historyBackupFile.setText(root.lastSavedJson)
    historyFile.setText(next)
    root.lastSavedJson = next
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = ClipboardHistory.addEntry(root.history, normalized, root.historyLimit)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    root.addClipboardEntry(ClipboardHistory.parseEntryJson(line))
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
        historyIndex: row.index,
        category: row.category,
        pinned: row.pinned,
        annotation: row.annotation || ""
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })

    root.displayRevision++
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
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
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

  function textIsOpenable(text) {
    var value = String(text || "").trim()
    if (value.length === 0 || value.indexOf("\n") >= 0) return false
    if (/^https?:\/\/\S+$/i.test(value)) return true
    if (/^www\.[^\s/]+\.[^\s]+$/i.test(value)) return true
    return /^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}(\/\S*)?$/i.test(value)
  }

  function openSelected(row) {
    if (!row) return
    if (row.entryType === "image") {
      // Edit a copy so the original entry survives; the edited image is
      // stored as a new history entry when the editor closes.
      root.opened = false
      imageEditProc.sourcePath = String(row.path || "")
      imageEditProc.running = true
      return
    }
    // A link/domain opens in the browser; anything else opens in the external
    // editor with write-back (Ctrl+Shift+E was folded into Alt+Enter).
    if (root.textIsOpenable(row.fullText)) {
      root.opened = false
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
      return
    }
    root.editSelectedExternally(row)
  }

  function finishImageEdit(json) {
    var line = String(json || "").trim()
    if (line.length > 0) root.addClipboardJson(line)
    root.open("{}")
  }

  // ------------------------------------------------------- external editor
  //
  // Edit a text entry or note in an external editor. The overlay closes, the
  // text is written to a runtime file, the editor opens on it, and every save
  // is written back to the same history entry. The file is watched, so this
  // does not depend on the editor process exiting (omawrite is launched
  // detached and has no reliable exit signal).

  function editSelectedExternally(row) {
    var target = row
    if (!target) {
      if (!root.cursorActive || displayModel.count === 0) return
      target = displayModel.get(root.selectedIndex)
    }
    if (!target) return
    if (target.entryType === "image") { root.openSelected(target); return }
    root.externalEditHistoryIndex = target.historyIndex
    root.externalEditPath = root.runtimeDir + "/edit.md"
    root.externalEditSeed = target.fullText
    root.externalEditLast = target.fullText
    root.externalEditArmed = false
    root.opened = false
    externalPrepareProc.running = true
  }

  function findHistoryIndexByText(text) {
    if (!text) return -1
    for (var i = 0; i < root.history.length; i++) {
      var entry = ClipboardHistory.normalizeEntry(root.history[i])
      if (entry && entry.type === "text" && entry.text === text) return i
    }
    return -1
  }

  function externalEditLoaded(raw) {
    if (!root.externalEditArmed) return
    var text = String(raw || "")
    if (text.trim().length === 0) return
    if (text === root.externalEditLast) return
    // The entry may have shifted (new captures prepend), so fall back to
    // finding it by its last known text instead of trusting the index.
    var idx = root.externalEditHistoryIndex
    if (idx < 0 || idx >= root.history.length
        || (root.history[idx].text !== root.externalEditSeed && root.history[idx].text !== root.externalEditLast)) {
      idx = root.findHistoryIndexByText(root.externalEditSeed)
      if (idx < 0) idx = root.findHistoryIndexByText(root.externalEditLast)
    }
    if (idx < 0) return
    root.history = ClipboardHistory.updateText(root.history, idx, text)
    root.externalEditHistoryIndex = idx
    root.externalEditSeed = text
    root.externalEditLast = text
    root.saveHistory()
  }

  Component.onCompleted: initProc.running = true

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    // A transient read failure must not wipe the in-memory history: on first
    // run it is already empty, and on any later failure keeping what we have
    // is strictly safer than resetting to [].
    onFileChanged: reload()
  }

  // Sidecar copy of the previous history, written just before each save.
  FileView {
    id: historyBackupFile
    path: root.historyPath + ".bak"
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadBackup(text())
  }

  FileView {
    id: themePaletteFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadThemePalette(text())
    onFileChanged: reload()
  }

  // colors.toml sits behind the current/theme symlink; a theme switch can swap
  // the target without a change event on this path, so re-read whenever the
  // singleton's accent moves.
  Connections {
    target: Color
    function onAccentChanged() { themePaletteFile.reload() }
  }

  // Reap watchers left behind by a previous shell instance, then start our
  // own. The pdeathsig on the watchers makes the kernel kill them whenever
  // the shell exits, however it exits, so no further lifecycle management.
  Process {
    id: initProc
    command: ["pkill", "-f", "wl-paste .*--watch .*clipbook/capture\\.sh"]
    onExited: {
      currentProc.running = true
      textWatchProc.running = true
      imageWatchProc.running = true
    }
  }

  Process {
    id: currentProc
    command: [root.captureScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.addClipboardJson(text)
    }
  }

  Process {
    id: textWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  // Edit an image copy. tensaku-edit saves in place, so we hand it a copy in
  // the runtime dir and store the result as a new history entry, leaving the
  // original entry untouched. Only a changed copy is stored.
  Process {
    id: imageEditProc
    property string sourcePath: ""
    command: ["bash", "-c",
      "src=\"$1\"; cap=\"$2\"; dir=\"${XDG_RUNTIME_DIR:-$HOME/.cache}/protoavatar.clipbook\"; "
        + "mkdir -p \"$dir\"; tmp=\"$dir/edit.png\"; "
        + "cp -f \"$src\" \"$tmp\" || exit 1; "
        + "tensaku-edit \"$tmp\" >/dev/null 2>&1 || true; "
        + "if [[ -s \"$tmp\" ]] && ! cmp -s \"$src\" \"$tmp\"; then cat \"$tmp\" | \"$cap\" image/png; fi; "
        + "rm -f \"$tmp\"",
      "clipbook-edit", sourcePath, root.captureScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishImageEdit(text)
    }
  }

  // Runtime file for external text editing; watched so saves flow back into
  // the entry without waiting on the editor process.
  FileView {
    id: externalEditFile
    path: root.externalEditPath
    blockLoading: root.externalEditPath.length === 0
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.externalEditLoaded(text())
    onFileChanged: reload()
  }

  Process {
    id: externalPrepareProc
    command: ["bash", "-c", "mkdir -p \"$1\"", "clipbook-edit", root.runtimeDir]
    onExited: {
      externalEditFile.setText(root.externalEditSeed)
      root.externalEditArmed = true
      externalEditProc.running = true
    }
  }

  Process {
    id: externalEditProc
    command: root.externalEditor.length > 0
      ? ["setsid", "uwsm-app", "--", root.externalEditor, root.externalEditPath]
      : ["omarchy-launch-editor", root.externalEditPath]
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
        z: (root.clearConfirmOpen || root.editing) ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }
          // The inline editor owns the keyboard while it is open.
          if (root.editing) return

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
            root.toggleSelectedPin()
            event.accepted = true
          } else if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
            root.startNewNote()
            event.accepted = true
          } else if ((event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier)) || event.key === Qt.Key_F2) {
            root.startEditEntry()
            event.accepted = true
          } else if (event.key === Qt.Key_M && (event.modifiers & Qt.ControlModifier)) {
            root.startAnnotation()
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
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
            if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
            else if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.copyIndex(root.selectedIndex)
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

        // Inline editor: editing a text entry, writing a note, or annotating.
        Rectangle {
          id: editorOverlay
          visible: root.editing
          anchors.fill: parent
          z: 30
          color: root.scrim

          BorderSurface {
            id: editorCard
            width: Math.min(Style.space(720), parent.width - Style.space(40))
            height: Math.min(Style.space(420), parent.height - Style.space(40))
            anchors.centerIn: parent
            radius: root.cornerRadius
            color: root.background
            borderSpec: root.borderSpec
            padding: root.contentMargin

            Item {
              anchors.fill: parent
              anchors.topMargin: editorCard.contentTopInset
              anchors.rightMargin: editorCard.contentRightInset
              anchors.bottomMargin: editorCard.contentBottomInset
              anchors.leftMargin: editorCard.contentLeftInset

              Text {
                id: editTitleLabel
                textFormat: Text.PlainText
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                text: root.editTitle
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: editHint
                textFormat: Text.PlainText
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                text: "Enter saves · Shift+Enter new line · Ctrl+V paste clipboard · Esc cancel"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Rectangle {
                id: editBox
                anchors.top: editTitleLabel.bottom
                anchors.topMargin: root.contentSpacing
                anchors.bottom: editHint.top
                anchors.bottomMargin: root.contentSpacing
                anchors.left: parent.left
                anchors.right: parent.right
                radius: root.cornerRadius
                color: Util.alpha(root.foreground, 0.06)
                border.color: Util.alpha(root.foreground, 0.18)
                border.width: Style.normalBorderWidth

                Flickable {
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  clip: true
                  contentWidth: width
                  contentHeight: Math.max(editorField.height, height)
                  boundsBehavior: Flickable.StopAtBounds

                  TextEdit {
                    id: editorField
                    width: parent.width
                    color: root.foreground
                    selectionColor: root.selectedBackground
                    selectedTextColor: root.selectedText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    persistentSelection: true

                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.cancelEdit()
                        event.accepted = true
                      } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                 && !(event.modifiers & Qt.ShiftModifier)) {
                        root.commitEdit()
                        event.accepted = true
                      } else if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
                        root.insertClipboardText()
                        event.accepted = true
                      }
                    }
                  }
                }
              }
            }
          }
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
            id: badge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Clipbook"
            color: root.foreground
            opacity: 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: badge.left
            anchors.rightMargin: Style.space(12)
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
          height: parent.height - root.headerHeight - footerBox.height - root.contentSpacing

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

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage
                  required property string category
                  required property bool pinned
                  required property string annotation

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                  readonly property color accentColor: root.showCategoryColors ? root.categoryColor(category) : Util.alpha(root.foreground, 0.45)
                  readonly property string swatch: root.entrySwatch(category, previewText)
                  readonly property int annotationHeight: annotation.length > 0 ? Style.font.caption + Style.space(6) : 0

                  width: ListView.view.width
                  height: root.rowHeight + annotationHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  // Type accent bar.
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.topMargin: Style.space(9)
                    anchors.bottomMargin: Style.space(9)
                    width: Style.space(3)
                    radius: width / 2
                    color: row.accentColor
                    opacity: row.hasCursor ? 1.0 : 0.7
                  }

                  Row {
                    id: leading
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)

                    // A hex-colour entry shows its own colour; everything else
                    // shows a type glyph.
                    Rectangle {
                      visible: row.swatch.length > 0
                      width: visible ? Style.space(18) : 0
                      height: Style.space(18)
                      radius: Style.space(4)
                      color: row.swatch.length > 0 ? row.swatch : "transparent"
                      border.color: Util.alpha(root.foreground, 0.35)
                      border.width: Style.normalBorderWidth
                    }

                    Text {
                      visible: row.swatch.length === 0
                      width: visible ? Style.space(18) : 0
                      text: root.categoryGlyph(row.category)
                      color: row.accentColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Image {
                      visible: row.previewImage.length > 0
                      width: visible ? Style.space(28) : 0
                      height: Style.space(28)
                      source: row.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }
                  }

                  Text {
                    id: pinGlyph
                    visible: row.pinned
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰐃"
                    color: row.accentColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    anchors.left: leading.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: pinGlyph.visible ? pinGlyph.left : parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: row.previewText
                      color: row.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      opacity: row.entryType === "image" || row.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: row.annotation.length > 0
                      width: parent.width
                      text: row.annotation
                      color: row.accentColor
                      opacity: 0.9
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
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
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }
                }
              }
            }

            Item {
              id: previewPane
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: {
                var rev = root.displayRevision // binding dependency, see segments
                if (displayModel.count === 0 || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return null
                return displayModel.get(root.selectedIndex)
              }

              readonly property bool markdownMode: activeRow !== null && activeRow.category === "note"
                && root.markdownPreview && !activeRow.previewImage

              // Notes are split into prose / code / quote so code blocks get a
              // real box (Qt's MarkdownText only monospaces them) and quotes a
              // left bar. Everything else is left to Qt's Markdown renderer.
              property var segments: {
                var rev = root.displayRevision
                if (!markdownMode) return []
                return ClipboardHistory.splitMarkdown(activeRow.fullText)
              }

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Flickable {
                id: textPreview
                visible: previewPane.activeRow !== null && !previewPane.activeRow.previewImage && !previewPane.markdownMode
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: Style.space(6)
                clip: true
                contentWidth: width
                contentHeight: textPreviewText.height
                boundsBehavior: Flickable.StopAtBounds

                Text {
                  id: textPreviewText
                  width: parent.width
                  textFormat: Text.PlainText
                  text: previewPane.activeRow ? previewPane.activeRow.fullText : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  wrapMode: Text.WrapAnywhere
                }
              }

              // Thin scroll hint, shown only while the pane overflows.
              Rectangle {
                visible: textPreview.visible && textPreview.contentHeight > textPreview.height + 1
                anchors.right: parent.right
                width: Style.space(3)
                radius: width / 2
                color: Util.alpha(root.foreground, 0.25)
                height: Math.max(Style.space(24), parent.height * textPreview.height / Math.max(1, textPreview.contentHeight))
                y: Math.max(0, Math.min(parent.height - height, textPreview.contentY / Math.max(1, textPreview.contentHeight) * parent.height))
              }

              Flickable {
                id: markdownPreview
                visible: previewPane.markdownMode
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: Style.space(6)
                clip: true
                contentWidth: width
                contentHeight: markdownColumn.height
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: markdownColumn
                  width: parent.width
                  spacing: Style.space(8)

                  Repeater {
                    model: previewPane.segments

                    delegate: Item {
                      required property var modelData

                      width: markdownColumn.width
                      height: modelData.kind === "code" ? codeBox.height
                            : (modelData.kind === "quote" ? quoteBox.height : proseText.implicitHeight)

                      Text {
                        id: proseText
                        visible: modelData.kind === "markdown"
                        width: parent.width
                        textFormat: Text.MarkdownText
                        text: modelData.kind === "markdown" ? modelData.text : ""
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        wrapMode: Text.Wrap
                        onLinkActivated: function(link) { Quickshell.execDetached(["omarchy-launch-browser", link]) }
                      }

                      Rectangle {
                        id: quoteBox
                        visible: modelData.kind === "quote"
                        width: parent.width
                        height: visible ? quoteText.implicitHeight + Style.space(8) : 0
                        color: "transparent"

                        Rectangle {
                          anchors.left: parent.left
                          anchors.top: parent.top
                          anchors.bottom: parent.bottom
                          width: Style.space(3)
                          radius: width / 2
                          color: Util.alpha(root.foreground, 0.3)
                        }

                        Text {
                          id: quoteText
                          anchors.left: parent.left
                          anchors.leftMargin: Style.space(12)
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.MarkdownText
                          text: modelData.kind === "quote" ? modelData.text : ""
                          color: root.foreground
                          opacity: 0.85
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.title
                          wrapMode: Text.Wrap
                          onLinkActivated: function(link) { Quickshell.execDetached(["omarchy-launch-browser", link]) }
                        }
                      }

                      Rectangle {
                        id: codeBox
                        visible: modelData.kind === "code"
                        width: parent.width
                        height: visible ? codeText.implicitHeight + Style.space(16) : 0
                        radius: Style.space(4)
                        color: Util.alpha(root.foreground, 0.08)
                        border.color: Util.alpha(root.foreground, 0.12)
                        border.width: Style.normalBorderWidth

                        Text {
                          id: codeText
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.space(8)
                          anchors.rightMargin: Style.space(8)
                          textFormat: Text.PlainText
                          text: modelData.kind === "code" ? modelData.text : ""
                          color: root.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          wrapMode: Text.WrapAnywhere
                        }
                      }
                    }
                  }
                }
              }

              Rectangle {
                visible: markdownPreview.visible && markdownPreview.contentHeight > markdownPreview.height + 1
                anchors.right: parent.right
                width: Style.space(3)
                radius: width / 2
                color: Util.alpha(root.foreground, 0.25)
                height: Math.max(Style.space(24), parent.height * markdownPreview.height / Math.max(1, markdownPreview.contentHeight))
                y: Math.max(0, Math.min(parent.height - height, markdownPreview.contentY / Math.max(1, markdownPreview.contentHeight) * parent.height))
              }

              Image {
                visible: parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: 0
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
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

        // Same breathing room above as the card's bottom padding, so the hint
        // block reads as vertically centred instead of hugging the list.
        Item {
          id: footerBox
          width: parent.width
          height: footer.implicitHeight + Math.max(0, card.contentBottomInset - root.contentSpacing)

          Text {
            id: footer
            textFormat: Text.PlainText
            width: parent.width
            anchors.top: parent.top
            anchors.topMargin: Math.max(0, card.contentBottomInset - root.contentSpacing)
            text: "↑↓ move · Home/End · Enter paste · Shift+Enter copy · Alt+Enter open · Del delete · Esc close\nCtrl+P pin · Ctrl+N note · Ctrl+E edit · Ctrl+M annotate · Shift+Del clear"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.NoWrap
            lineHeight: 1.25
          }
        }
      }
    }
  }
}
