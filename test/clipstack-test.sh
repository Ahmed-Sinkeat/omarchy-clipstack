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

const long = { type: 'text', text: 'x'.repeat(9000) + '\ntail' }
const longRow = history.displayRows([long], '', 10)[0]
assert(
  longRow.key === history.entryKey(long)
    && history.selectedEntries([long], select(long)).length === 1,
  'a capped row still carries the key of its uncapped entry'
)
JS
