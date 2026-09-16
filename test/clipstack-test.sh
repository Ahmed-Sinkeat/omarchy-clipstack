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
[[ $out == '{"type":"skipped","reason":"too-large"}' ]] && ok 'capture reports text one byte over the limit as skipped' || not_ok 'capture reports text one byte over the limit as skipped' "$out"

# capture.sh stops reading at the limit, so the writer feeding it gets SIGPIPE:
# that is the bound working, not a failure of this pipeline.
out=$(set +o pipefail; head -c $((3 * 1024 * 1024)) /dev/zero | tr '\0' a | capture env)
[[ $out == '{"type":"skipped","reason":"too-large"}' ]] && ok 'capture skips a 3 MiB copy at the default limit' || not_ok 'capture skips a 3 MiB copy at the default limit' "${out:0:200}"

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
