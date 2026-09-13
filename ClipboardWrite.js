// The one writer for every clipboard payload this plugin produces — a joined
// selection and a saved edit alike. Clipboard writes have one ordering constraint: stdin must be reopened before
// a reused Quickshell Process starts, then closed after the payload is written
// so wl-copy sees EOF. Keep that lifecycle behind this small interface so the
// QML editor does not have to repeat or remember it.

function startCopy(process, value) {
  if (!process || process.running) return false

  var text = String(value === undefined || value === null ? "" : value)
  if (text.length === 0) return false

  process.payload = text
  process.stdinEnabled = true
  process.running = true
  return true
}

function writePendingCopy(process) {
  if (!process) return false

  var text = String(process.payload || "")
  if (text.length === 0) {
    process.stdinEnabled = false
    return false
  }

  process.write(text)
  process.payload = ""
  process.stdinEnabled = false
  return true
}

if (typeof module !== "undefined") {
  module.exports = {
    startCopy: startCopy,
    writePendingCopy: writePendingCopy
  }
}
