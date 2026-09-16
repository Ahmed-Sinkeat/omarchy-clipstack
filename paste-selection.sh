#!/bin/bash

# Copies a multi-entry selection from stdin and, unless --copy-only, pastes it
# into the window that had focus. The payload arrives on stdin, never argv: a
# joined selection can exceed MAX_ARG_STRLEN and exec would fail with E2BIG,
# losing the paste silently.

set -o pipefail

# Resolved from here, not from the caller's PATH: clipboard contents pass
# through these tools.
PATH=/usr/local/bin:/usr/bin

copy_only=false
mime=""

while (( $# > 0 )); do
  case "$1" in
    --copy-only) copy_only=true; shift ;;
    --type) mime="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done

payload=$(cat)

# An empty payload would hand wl-copy nothing and wipe the clipboard instead.
[[ -n $payload ]] || exit 0

args=()
[[ -n $mime ]] && args=(--type "$mime")
printf '%s' "$payload" | wl-copy "${args[@]}"

if [[ $copy_only == "true" ]]; then
  exit
fi

# Same focus settle as omarchy-clipboard-paste-text.
sleep 0.15
wtype -M shift -k Insert -m shift 2>/dev/null || true
