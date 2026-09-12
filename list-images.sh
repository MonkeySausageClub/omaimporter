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
# are written to a per-file cache keyed by the md5 of the file's *path string*,
# so different files never overwrite each other's cache row. The cache also
# records the stat signature of the thumbnail *source*, and that signature is
# embedded in the thumbnail filename, so a changed source file invalidates
# stale thumbnails on the next scan. The SD card is only ever read; source
# files are never modified.
#
# RAW files: a same-basename .JPG sibling (the embedded preview the camera
# writes) is used as the thumbnail source when present — far cheaper than a
# libraw decode. Otherwise ImageMagick (built against libraw) reads the RAW
# directly. No metadata is written back to the source.
#
# If a thumbnail cannot be built (no ImageMagick, undecodable RAW), the row is
# still emitted with the source path in place of the thumbnail so the file can
# at least be selected and imported.

set -o pipefail
set -u

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

# stat signature of the thumbnail source (the sibling JPG for RAW files,
# otherwise the file itself) — used to invalidate stale thumbnails.
src_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }

# signature -> existing cached thumbnail path, else empty.
cached_thumb() {
  local file="$1" src sig hash
  src="${2:-$file}"
  sig=$(src_sig "$src") || return
  hash=${CACHE_IDX["$file"$'\t'"$sig"]:-}
  [ -n "$hash" ] && [ -f "$cache_root/$hash" ] && printf '%s\n' "$cache_root/$hash"
}

# Thumbnail cache key is the md5 of the source file's path string, not of the
# image bytes: two different files that happen to share content must not
# overwrite each other's cache row. The source's stat signature is appended to
# the filename so a changed source (e.g. an edited sibling JPG) produces a new
# thumbnail instead of silently serving a stale one.
thumb_key() { printf '%s' "$1" | md5sum | cut -d ' ' -f 1; }

make_thumb() {
  local file="$1" src key sig thumb
  src="${2:-$file}"
  key=$(thumb_key "$file") || return 1
  sig=$(src_sig "$src") || return 1
  thumb="$cache_root/$key.$sig.jpg"
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

# Collect a stable list of matching regular files first so we don't re-stat in
# a pipe subshell (which would prevent a shared index from being maintained).
# -P (the find default, made explicit here) never follows symlinks, so a
# planted card cannot reach into the rest of the filesystem. Filenames that
# contain a newline or a tab are skipped: they cannot survive the TSV protocol
# used to talk to the shell.
mapfile -d '' files < <(
  find -P "$dir" -maxdepth 6 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.raw' -o -iname '*.cr2' \
       -o -iname '*.cr3' -o -iname '*.crw' -o -iname '*.nef' -o -iname '*.nrw' \
       -o -iname '*.arw' -o -iname '*.srw' -o -iname '*.orf' -o -iname '*.raf' \
       -o -iname '*.rw2' -o -iname '*.pef' -o -iname '*.dng' -o -iname '*.3fr' \
       -o -iname '*.dcr' -o -iname '*.kdc' -o -iname '*.mdc' -o -iname '*.mrw' \
       -o -iname '*.mos' -o -iname '*.erf' -o -iname '*.iiq' -o -iname '*.fff' \
       -o -iname '*.mef' \) \
    -print0 2>/dev/null | sort -z
)

clean=()
for img in "${files[@]}"; do
  [ -n "$img" ] || continue
  case "$img" in
    *$'\n'*|*$'\t'*) printf 'skipping filename with newline or tab: %s\n' "$img" >&2; continue ;;
  esac
  clean+=("$img")
done
files=("${clean[@]}")
unset clean

# Stream already-cached rows immediately so the UI fills before any heavy
# thumbnailing happens.
uncached=()
for img in "${files[@]}"; do
  thumb=$(cached_thumb "$img" "$(raw_thumb_src "$img")")
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
    local file="$1" src thumb sig
    src=$(raw_thumb_src "$file")
    thumb=$(make_thumb "$file" "$src")
    if [ -n "$thumb" ]; then
      printf '%s\t%s\n' "$file" "$thumb"
      sig=$(src_sig "${src:-$file}") || return
      printf '%s\t%s\t%s\n' "$file" "$sig" "$(basename "$thumb")" \
        >> "$idx_file"
    else
      # No thumbnail possible (missing ImageMagick, undecodable RAW, ...).
      # Still list the file so it can be selected and imported.
      printf '%s\t%s\n' "$file" "$file"
    fi
  }
  export -f worker make_thumb thumb_key src_sig cached_thumb raw_thumb_src
  export cache_root

  : > "$idx_file"
  printf '%s\0' "${uncached[@]}" \
    | xargs -0 -n1 -P"$ncpu" bash -c 'worker "$1"' _

  # Workers appended to a per-run index file; merge it in. Concurrent scans
  # each have their own index file, so the merge is serialized with flock to
  # avoid losing updates. A pristine run has no index.tsv yet, so tolerate a
  # missing base.
  if [ -s "$idx_file" ]; then
    (
      flock 9
      if [ -f "$cache_root/index.tsv" ]; then
        sort -u "$cache_root/index.tsv" "$idx_file" \
          > "$cache_root/index.tsv.merged.$$" 2>/dev/null
      else
        sort -u "$idx_file" > "$cache_root/index.tsv.merged.$$" 2>/dev/null
      fi
      mv -f "$cache_root/index.tsv.merged.$$" "$cache_root/index.tsv"
    ) 9>"$cache_root/.index.lock"
  fi
  rm -f "$idx_file"
  trap - EXIT
fi

exit 0