#!/bin/bash
# copy-files.sh <dest-dir> [prefix-name] <src1> [src2 ...]
#
# Copy the given files into <dest-dir>, creating the directory if it does not
# exist yet, and preserving timestamps, mode, ownership where possible, and
# extended attributes. Source files are never modified or removed — the SD card
# contents are left untouched.
#
# If a non-empty <prefix-name> is given, files are renamed sequentially as
#   <prefix-name>_001.<ext>, <prefix-name>_002.<ext>, ...
# in the order they appear on the command line, keeping the original file
# extension. Otherwise the original basename is preserved.
#
# Emits one line per copied file to stdout: "copied<TAB><dest-path>".
# On failure, emits "error<TAB><src><TAB><message>" and exits non-zero after
# attempting to copy the rest.

set -u

dest=${1:-}; shift || true
prefix=${1:-}; shift || true

[ -n "$dest" ] || { echo "no destination given" >&2; exit 1; }
mkdir -p "$dest" || { echo "cannot create destination: $dest" >&2; exit 1; }

failed=0
seq=0
for src in "$@"; do
  [ -n "$src" ] || continue
  base=$(basename -- "$src")
  stem=${base%.*}
  dot=${base##*.}
  if [ "$dot" = "$base" ]; then
    dot=""
  else
    dot=".$dot"
  fi

  if [ -n "$prefix" ]; then
    seq=$((seq+1))
    target="$(printf '%s/%s_%03d%s' "$dest" "$prefix" "$seq" "$dot")"
    # If a same-named file already exists, keep numbering until we find a gap.
    while [ -e "$target" ]; do
      seq=$((seq+1))
      target="$(printf '%s/%s_%03d%s' "$dest" "$prefix" "$seq" "$dot")"
    done
  else
    target="$dest/$base"
    # If a same-named file already exists, make the copy unique rather than
    # overwriting it silently.
    if [ -e "$target" ]; then
      n=1
      while [ -e "$dest/${stem}_${n}${dot}" ]; do n=$((n+1)); done
      target="$dest/${stem}_${n}${dot}"
    fi
  fi

  if cp -p -- "$src" "$target" 2>/dev/null; then
    printf 'copied\t%s\n' "$target"
  else
    printf 'error\t%s\t%s\n' "$src" "copy failed"
    failed=1
  fi
done

exit $failed
