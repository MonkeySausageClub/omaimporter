#!/bin/bash
# list-images.sh <dir>
#
# Scan <dir> recursively (bounded depth) for common photo files — JPEG plus
# the camera RAW formats the tools on this system can decode — and emit one
# TSV line per file: "source_path<TAB>thumbnail_path".
#
# Rows whose thumbnail is already cached are printed first (so a second visit
# to the same card is effectively instant), then uncached thumbnails are built
# in parallel and their rows streamed out as the workers finish. Thumbnails
# are written to a per-file cache keyed by content hash, so re-scanning is
# fast and the SD card is only ever read. Source files are never modified.
#
# RAW files: a same-basename .JPG sibling (the embedded preview the camera
# writes) is used as the thumbnail source when present — far cheaper than a
# libraw decode. Otherwise ImageMagick (built against libraw) reads the RAW
# directly. No metadata is written back to the source.

set -o pipefail

dir=${1:-}
[ -n "$dir" ] && [ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 1; }

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/sd-importer"
mkdir -p "$cache_root"

# Load the index once into an associative array: lookup key is
# "path<TAB>sig", value is "<hash>". Under bash this is a pico-second
# hash-map hit instead of one awk(1) spawn per file.
declare -A CACHE_IDX=()
while IFS=$'\t' read -r _fp _sig _hash; do
  [ -n "$_fp" ] && [ -n "$_sig" ] && [ -n "$_hash" ] && CACHE_IDX["$_fp"$'\t'"$_sig"]="$_hash"
done < <([ -f "$cache_root/index.tsv" ] && cat "$cache_root/index.tsv")

# stat signature -> existing cached thumbnail path, else empty.
cached_thumb() {
  local file="$1"
  local sig hash
  sig=$(stat -Lc '%s:%Y' "$file" 2>/dev/null) || return
  hash=${CACHE_IDX["$file"$'\t'"$sig"]}
  [ -n "$hash" ] && [ -f "$cache_root/$hash" ] && printf '%s\n' "$cache_root/$hash"
}

# Thumbnail cache key is the md5 of the source file's path string, not of the
# image bytes: two different files that happen to share thumbnails must not
# overwrite each other's cache row.
thumb_key() { md5sum "$1" 2>/dev/null | cut -d ' ' -f 1; }

make_thumb() {
  local file="$1"
  local src="${2:-$file}"
  local hash thumb
  hash=$(thumb_key "$file") || return 1
  thumb="$cache_root/$hash.jpg"
  [ -f "$thumb" ] && { printf '%s\n' "$thumb"; return 0; }

  if command -v convert >/dev/null 2>&1; then
    convert "$src[0]" -auto-orient -thumbnail '256x256>' -quality 82 \
      "$thumb" 2>/dev/null && { printf '%s\n' "$thumb"; return 0; }
  fi

  rm -f "$thumb"
  return 1
}

# Prefer a sibling JPEG for the thumbnail when the row is a RAW file.
raw_thumb_src() {
  local file="$1"
  local dir base ext s
  dir=$(dirname -- "$file")
  base=$(basename -- "$file")
  ext="${base##*.}"
  base="${base%.*}"
  case "${ext,,}" in
    cr2|cr3|crw|nef|nrw|arw|srw|orf|raf|rw2|pef|dng|3fr|dcr|kdc|mdc|mrw|mos|erf|iiq|fff|mef)
      for s in "$dir/$base.jpg" "$dir/$base.JPG" "$dir/$base.jpeg" "$dir/$base.JPEG"; do
        [ -f "$s" ] && { printf '%s\n' "$s"; return 0; }
      done
      ;;
  esac
  return 1
}

# Collect a stable list of matching files first so we don't re-stat in a pipe
# subshell (which would prevent a shared index from being maintained).
mapfile -d '' files < <(
  find -L "$dir" -maxdepth 6 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.raw' -o -iname '*.cr2' \
       -o -iname '*.cr3' -o -iname '*.crw' -o -iname '*.nef' -o -iname '*.nrw' \
       -o -iname '*.arw' -o -iname '*.srw' -o -iname '*.orf' -o -iname '*.raf' \
       -o -iname '*.rw2' -o -iname '*.pef' -o -iname '*.dng' -o -iname '*.3fr' \
       -o -iname '*.dcr' -o -iname '*.kdc' -o -iname '*.mdc' -o -iname '*.mrw' \
       -o -iname '*.mos' -o -iname '*.erf' -o -iname '*.iiq' -o -iname '*.fff' \
       -o -iname '*.mef' \) \
    -print0 2>/dev/null | sort -z
)

# Stream already-cached rows immediately so the UI fills before any heavy
# thumbnailing happens.
uncached=()
for img in "${files[@]}"; do
  [ -n "$img" ] || continue
  thumb=$(cached_thumb "$img")
  if [ -n "$thumb" ]; then
    printf '%s\t%s\n' "$img" "$thumb"
  else
    uncached+=("$img")
  fi
done

if [ "${#uncached[@]}" -gt 0 ]; then
  ncpu=$(nproc 2>/dev/null || printf '4')
  # Remove this run's worker-index even if the script is killed, so aborted
  # scans never leave stale temp files behind.
  idx_file="$cache_root/.idx.$$"
  export idx_file
  trap 'rm -f "$idx_file"' EXIT
  worker() {
    local file="$1"
    local thumb
    thumb=$(make_thumb "$file" "$(raw_thumb_src "$file")")
    if [ -n "$thumb" ]; then
      printf '%s\t%s\n' "$file" "$thumb"
      printf '%s\t%s\t%s\n' "$file" "$(stat -Lc '%s:%Y' "$file" 2>/dev/null)" "$(basename "$thumb")" \
        >> "$idx_file"
    fi
  }
  export -f worker make_thumb thumb_key raw_thumb_src
  export cache_root

  : > "$idx_file"
  printf '%s\n' "${uncached[@]}" \
    | xargs -d '\n' -n1 -P"$ncpu" bash -c 'worker "$1"' _

  # Workers appended to a per-run index file; merge it in. A pristine run
  # has no index.tsv yet, so tolerate a missing base.
  if [ -s "$idx_file" ]; then
    sort -u "$cache_root/index.tsv" "$idx_file" \
      > "$cache_root/index.tsv.merged" 2>/dev/null \
      || sort -u "$idx_file" > "$cache_root/index.tsv.merged"
    mv -f "$cache_root/index.tsv.merged" "$cache_root/index.tsv"
  fi
  rm -f "$idx_file"
  trap - EXIT
fi

exit 0