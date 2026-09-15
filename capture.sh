#!/bin/bash

# Captures the current clipboard as a JSON entry on stdout. In watch mode,
# wl-paste invokes this with the payload on stdin and the mime as $1. Without
# arguments, it snapshots the current selection itself.

set -o pipefail

# Largest text entry recorded, in bytes. ClipboardHistory.js holds the same limit
# in UTF-16 units, and a byte count is never smaller than the unit count of the
# text it decodes to, so an entry accepted here is always accepted there. A copy
# over the limit is reported as skipped rather than carried into the shell.
ENTRY_LIMIT=${CLIPBOARD_ENTRY_LIMIT:-2097152}
# Largest image recorded, in bytes.
IMAGE_LIMIT=${CLIPBOARD_IMAGE_LIMIT:-67108864}
# Seconds a copy may take to arrive. The clipboard owner controls the stream and
# can stall it or never end it, so the reader is killed at this deadline.
READ_DEADLINE=${CLIPBOARD_READ_DEADLINE:-10}

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
mkdir -p "$IMAGE_DIR"

# The copy being read. It is removed however the script ends, killed included.
tmp=
trap 'rm -f -- "$tmp"' EXIT
trap 'exit 143' TERM INT HUP

types=$(wl-paste --list-types 2>/dev/null || true)

if [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] || grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

emit_skipped() {
  printf '{"type":"skipped","reason":"too-large"}\n'
}

# Writes at most limit + 1 bytes from the command into $tmp, killing the command at
# the read deadline. Returns 0 for a complete copy within the limit, 1 for nothing
# to record, and 2 for a copy over the limit or cut off by the deadline.
read_copy() {
  local limit=$1 status size
  shift
  timeout -k 1 "$READ_DEADLINE" "$@" 2>/dev/null | head -c $((limit + 1)) >"$tmp"
  status=$?
  size=$(stat -c %s -- "$tmp")
  # A reader stopped by head at the limit exits on SIGPIPE, so size is checked first.
  (( size > limit || status == 124 || status == 137 )) && return 2
  (( status == 0 && size > 0 )) || return 1
}

emit_image() {
  local mime=$1 ext hash file
  shift

  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg

  tmp=$(mktemp --tmpdir="$IMAGE_DIR" clipboard.XXXXXX) || return 0
  read_copy "$IMAGE_LIMIT" "$@" || { (( $? == 2 )) && emit_skipped; return 0; }

  hash=$(sha256sum "$tmp" | awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e $file ]]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi
  tmp=

  jq -cn --arg mime "$mime" --arg path "$file" --arg captured_at "$(date +'%A %H:%M')" \
    '{type:"image", mime:$mime, path:$path, capturedAt:$captured_at}'
}

emit_text() {
  tmp=$(mktemp) || return 0
  read_copy "$ENTRY_LIMIT" "$@" || { (( $? == 2 )) && emit_skipped; return 0; }

  perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -0777 -e '
    my $raw = <STDIN>;

    my $encoding;
    my $heuristic_encoding = 0;
    if ($raw =~ /^(?:\xFF\xFE|\xFE\xFF)/) {
      $encoding = "UTF-16";
    } elsif (length($raw) % 2 == 0 && index($raw, "\0") >= 0) {
      my $units = length($raw) / 2;
      my $nuls = $raw =~ tr/\0/\0/;

      # Neither byte lane can reach the padding threshold when the entire
      # payload contains fewer NULs than that, so avoid two full string passes.
      if ($nuls * 4 >= $units * 3) {
        my $even_bytes = $raw;
        $even_bytes =~ s/(.)./$1/sg;
        my $even_nuls = $even_bytes =~ tr/\0/\0/;
        undef $even_bytes;

        my $odd_bytes = $raw;
        $odd_bytes =~ s/.(.)/$1/sg;
        my $odd_nuls = $odd_bytes =~ tr/\0/\0/;

        # BOM-less UTF-16 is indistinguishable from NUL-separated bytes. Decode
        # only when at least three quarters of the code units have consistent
        # padding and fewer than one quarter have NULs in the opposite byte.
        if ($odd_nuls * 4 >= $units * 3 && $even_nuls * 4 < $units) {
          $encoding = "UTF-16LE";
          $heuristic_encoding = 1;
        } elsif ($even_nuls * 4 >= $units * 3 && $odd_nuls * 4 < $units) {
          $encoding = "UTF-16BE";
          $heuristic_encoding = 1;
        }
      }
    }

    my $text = $encoding ? eval { decode($encoding, $raw, FB_CROAK | LEAVE_SRC) } : undef;
    if ($heuristic_encoding && defined($text) && $text =~ /[\x00-\x08\x0E-\x1A\x1C-\x1F]/) {
      $text = undef;
    }
    $text = decode("UTF-8", $raw) unless defined $text;
    print "{\"type\":\"text\",\"text\":", encode_json($text), "}\n";
  ' <"$tmp"
}

# In watch mode the copy arrives on stdin, read by cat so the deadline covers it.
case "${1:-}" in
text) emit_text cat; exit 0 ;;
image/*) emit_image "$1" cat; exit 0 ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  if grep -qx "$mime" <<<"$types"; then
    emit_image "$mime" wl-paste --type "$mime"
    exit 0
  fi
done

if grep -q '^text/' <<<"$types" || grep -qx 'UTF8_STRING' <<<"$types" || grep -qx 'STRING' <<<"$types"; then
  emit_text wl-paste --type text --no-newline
fi
