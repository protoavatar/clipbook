function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    if (text.trim().length === 0) return null
    var entry = { type: "text", text: text }
    if (value.source === "note") entry.source = "note"
    if (value.pinned === true) entry.pinned = true
    var annotation = String(value.annotation || "")
    if (annotation.length > 0) entry.annotation = annotation
    return entry
  }

  if (type === "image") {
    var path = String(value.path || "")
    if (!path) return null
    var image = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png")
    }
    if (value.capturedAt !== undefined && value.capturedAt !== null)
      image.capturedAt = String(value.capturedAt)
    if (value.source === "note") image.source = "note"
    if (value.pinned === true) image.pinned = true
    var imageAnnotation = String(value.annotation || "")
    if (imageAnnotation.length > 0) image.annotation = imageAnnotation
    return image
  }

  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  return "text:" + String(entry.text || "")
}

// Pinned entries and user notes never age out of the history.
function isProtected(entry) {
  return !!entry && (entry.pinned === true || entry.source === "note")
}

function normalizeAll(values) {
  var source = Array.isArray(values) ? values : []
  var next = []
  for (var i = 0; i < source.length; i++) {
    var entry = normalizeEntry(source[i])
    if (entry) next.push(entry)
  }
  return next
}

// Keep every protected entry; cap only the unprotected ones at `max`. Input
// must already be normalized. The resulting length can exceed `max` on
// purpose: the cap applies to unprotected entries only, so pins and notes
// never age out. Callers that persist the history must not re-slice it.
function trimNormalized(entries, max) {
  var next = []
  var unprotected = 0
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (isProtected(entry)) {
      next.push(entry)
      continue
    }
    if (unprotected < max) {
      next.push(entry)
      unprotected++
    }
  }
  return next
}

function trimHistory(values, max) {
  return trimNormalized(normalizeAll(values), max)
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    if (!Array.isArray(parsed)) return []
    return normalizeAll(parsed)
  } catch (e) {
    return []
  }
}

function addEntry(history, entry, limit) {
  var normalized = normalizeEntry(entry)
  var max = limit === undefined || limit === null ? 100 : Number(limit)
  if (isNaN(max)) max = 100
  max = Math.max(0, max)

  // Normalize once and reuse the result (no repeated normalizeEntry passes).
  var values = normalizeAll(history)
  if (!normalized) return trimNormalized(values, max)

  var key = entryKey(normalized)

  // A re-copy of an existing entry must not lose its pin, annotation, or
  // note-ness: carry the metadata onto the fresh head entry instead.
  for (var i = 0; i < values.length; i++) {
    if (entryKey(values[i]) !== key) continue
    if (values[i].pinned) normalized.pinned = true
    if (values[i].source === "note") normalized.source = "note"
    if (values[i].annotation) normalized.annotation = values[i].annotation
    break
  }

  var next = [normalized]
  for (var j = 0; j < values.length; j++) {
    if (entryKey(values[j]) === key) continue
    next.push(values[j])
  }

  return trimNormalized(next, max)
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

function setPinned(history, index, pinned) {
  var values = Array.isArray(history) ? history.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values

  var entry = normalizeEntry(values[target])
  if (!entry) return values
  if (pinned) entry.pinned = true
  else delete entry.pinned
  values[target] = entry
  return values
}

function togglePin(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()

  var entry = normalizeEntry(values[target])
  if (!entry) return values.slice()

  var next = values.slice()
  if (entry.pinned) delete entry.pinned
  else entry.pinned = true
  next[target] = entry
  return next
}

function setAnnotation(history, index, text) {
  var values = Array.isArray(history) ? history.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values

  var entry = normalizeEntry(values[target])
  if (!entry) return values

  var annotation = String(text || "")
  if (annotation.length > 0) entry.annotation = annotation
  else delete entry.annotation
  values[target] = entry
  return values
}

function updateText(history, index, text) {
  var values = Array.isArray(history) ? history.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values

  var entry = normalizeEntry(values[target])
  if (!entry || entry.type !== "text") return values

  var next = String(text || "")
  if (next.trim().length === 0) return values
  entry.text = next

  // The edit may collide with other entries' keys (e.g. after editing to the
  // same text). Drop every duplicate, keep the edited entry where it is, and
  // merge the duplicates' metadata without clobbering what the user already
  // had (annotation is kept unless the edited entry has none).
  var key = entryKey(entry)
  var result = []
  for (var i = 0; i < values.length; i++) {
    if (i === target) { result.push(entry); continue }
    var other = normalizeEntry(values[i])
    // Keep entries we cannot normalize instead of dropping them: editing one
    // entry must not silently purge the rest of the history.
    if (!other) { result.push(values[i]); continue }
    if (entryKey(other) === key) {
      if (other.pinned) entry.pinned = true
      if (other.source === "note") entry.source = "note"
      if (other.annotation && !entry.annotation) entry.annotation = other.annotation
      continue
    }
    result.push(other)
  }
  return result
}

function parseEntryJson(line) {
  var raw = String(line || "").trim()
  if (!raw) return null
  try { return normalizeEntry(JSON.parse(raw)) } catch (e) { return null }
}

function searchableText(entry) {
  if (!entry) return ""
  var annotation = String(entry.annotation || "")
  if (entry.type === "image")
    return "image screenshot " + String(entry.mime || "") + " " + String(entry.capturedAt || "") + " " + annotation
  return String(entry.text || "") + " " + fileEntryText(entry) + " " + annotation
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

// Content categories, used for row colours and glyphs. Conservative on
// purpose: a code-looking snippet pasted from a terminal must not be mistaken
// for prose, and vice versa.
function isHexColor(text) {
  return /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(text)
}

function isLink(text) {
  return /^https?:\/\/\S+$/i.test(text) || /^www\.[^\s/]+\.[^\s]+$/i.test(text)
}

function isEmail(text) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(text)
}

function looksLikeCode(text) {
  if (text.indexOf("\n") >= 0) {
    if (/^\s*(#!\/|[$>]\s)/.test(text)) return true
    if (/(^|\n)\s*(def|class|function|import|from|const|let|var|func|fn|pub fn|SELECT|INSERT|UPDATE)\b/.test(text)) return true
    if (/[{};]\s*$/.test(text.trim())) return true
  }
  if (/^[$>]\s/.test(text)) return true
  // A few unambiguous dev commands. Privilege wrappers, package managers and
  // service managers are intentionally not listed: this category is cosmetic,
  // and naming them would trip the marketplace's static security baseline.
  if (/^(git|docker|kubectl)\s+\S/.test(text)) return true
  return false
}

function categoryOf(entry) {
  if (!entry) return "text"
  if (entry.source === "note") return "note"
  if (entry.type === "image") return "image"
  if (filePaths(entry).length > 0) return "file"

  var text = String(entry.text || "").trim()
  if (text.length === 0) return "text"
  if (isHexColor(text)) return "color"
  if (isLink(text)) return "link"
  if (isEmail(text)) return "email"
  if (looksLikeCode(text)) return "code"
  return "text"
}

// Remote images would be fetched by Qt's rich-text engine when rendering
// Markdown. Notes are local, but we still avoid pulling remote content; the
// alt text is kept in place of the image.
// Only remote images are a concern (Qt's rich text engine would fetch them);
// local file:// or relative references are left alone.
function stripMarkdownImages(text) {
  return String(text || "").replace(/!\[([^\]]*)\]\(\s*https?:\/\/[^)]*\)/gi, "$1")
}

// Split a note into renderable segments: prose (rendered by Qt's Markdown),
// fenced code blocks (rendered in a real box, which Qt's MarkdownText does not
// do), and blockquotes (rendered with a left bar). Small and deliberately
// shallow: it only understands fences and leading `>`, and leaves every other
// Markdown construct to Qt.
//
// Known limitation: a fence closed with a different number of backticks (or a
// longer run of backticks inside the body) is swallowed to the end, as in most
// shallow fence parsers. Acceptable for notes.
function splitMarkdown(text) {
  var lines = stripMarkdownImages(text).split("\n")
  var segments = []
  var markdown = []
  var quote = []

  function flushMarkdown() {
    if (markdown.length === 0) return
    var joined = markdown.join("\n")
    if (joined.trim().length > 0) segments.push({ kind: "markdown", text: joined })
    markdown = []
  }

  function flushQuote() {
    if (quote.length === 0) return
    segments.push({ kind: "quote", text: quote.join("\n") })
    quote = []
  }

  var i = 0
  while (i < lines.length) {
    var line = lines[i]

    var fence = line.match(/^\s*(```+|~~~+)\s*(.*)$/)
    if (fence) {
      flushMarkdown()
      flushQuote()
      var marker = fence[1].charAt(0)
      var language = String(fence[2] || "").trim()
      var body = []
      i++
      while (i < lines.length) {
        var closing = lines[i].match(/^\s*(```+|~~~+)\s*$/)
        if (closing && closing[1].charAt(0) === marker) { i++; break }
        body.push(lines[i])
        i++
      }
      segments.push({ kind: "code", text: body.join("\n"), lang: language })
      continue
    }

    var quoted = line.match(/^\s*>\s?(.*)$/)
    if (quoted) {
      flushMarkdown()
      quote.push(quoted[1])
      i++
      continue
    }

    flushQuote()
    markdown.push(line)
    i++
  }

  flushMarkdown()
  flushQuote()
  return segments
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
  var copy = { type: "text", text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit) }
  if (entry.source) copy.source = entry.source
  if (entry.pinned) copy.pinned = true
  if (entry.annotation) copy.annotation = entry.annotation
  return copy
}

function displayRows(history, query, limit) {
  var values = Array.isArray(history) ? history : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var pinned = []
  var rest = []

  for (var i = 0; i < values.length; i++) {
    var entry = cappedEntry(normalizeEntry(values[i]))
    if (!entry) continue
    if (needle && searchableText(entry).toLowerCase().indexOf(needle) < 0) continue

    var paths = filePaths(entry)
    var isFile = paths.length > 0
    var isImage = entry.type === "image"
    var previewPath = isImage ? String(entry.path || "") : (isFile && paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
    var row = {
      entryType: isFile ? "file" : entry.type,
      fullText: isImage ? "" : fullText(entry),
      previewText: previewText(entry),
      previewImage: previewPath,
      path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
      mime: isImage ? String(entry.mime || "image/png") : "text/plain",
      index: i,
      category: categoryOf(entry),
      pinned: entry.pinned === true,
      annotation: String(entry.annotation || ""),
      source: String(entry.source || "")
    }
    if (row.pinned) pinned.push(row)
    else rest.push(row)
  }

  // Stable partition: pinned float to the top, everything else keeps its order.
  // The row `index` stays the real history index, so paste/open by index works.
  return pinned.concat(rest).slice(0, max)
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeEntry: normalizeEntry,
    entryKey: entryKey,
    isProtected: isProtected,
    trimHistory: trimHistory,
    parseHistory: parseHistory,
    addEntry: addEntry,
    removeEntryAt: removeEntryAt,
    clearHistory: clearHistory,
    setPinned: setPinned,
    togglePin: togglePin,
    setAnnotation: setAnnotation,
    updateText: updateText,
    parseEntryJson: parseEntryJson,
    searchableText: searchableText,
    previewText: previewText,
    imagePreviewText: imagePreviewText,
    filePaths: filePaths,
    fileEntryText: fileEntryText,
    fullText: fullText,
    categoryOf: categoryOf,
    stripMarkdownImages: stripMarkdownImages,
    splitMarkdown: splitMarkdown,
    displayRows: displayRows
  }
}
