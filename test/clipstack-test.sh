#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT="$ROOT" node <<'JS'
const path = require('path')
const root = process.env.ROOT
const write = require(path.join(root, 'ClipboardWrite.js'))

function assert(condition, description, detail) {
  if (condition) {
    console.log(`ok - ${description}`)
    return
  }

  if (detail) console.error(detail)
  console.error(`not ok - ${description}`)
  process.exit(1)
}

function processAdapter() {
  return {
    payload: '',
    running: false,
    stdinEnabled: false,
    writes: [],
    write(value) { this.writes.push(value) }
  }
}

const adapter = processAdapter()

assert(write.startCopy(adapter, 'first'), 'first copy starts')
assert(
  adapter.payload === 'first' && adapter.stdinEnabled && adapter.running,
  'copy starts with its complete payload and stdin open'
)

write.writePendingCopy(adapter)
assert(
  adapter.writes.length === 1 && adapter.writes[0] === 'first' && !adapter.stdinEnabled,
  'started process writes the payload and closes stdin'
)

adapter.running = false
assert(write.startCopy(adapter, 'second'), 'second copy starts on the same process adapter')
assert(
  adapter.payload === 'second' && adapter.stdinEnabled && adapter.running,
  'second copy reopens stdin before starting'
)

const emptyProcess = processAdapter()
assert(!write.startCopy(emptyProcess, ''), 'empty text is rejected')
assert(
  emptyProcess.payload === '' && !emptyProcess.stdinEnabled && !emptyProcess.running,
  'empty text leaves the copy process untouched'
)

const busyProcess = processAdapter()
busyProcess.running = true
assert(!write.startCopy(busyProcess, 'next'), 'a rapid save cannot replace an in-flight payload')

const history = require(path.join(root, 'ClipboardHistory.js'))

const text1 = { type: 'text', text: 'first snippet' }
const text2 = { type: 'text', text: 'second snippet' }
const image1 = { type: 'image', path: '/tmp/clip images/a b.png', mime: 'image/png' }
const image2 = { type: 'image', path: '/tmp/clip/c.png', mime: 'image/png' }

function select() {
  return Array.prototype.slice.call(arguments).reduce(
    (keys, entry) => history.toggleSelection(keys, history.entryKey(entry)), {})
}

const texts = history.joinSelection([text1, text2], select(text1, text2))
assert(
  texts.text === 'first snippet\nsecond snippet' && texts.mime === '' && texts.count === 2,
  'a text-only selection joins with newlines as plain text'
)

const images = history.joinSelection([image1, image2], select(image1, image2))
assert(
  images.mime === 'text/uri-list'
    && images.text === 'file:///tmp/clip%20images/a%20b.png\nfile:///tmp/clip/c.png',
  'an image-only selection becomes an encoded uri-list'
)

const mixed = history.joinSelection([text1, image2], select(text1, image2))
assert(
  mixed.mime === '' && mixed.text === 'first snippet\nfile:///tmp/clip/c.png',
  'a mixed selection stays plain text and contributes the image as a file:// line'
)

assert(
  history.selectionMime([text1, image2], select(text1, image2)) === ''
    && history.selectionMime([image1, image2], select(image1, image2)) === 'text/uri-list'
    && history.selectionMime([image1], {}) === '',
  'selectionMime answers what a paste would be without building it'
)

const fileEntry = { type: 'text', text: 'file:///tmp/one.png\nfile:///tmp/two.png' }
assert(
  history.joinSelection([fileEntry], select(fileEntry)).mime === 'text/uri-list',
  'an existing multi-file entry counts as files, not text'
)

assert(
  history.joinSelection([text1], {}).count === 0
    && history.joinSelection([text1], {}).mime === '',
  'an empty selection joins to nothing and claims no uri-list'
)

const ticked = select(text1, image2)
const untoggled = history.toggleSelection(ticked, history.entryKey(text1))
assert(
  history.selectionCount(ticked) === 2 && history.selectionCount(untoggled) === 1,
  'toggling an entry off returns a new set without it'
)
assert(untoggled !== ticked, 'toggleSelection never mutates the set in place')

// The reason selections are keyed by content: this is what the watcher and a
// saved edit do to history while a selection is open.
const grown = history.addEntry(history.addEntry([text1, text2], image2), { type: 'text', text: 'edited' })
assert(
  history.selectedEntries(grown, select(text1, text2)).map(e => e.text).join('|')
    === 'first snippet|second snippet',
  'a selection survives entries being prepended to history'
)

assert(
  history.removeSelected(grown, select(text1, image2)).map(history.entryKey).join('|')
    === 'text:edited|text:second snippet',
  'removeSelected drops exactly the ticked entries'
)

const huge1 = { type: 'text', text: 'a'.repeat(1.5 * 1024 * 1024) }
const huge2 = { type: 'text', text: 'b'.repeat(1.5 * 1024 * 1024) }
const huge3 = { type: 'text', text: 'c'.repeat(1.5 * 1024 * 1024) }
const largeHistory = [huge1, huge2, huge3]
assert(
  !history.selectionOverflows(largeHistory, select(huge1)),
  'one large entry is still within the paste ceiling'
)
assert(
  history.selectionOverflows(largeHistory, select(huge1, huge2, huge3)),
  'a selection past the ceiling is refused, not truncated'
)
const refused = history.joinSelection(largeHistory, select(huge1, huge2, huge3))
assert(
  refused.overflow === true && refused.text === '' && refused.count === 3,
  'an over-ceiling join yields no payload and says why'
)

const long = { type: 'text', text: 'x'.repeat(9000) + '\ntail' }
const longRow = history.displayRows([long], '', 10)[0]
assert(
  longRow.key === history.entryKey(long)
    && history.selectedEntries([long], select(long)).length === 1,
  'a capped row still carries the key of its uncapped entry'
)
// --- History byte bounds -------------------------------------------------
// Clipboard text used to have no byte limit anywhere between capture and disk:
// one large copy was carried whole through capture, the watcher line, every
// save and every startup load.
const fs = require('fs')
const MiB = 1024 * 1024
const cp = (...points) => String.fromCodePoint(...points)
// Exactly what the overlay writes: saveHistory() output, encoded as UTF-8.
const fileBytes = (h) => Buffer.byteLength(JSON.stringify(h.slice(0, 500), null, 2) + '\n', 'utf8')

assert(history.entryTextLimit === 2 * MiB, 'an entry may hold up to 2 MiB of text')
assert(
  history.normalizeEntry({ type: 'text', text: 'a'.repeat(history.entryTextLimit) }) !== null
    && history.normalizeEntry({ type: 'text', text: 'a'.repeat(history.entryTextLimit + 1) }) === null,
  'an entry at the limit is kept and one unit over is rejected'
)

const captureSource = fs.readFileSync(path.join(root, 'capture.sh'), 'utf8')
const captureLimit = Number((captureSource.match(/CLIPBOARD_ENTRY_LIMIT:-(\d+)/) || [])[1])
assert(captureLimit === history.entryTextLimit, `capture.sh and ClipboardHistory.js agree on the entry limit (${captureLimit})`)

assert(history.captureResult('{"type":"skipped","reason":"too-large"}').kind === 'skipped', 'a copy capture.sh skipped is reported as skipped')
const captured = history.captureResult(JSON.stringify({ type: 'text', text: 'hello' }))
assert(captured.kind === 'entry' && captured.entry.text === 'hello', 'a normal captured entry is accepted')
assert(
  history.captureResult(JSON.stringify({ type: 'text', text: 'a'.repeat(history.entryTextLimit + 1) })).kind === 'skipped',
  'an oversized entry that got past capture.sh is still reported as skipped'
)
assert(
  history.captureResult('x'.repeat(history.captureLineLimit + 1)).kind === 'skipped',
  'a watcher line past the line limit is refused before it is parsed'
)
assert(history.captureResult('not json').kind === 'ignore' && history.captureResult('').kind === 'ignore', 'unparseable capture lines are ignored')

assert(history.parseHistory('not json') === null && history.parseHistory('{}') === null, 'an unreadable history is reported as unreadable, never as empty')
assert(Array.isArray(history.parseHistory('[]')) && history.parseHistory('[]').length === 0, 'an empty history parses as empty')
const tooMany = JSON.stringify(Array.from({ length: 700 }, (_, i) => ({ type: 'text', text: 'entry ' + i })))
assert(history.parseHistory(tooMany, 500).length === 500, 'loading stops at the entry limit')
const withOversized = JSON.stringify([
  { type: 'text', text: 'keep' },
  { type: 'text', text: 'a'.repeat(history.entryTextLimit + 1) },
  { type: 'text', text: 'after' },
])
assert(history.parseHistory(withOversized, 500).map(e => e.text).join('|') === 'keep|after', 'loading skips an oversized entry and keeps the rest')
const overBudget = JSON.stringify(Array.from({ length: 10 }, (_, i) => ({ type: 'text', text: String(i).repeat(1.5 * MiB) })))
const loaded = history.parseHistory(overBudget, 500)
assert(loaded.length === 5 && loaded[0].text[0] === '0', `loading keeps history newest-first within the byte budget (${loaded.length} kept)`)

let budgeted = []
for (let i = 0; i < 10; i++) budgeted = history.addEntry(budgeted, { type: 'text', text: String(i).repeat(1.5 * MiB) }, 500)
assert(budgeted.length === 5 && budgeted[0].text[0] === '9', `adding evicts the oldest entries to stay within the byte budget (${budgeted.length} kept)`)
const alone = history.addEntry(budgeted, { type: 'text', text: cp(1).repeat(history.entryTextLimit) }, 500)
assert(alone.length === 1 && alone[0].text.length === history.entryTextLimit, 'the newest entry is always kept, even when it alone fills the budget')

// The loader must never refuse a file the writer can produce, or a legitimate
// history would be renamed aside at the next start. Drive the writer with the
// content that serializes to the most bytes per character.
assert(history.historyFileLimit <= 32 * MiB, `the load ceiling stays a meaningful bound (${history.historyFileLimit / MiB} MiB)`)
const heaviest = {
  control: cp(1),                          // JSON escapes it to six ASCII characters
  lone: String.fromCharCode(0xd800),       // node escapes a lone surrogate to six characters
  cjk: cp(0x4e2d),                         // three UTF-8 bytes per unit
  emoji: cp(0x1f600),                      // four bytes per two units
  quote: '"',                              // two bytes per unit
  ascii: 'a',
}
const checkCeiling = (h, label) =>
  assert(fileBytes(h) <= history.historyFileLimit, `a written history fits the load ceiling: ${label} (${(fileBytes(h) / MiB).toFixed(2)} MiB)`)

let cjkFill = []
for (let i = 0; i < 24; i++) cjkFill = history.addEntry(cjkFill, { type: 'text', text: String(i) + heaviest.cjk.repeat(512 * 1024) }, 500)
checkCeiling(cjkFill, 'budget filled with 3-byte characters')
for (const [name, unit] of Object.entries(heaviest)) {
  const text = unit.repeat(Math.floor(history.entryTextLimit / unit.length))
  checkCeiling(history.addEntry(cjkFill, { type: 'text', text }, 500), `largest ${name} entry on top of a full history`)
}

let seed = 20260915
const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
let seededMix = []
const units = Object.values(heaviest)
for (let i = 1; i <= 400; i++) {
  const unit = units[Math.floor(random() * units.length)]
  const size = Math.floor(random() * 300 * 1024 / unit.length)
  seededMix = history.addEntry(seededMix, { type: 'text', text: i + unit.repeat(size) }, 500)
  if (i % 50 === 0) checkCeiling(seededMix, `seeded mix after ${i} copies`)
}
// --- Large copies ----------------------------------------------------------
// A text copy over the entry limit is kept as a file, like an image, with only
// a short preview in history, so the shell never holds the whole text.
const hex = (c) => c.repeat(64)
const largePath = '/home/u/.local/state/omarchy/clipboard-text/' + hex('a') + '.txt'
const large = (path, bytes, preview) => ({ type: 'largetext', path, bytes, preview })

assert(history.largeTextLimit === 256 * MiB && history.largeTextBudget === 1024 * MiB, 'large copies are limited to 256 MiB each and 1 GiB together')
const captureLarge = Number((captureSource.match(/CLIPBOARD_LARGE_LIMIT:-(\d+)/) || [])[1])
assert(captureLarge === history.largeTextLimit, `capture.sh and ClipboardHistory.js agree on the large-copy limit (${captureLarge})`)

const keptLarge = history.normalizeEntry(large(largePath, 3 * MiB, 'x'.repeat(9000)))
assert(
  keptLarge && keptLarge.type === 'largetext' && keptLarge.path === largePath && keptLarge.bytes === 3 * MiB
    && keptLarge.preview.length === history.largePreviewLimit,
  'a large copy keeps its path and size, with its preview capped'
)
for (const [label, bad] of [
  ['a path outside the large-copy folder', large('/etc/passwd', 3 * MiB, 'x')],
  ['a parent-directory segment', large('/home/u/../u/.local/state/omarchy/clipboard-text/' + hex('a') + '.txt', 3 * MiB, 'x')],
  ['a name that is not a content hash', large('/home/u/.local/state/omarchy/clipboard-text/notes.txt', 3 * MiB, 'x')],
  ['a size over the limit', large(largePath, history.largeTextLimit + 1, 'x')],
  ['no size', large(largePath, undefined, 'x')],
]) assert(history.normalizeEntry(bad) === null, `a large copy with ${label} is rejected`)

assert(history.entryKey(keptLarge) === 'largetext:' + largePath, 'a large copy is keyed by its file')
const [largeRow] = history.displayRows([keptLarge], '', 10)
assert(
  largeRow.entryType === 'largetext' && largeRow.path === largePath && largeRow.mime === 'text/plain;charset=utf-8'
    && largeRow.previewText.startsWith('3.0 MB'),
  `a large copy shows its size in the list (${largeRow.previewText.slice(0, 16)})`
)
assert(history.displayRows([large(largePath, 3 * MiB, 'find me inside')], 'me inside', 10).length === 1, 'a large copy is found by its preview')
assert(history.selectionOverflows([keptLarge, text1], select(keptLarge)), 'a large copy is never joined into a paste')
assert(history.entryForAction([keptLarge], 0).type === 'largetext', 'actions see a large copy as one, so it is never offered for editing')

let disk = []
for (let i = 0; i < 5; i++) {
  disk = history.addEntry(disk, large(largePath.replace(hex('a'), hex(String(i))), 250 * MiB, 'copy ' + i), 500)
  disk = history.addEntry(disk, { type: 'text', text: 'small ' + i }, 500)
}
const diskShape = disk.map(e => e.type === 'largetext' ? 'L' + e.preview.slice(-1) : 's' + e.text.slice(-1)).join(' ')
assert(
  disk.filter(e => e.type === 'largetext').length === 4 && disk.filter(e => e.type === 'text').length === 5,
  `adding drops the oldest large copies past 1 GiB and keeps every small entry (${diskShape})`
)
const fiveLarge = JSON.stringify([0, 1, 2, 3, 4].map(i => large(largePath.replace(hex('a'), hex(String(i))), 250 * MiB, 'p' + i)))
assert(history.parseHistory(fiveLarge, 500).length === 4, 'loading drops large copies past 1 GiB too')

assert(
  history.largeTextNames([keptLarge, text1, large('/etc/passwd', 1, 'x')]).join(',') === hex('a') + '.txt',
  'only valid large copies name files to keep'
)

let previews = []
for (let i = 0; i < 520; i++)
  previews = history.addEntry(previews, large(largePath.replace(hex('a'), i.toString(16).padStart(64, '0')), 3 * MiB, heaviest.cjk.repeat(8192)), 500)
checkCeiling(previews, 'large copies with the heaviest previews')

JS

# --- capture.sh and load-history.sh ---------------------------------------
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; [[ -n ${2:-} ]] && printf '%s\n' "$2"; exit 1; }
capture_as() { local mode=$1; shift; XDG_STATE_HOME="$T/state" "$@" bash "$ROOT/capture.sh" "$mode"; }
capture() { capture_as text "$@"; }
leftovers() { find "$T/state" -name 'clipboard.*' | head -1; }

out=$(printf '%s' '0123456789abcdef' | capture env CLIPBOARD_ENTRY_LIMIT=16)
[[ $out == '{"type":"text","text":"0123456789abcdef"}' ]] && ok 'capture records text at the entry limit' || not_ok 'capture records text at the entry limit' "$out"

out=$(printf '%s' '0123456789abcdefX' | capture env CLIPBOARD_ENTRY_LIMIT=16)
path=$(printf '%s' "$out" | jq -r 'select(.type == "largetext") | .path' 2>/dev/null)
[[ -n $path && -f $path && $(cat "$path") == '0123456789abcdefX' && $(printf '%s' "$out" | jq -r '.bytes') == 17 && $(printf '%s' "$out" | jq -r '.preview') == '0123456789abcdefX' ]] \
  && ok 'a copy over the entry limit is kept as a large copy on disk' || not_ok 'a copy over the entry limit is kept as a large copy on disk' "$out"
[[ $path == "$T/state/omarchy/clipboard-text/$(printf '%s' '0123456789abcdefX' | sha256sum | cut -d' ' -f1).txt" ]] \
  && ok 'a large copy is stored under its content hash' || not_ok 'a large copy is stored under its content hash' "$path"

again=$(printf '%s' '0123456789abcdefX' | capture env CLIPBOARD_ENTRY_LIMIT=16)
[[ $again == "$out" && $(find "$T/state/omarchy/clipboard-text" -type f -name '*.txt' | wc -l) -eq 1 ]] \
  && ok 'copying the same large text again reuses its file' || not_ok 'copying the same large text again reuses its file' "$again"

out=$(head -c 33 /dev/zero | tr '\0' a | capture env CLIPBOARD_ENTRY_LIMIT=16 CLIPBOARD_LARGE_LIMIT=32)
[[ $out == '{"type":"skipped","reason":"too-large"}' && -z $(find "$T/state/omarchy/clipboard-text" -name 'clipboard.*') ]] \
  && ok 'a copy over the large-copy limit is skipped and leaves no file behind' || not_ok 'a copy over the large-copy limit is skipped and leaves no file behind' "$out"

out=$(head -c $((3 * 1024 * 1024)) /dev/zero | tr '\0' a | capture env)
path=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null)
[[ $(printf '%s' "$out" | jq -r '.type') == largetext && -f $path && $(stat -c %s "$path") -eq $((3 * 1024 * 1024)) && $(printf '%s' "$out" | jq -r '.preview | length') -eq 8192 ]] \
  && ok 'a 3 MiB copy is kept whole on disk with an 8 KB preview' || not_ok 'a 3 MiB copy is kept whole on disk with an 8 KB preview' "${out:0:200}"

out=$(for i in $(seq 1 4000); do printf '\xe4\xb8\xad'; done | capture env CLIPBOARD_ENTRY_LIMIT=16)
preview=$(printf '%s' "$out" | jq -j '.preview')
[[ $(printf '%s' "$out" | jq -r '.preview | length') -eq 2730 ]] && printf '%s' "$preview" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  && ok 'a preview ends on a whole UTF-8 character' || not_ok 'a preview ends on a whole UTF-8 character' "$(printf '%s' "$out" | jq -r '.preview | length')"

utf16_text="large utf-16 copy $(head -c 40 /dev/zero | tr '\0' x)"
out=$({ printf '\xff\xfe'; printf '%s' "$utf16_text" | iconv -f UTF-8 -t UTF-16LE; } | capture env CLIPBOARD_ENTRY_LIMIT=16)
path=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null)
[[ -f $path && $(cat "$path") == "$utf16_text" && $(printf '%s' "$out" | jq -r '.preview') == "$utf16_text" ]] \
  && ok 'a large UTF-16 copy is stored converted to UTF-8' || not_ok 'a large UTF-16 copy is stored converted to UTF-8' "$out"

out=$(printf '0123456789abcdef' | capture_as image/png env CLIPBOARD_IMAGE_LIMIT=16)
[[ $out == *'"type":"image"'* && -f $T/state/omarchy/clipboard-images/$(printf '0123456789abcdef' | sha256sum | cut -d' ' -f1).png ]] \
  && ok 'capture records an image at the image limit' || not_ok 'capture records an image at the image limit' "$out"

out=$(printf '0123456789abcdef' | capture_as image/png env CLIPBOARD_IMAGE_LIMIT=16)
[[ $out == *'"type":"image"'* && -z $(leftovers) ]] && ok 'capturing an image already kept leaves no temporary file' || not_ok 'capturing an image already kept leaves no temporary file' "out=$out left=$(leftovers)"

out=$(set +o pipefail; head -c 1048576 /dev/zero | capture_as image/png env CLIPBOARD_IMAGE_LIMIT=16)
[[ $out == '{"type":"skipped","reason":"too-large"}' && -z $(leftovers) ]] \
  && ok 'capture skips an image over the limit and deletes what it read' || not_ok 'capture skips an image over the limit and deletes what it read' "out=$out left=$(leftovers)"

# A clipboard owner that sends a few bytes and then never ends its stream.
for mode in image/png text; do
  start=$SECONDS
  out=$(capture_as "$mode" env CLIPBOARD_READ_DEADLINE=1 < <(printf abc; sleep 6))
  (( SECONDS - start <= 3 )) && [[ $out == '{"type":"skipped","reason":"too-large"}' && -z $(leftovers) ]] \
    && ok "capture drops a stalled $mode stream at the read deadline" \
    || not_ok "capture drops a stalled $mode stream at the read deadline" "out=$out took=$((SECONDS - start))s left=$(leftovers)"
done

capture_as image/png env CLIPBOARD_READ_DEADLINE=1 < <(printf abc; sleep 6) >/dev/null &
sleep 0.3; kill -TERM $!; wait $! 2>/dev/null || true
[[ -z $(leftovers) ]] && ok 'a capture killed mid-read leaves no partial file' || not_ok 'a capture killed mid-read leaves no partial file' "$(leftovers)"

# A limit reaches $(( )), where bash runs a command substitution it finds in an
# operand. It has to be refused before the arithmetic, not evaluated.
out=$(printf abc | capture env "CLIPBOARD_ENTRY_LIMIT=x[\$(touch $T/pwned)]" 2>/dev/null) && status=0 || status=$?
(( status != 0 )) && [[ ! -e $T/pwned && -z $out ]] \
  && ok 'a non-numeric entry limit is refused instead of evaluated' \
  || not_ok 'a non-numeric entry limit is refused instead of evaluated' "status=$status out=$out pwned=$([[ -e $T/pwned ]] && echo yes)"

# The large-copy limit reaches $(( )) in read_copy the same way, and an array
# subscript is evaluated there even though a bare command substitution is not.
rm -f "$T/pwned"
out=$(printf abc | capture env "CLIPBOARD_LARGE_LIMIT=x[\$(touch $T/pwned)]" 2>/dev/null) && status=0 || status=$?
(( status != 0 )) && [[ ! -e $T/pwned && -z $out ]] \
  && ok 'a non-numeric large-copy limit is refused instead of evaluated' \
  || not_ok 'a non-numeric large-copy limit is refused instead of evaluated' "status=$status out=$out pwned=$([[ -e $T/pwned ]] && echo yes)"

# Clipboard text passes through head, so a head earlier on the caller's PATH
# would see every copy. capture.sh pins its own PATH instead of inheriting one.
cat >"$T/bin/head" <<SH
#!/bin/bash
touch "$T/shadow-ran"
exec /usr/bin/head "\$@"
SH
chmod +x "$T/bin/head"
out=$(printf abc | PATH="$T/bin:$PATH" bash "$ROOT/capture.sh" text)
[[ $out == '{"type":"text","text":"abc"}' && ! -e $T/shadow-ran ]] \
  && ok 'a shadow tool on the caller PATH never sees a copy' \
  || not_ok 'a shadow tool on the caller PATH never sees a copy' "out=$out shadow=$([[ -e $T/shadow-ran ]] && echo ran)"

load() {
  if out=$(timeout 5 bash "$ROOT/load-history.sh" "$H" "${1:-1048576}"); then status=0; else status=$?; fi
}
reset() { rm -rf "$T/h"; mkdir -p "$T/h"; H="$T/h/clipboard-history.json"; }
rejected() { compgen -G "$H.rejected-*" | head -1; }

reset; load
[[ $status -eq 0 && $out == '[]' ]] && ok 'an absent history loads as empty' || not_ok 'an absent history loads as empty' "status=$status out=$out"

reset; printf '[{"type":"text","text":"hi"}]\n' >"$H"; load
[[ $status -eq 0 && $out == '[{"type":"text","text":"hi"}]' && -f $H ]] && ok 'a normal history is handed over unchanged' || not_ok 'a normal history is handed over unchanged' "status=$status out=$out"

reset; printf '["target"]\n' >"$T/h/target.json"; ln -s "$T/h/target.json" "$H"; load
[[ $status -eq 0 && $out == '[]' && ! -e $H && -L $(rejected) && $(cat "$T/h/target.json") == '["target"]' ]] \
  && ok 'a symlinked history is renamed aside without following or touching its target' \
  || not_ok 'a symlinked history is renamed aside without following or touching its target' "status=$status out=$out rejected=$(rejected)"

reset; mkfifo "$H"; load
[[ $status -eq 0 && $out == '[]' && ! -e $H && -p $(rejected) ]] && ok 'a FIFO history is renamed aside instead of read' || not_ok 'a FIFO history is renamed aside instead of read' "status=$status out=$out"

reset; printf '["%s"]' "$(head -c 100 /dev/zero | tr '\0' a)" >"$H"; load 64
[[ $status -eq 0 && $out == '[]' && ! -e $H && -s $(rejected) ]] && ok 'a history over the load ceiling is renamed aside unread' || not_ok 'a history over the load ceiling is renamed aside unread' "status=$status out=$out"

reset; printf '[{"type":"text","text":"hi"' >"$H"; load
[[ $status -eq 0 && $out == '[]' && ! -e $H && $(cat "$(rejected)") == '[{"type":"text","text":"hi"' ]] && ok 'an invalid history is renamed aside with its bytes preserved' || not_ok 'an invalid history is renamed aside with its bytes preserved' "status=$status out=$out"

reset; printf '{"not":"an array"}' >"$H"; load
[[ $status -eq 0 && $out == '[]' && ! -e $H && -s $(rejected) ]] && ok 'a history that is not an array is renamed aside' || not_ok 'a history that is not an array is renamed aside' "status=$status out=$out"

reset; printf '["private"]' >"$H"; chmod 000 "$H"; load; chmod 600 "$H"
[[ $status -eq 3 && -z $out && -f $H && -z $(rejected) ]] && ok 'an unreadable history reports status 3 and is left in place' || not_ok 'an unreadable history reports status 3 and is left in place' "status=$status out=$out"

# --- prune-text.sh -----------------------------------------------------------
D="$T/prune/omarchy/clipboard-text"; PH="$T/prune/omarchy/clipboard-history.json"
A=$(printf 'a%.0s' $(seq 64)).txt; B=$(printf 'b%.0s' $(seq 64)).txt; C=$(printf 'c%.0s' $(seq 64)).txt; L=$(printf 'd%.0s' $(seq 64)).txt
prune_reset() {
  rm -rf "$T/prune"; mkdir -p "$D"
  printf a >"$D/$A"; printf b >"$D/$B"; printf c >"$D/$C"; printf n >"$D/notes.txt"
  printf t >"$T/prune/target.txt"; ln -s "$T/prune/target.txt" "$D/$L"
  printf s >"$D/clipboard.stale1"
  touch -d '2 minutes ago' "$D/$A" "$D/$B" "$D/notes.txt"; touch -h -d '2 minutes ago' "$D/$L"
  touch -d '2 hours ago' "$D/clipboard.stale1"
}

prune_reset
bash "$ROOT/prune-text.sh" "$D" "$PH" "$A"
[[ -f $D/$A ]] && ok 'the sweep keeps a large copy history still uses' || not_ok 'the sweep keeps a large copy history still uses'
[[ ! -e $D/$B ]] && ok 'the sweep deletes an old large copy history no longer uses' || not_ok 'the sweep deletes an old large copy history no longer uses'
[[ -f $D/$C ]] && ok 'the sweep leaves a copy captured moments ago for its entry to arrive' || not_ok 'the sweep leaves a copy captured moments ago for its entry to arrive'
[[ -f $D/notes.txt ]] && ok 'the sweep ignores files not named like a large copy' || not_ok 'the sweep ignores files not named like a large copy'
[[ -L $D/$L && -f $T/prune/target.txt ]] && ok 'the sweep never deletes a symlink or its target' || not_ok 'the sweep never deletes a symlink or its target'
[[ ! -e $D/clipboard.stale1 ]] && ok 'the sweep clears temp files a dead capture left behind' || not_ok 'the sweep clears temp files a dead capture left behind'

prune_reset; printf '[]' >"$PH.rejected-20260101-000000-1"
bash "$ROOT/prune-text.sh" "$D" "$PH"
[[ -f $D/$A && -f $D/$B ]] && ok 'the sweep deletes nothing while a rejected history may still need its copies' || not_ok 'the sweep deletes nothing while a rejected history may still need its copies'
