function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 ? { type: "text", text: text } : null
  }

  if (type === "image") {
    var path = String(value.path || "")
    if (!path) return null
    var entry = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png")
    }
    if (value.capturedAt !== undefined && value.capturedAt !== null)
      entry.capturedAt = String(value.capturedAt)
    return entry
  }

  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  return "text:" + String(entry.text || "")
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    var next = []
    if (!Array.isArray(parsed)) return next

    for (var i = 0; i < parsed.length; i++) {
      var entry = normalizeEntry(parsed[i])
      if (entry) next.push(entry)
    }
    return next
  } catch (e) {
    return []
  }
}

function addEntry(history, entry, limit) {
  var normalized = normalizeEntry(entry)
  var max = limit === undefined || limit === null ? 100 : Number(limit)
  if (isNaN(max)) max = 100
  max = Math.max(0, max)
  if (!normalized) return Array.isArray(history) ? history.slice(0, max) : []
  if (max === 0) return []

  var key = entryKey(normalized)
  var next = [normalized]
  var values = Array.isArray(history) ? history : []

  for (var i = 0; i < values.length && next.length < max; i++) {
    var existing = normalizeEntry(values[i])
    if (!existing || entryKey(existing) === key) continue
    next.push(existing)
  }

  return next
}

function removeEntryAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()

  var next = values.slice()
  next.splice(target, 1)
  return next
}

function clearHistory() {
  return []
}

function parseEntryJson(line) {
  var raw = String(line || "").trim()
  if (!raw) return null
  try { return normalizeEntry(JSON.parse(raw)) } catch (e) { return null }
}

function searchableText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image screenshot " + String(entry.mime || "") + " " + String(entry.capturedAt || "")
  return String(entry.text || "") + " " + fileEntryText(entry)
}

function decodeFileUri(uri) {
  var value = String(uri || "").trim()
  if (value.indexOf("file://") !== 0) return ""

  var path = value.substring(7)
  if (path.indexOf("localhost/") === 0) path = path.substring(9)
  if (path.charAt(0) !== "/") return ""

  try { return decodeURIComponent(path) } catch (e) { return path }
}

function filePaths(entry) {
  if (!entry || entry.type !== "text") return []

  var lines = String(entry.text || "").split(/\r?\n/)
  var paths = []
  for (var i = 0; i < lines.length; i++) {
    var path = decodeFileUri(lines[i])
    if (path) paths.push(path)
  }
  return paths
}

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts.length > 0 ? parts[parts.length - 1] : String(path || "")
}

function isImagePath(path) {
  return /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(String(path || ""))
}

function fileEntryText(entry) {
  var paths = filePaths(entry)
  if (paths.length === 0) return ""
  if (paths.length === 1) return fileName(paths[0])
  return paths.length + " files"
}

function imagePreviewText(entry) {
  var timestamp = String(entry && entry.capturedAt || "")
  if (!timestamp) return "Image"

  var label = String(entry && entry.mime || "") === "image/png" ? "Screenshot" : "Image"
  return label + " from " + timestamp
}

function previewText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return imagePreviewText(entry)
  var fileText = fileEntryText(entry)
  if (fileText) return fileText
  return String(entry.text || "").replace(/\s+/g, " ")
}

function fullText(entry) {
  if (!entry) return ""
  var paths = filePaths(entry)
  if (paths.length > 0) return paths.join("\n")
  return String(entry.text || "")
}

// The picker only ever searches and renders a prefix of an entry, so scan and
// render just that much. A single huge paste otherwise costs hundreds of
// megabytes of string work on every keystroke and stalls the whole shell.
// Pasting reads the full entry back from history by index, so nothing is lost.
var displayTextLimit = 8192

function cappedEntry(entry) {
  if (!entry || entry.type !== "text" || entry.text.length <= displayTextLimit) return entry

  // Cut on a line break so a file:// URI never truncates into a bogus path.
  var cut = entry.text.lastIndexOf("\n", displayTextLimit)
  return { type: "text", text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit) }
}

function displayRows(history, query, limit) {
  var values = Array.isArray(history) ? history : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var rows = []

  for (var i = 0; i < values.length; i++) {
    // The key comes from the uncapped record: cappedEntry() may truncate the
    // text, and a key built from a truncated entry would never match the one
    // a selection stored.
    var source = normalizeEntry(values[i])
    if (!source) continue
    var entry = cappedEntry(source)
    if (needle && searchableText(entry).toLowerCase().indexOf(needle) < 0) continue

    var paths = filePaths(entry)
    var isFile = paths.length > 0
    var isImage = entry.type === "image"
    var previewPath = isImage ? String(entry.path || "") : (isFile && paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
    rows.push({
      entryType: isFile ? "file" : entry.type,
      fullText: isImage ? "" : fullText(entry),
      previewText: previewText(entry),
      previewImage: previewPath,
      path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
      mime: isImage ? String(entry.mime || "image/png") : "text/plain",
      key: entryKey(source),
      index: i
    })
    if (rows.length >= max) break
  }

  return rows
}

// A selection is a plain object used as a set of entryKey() values. Keys, not
// indices: the watcher rewrites history on every copy, saving an edit prepends a
// new entry, and filtering reshuffles rows, so an index-keyed tick would quietly
// move to another entry.
function toggleSelection(keys, key) {
  var next = {}
  var source = keys && typeof keys === "object" ? keys : {}
  for (var existing in source)
    if (existing !== key) next[existing] = true

  if (!source[key] && String(key || "").length > 0) next[key] = true
  return next
}

function selectionCount(keys) {
  var source = keys && typeof keys === "object" ? keys : {}
  var count = 0
  for (var key in source) count++
  return count
}

// History order, newest first, so the payload reads the way the list does.
// Click order would need state nothing else wants.
function selectedEntries(history, keys) {
  var values = Array.isArray(history) ? history : []
  var source = keys && typeof keys === "object" ? keys : {}
  var picked = []

  for (var i = 0; i < values.length; i++) {
    var entry = normalizeEntry(values[i])
    if (!entry) continue
    if (source[entryKey(entry)]) picked.push(entry)
  }
  return picked
}

function removeSelected(history, keys) {
  var values = Array.isArray(history) ? history : []
  var source = keys && typeof keys === "object" ? keys : {}
  var next = []

  for (var i = 0; i < values.length; i++) {
    var entry = normalizeEntry(values[i])
    if (!entry) continue
    if (!source[entryKey(entry)]) next.push(entry)
  }
  return next
}

function fileUri(path) {
  return "file://" + encodeURI(String(path || ""))
}

// text/uri-list only when every selected entry is a file or an image: a uri-list
// payload is invisible to a plain text editor, so anything mixed stays text/plain
// and contributes image paths as file:// lines. Kept separate from the join so a
// label can ask what a paste would be without building the payload.
function selectionMime(history, keys) {
  var entries = selectedEntries(history, keys)
  if (entries.length === 0) return ""

  for (var i = 0; i < entries.length; i++) {
    if (entries[i].type === "image") continue
    if (filePaths(entries[i]).length > 0) continue
    return ""
  }
  return "text/uri-list"
}

// Collapses a selection into the one payload a Wayland clipboard can hold. Lines
// join with \n rather than the CRLF of RFC 2483 because filePaths() parses \n
// back, which keeps the copy round-tripping through our own history.
function joinSelection(history, keys) {
  var entries = selectedEntries(history, keys)
  var lines = []

  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    lines.push(entry.type === "image" ? fileUri(entry.path) : fullText(entry))
  }

  return {
    text: lines.join("\n"),
    mime: selectionMime(history, keys),
    count: entries.length
  }
}

// Rows are intentionally capped for rendering, but contextual actions act on
// clipboard entries rather than previews. Rebuild the action payload from the
// original history record so an extension can never save a truncated value.
function entryForAction(history, historyIndex) {
  var index = Number(historyIndex)
  var values = Array.isArray(history) ? history : []
  if (isNaN(index) || index < 0 || index >= values.length) return null

  var entry = normalizeEntry(values[index])
  if (!entry) return null

  var paths = filePaths(entry)
  var isFile = paths.length > 0
  var isImage = entry.type === "image"
  return {
    type: isFile ? "file" : entry.type,
    text: isImage ? "" : fullText(entry),
    path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
    mime: isImage ? String(entry.mime || "image/png") : "text/plain",
    historyIndex: index
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeEntry: normalizeEntry,
    entryKey: entryKey,
    parseHistory: parseHistory,
    addEntry: addEntry,
    removeEntryAt: removeEntryAt,
    clearHistory: clearHistory,
    parseEntryJson: parseEntryJson,
    searchableText: searchableText,
    previewText: previewText,
    imagePreviewText: imagePreviewText,
    filePaths: filePaths,
    fileEntryText: fileEntryText,
    fullText: fullText,
    displayRows: displayRows,
    entryForAction: entryForAction,
    toggleSelection: toggleSelection,
    selectionCount: selectionCount,
    selectedEntries: selectedEntries,
    removeSelected: removeSelected,
    selectionMime: selectionMime,
    joinSelection: joinSelection
  }
}
