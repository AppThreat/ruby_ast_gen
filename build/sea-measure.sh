#!/bin/sh
# Compare a single executable against the gem on one or more Ruby inputs:
# output parity (byte-for-byte, manifests and diagnostics included), wall time
# and peak RSS. Used for the SEA spike (issues #16-#18); not part of a release.
#
#   build/sea-measure.sh <executable> "<gem command>" <input-dir>...
#
#   build/sea-measure.sh dist/ruby_ast_gen-2.1.0-macos-arm64 \
#     "ruby exe/ruby_ast_gen" /tmp/corpora/railsgoat
#
# Extra ruby_ast_gen flags can be passed through MEASURE_ARGS
# (for example MEASURE_ARGS="--parser-target 3.4").
# Prints one tab-separated row per input:
#   input  gem_s  exe_s  gem_rss_mb  exe_rss_mb  files  differing_files
set -eu

EXE=$1
GEM_CMD=$2
shift 2
ARGS=${MEASURE_ARGS:-}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sea-measure.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [ "$(uname -s)" = Darwin ]; then
  timed() { /usr/bin/time -l "$@" 2>"$WORK/time.txt" >/dev/null || true
    secs=$(awk '/ real /{print $1}' "$WORK/time.txt")
    rss=$(awk '/maximum resident set size/{printf "%.0f", $1/1048576}' "$WORK/time.txt"); }
else
  timed() { /usr/bin/time -v "$@" 2>"$WORK/time.txt" >/dev/null || true
    secs=$(awk -F': ' '/Elapsed \(wall clock\)/{n=split($2,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print s}' "$WORK/time.txt")
    rss=$(awk -F': ' '/Maximum resident set size/{printf "%.0f", $2/1024}' "$WORK/time.txt"); }
fi

for input in "$@"; do
  name=$(basename "$input")
  rm -rf "$WORK/gem" "$WORK/exe"
  # shellcheck disable=SC2086
  timed $GEM_CMD -i "$input" -o "$WORK/gem" $ARGS
  gem_s=$secs; gem_rss=$rss
  # shellcheck disable=SC2086
  timed "$EXE" -i "$input" -o "$WORK/exe" $ARGS
  exe_s=$secs; exe_rss=$rss
  files=$(find "$WORK/gem" -type f | wc -l | tr -d ' ')
  differing=$(diff -rq "$WORK/gem" "$WORK/exe" | wc -l | tr -d ' ')
  if [ "$differing" != 0 ]; then
    mkdir -p "${MEASURE_KEEP:-$WORK/keep}/$name"
    diff -rq "$WORK/gem" "$WORK/exe" | head -20 >"${MEASURE_KEEP:-$WORK/keep}/$name/diff.txt"
    cat "${MEASURE_KEEP:-$WORK/keep}/$name/diff.txt" >&2
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$gem_s" "$exe_s" "$gem_rss" "$exe_rss" "$files" "$differing"
done
