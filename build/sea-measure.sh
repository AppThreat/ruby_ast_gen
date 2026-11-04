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
# Prints one tab-separated row per input:
#   input  gem_s  exe_s  gem_rss_mb  exe_rss_mb  files  differing  differing_masked  backend_mismatch
#
#   differing         files that differ byte-for-byte
#   differing_masked  files that still differ once the fields that legitimately
#                     vary are masked: ruby_version everywhere, plus the
#                     manifest's generated_at and output. parser_backend is NOT
#                     masked: an executable whose prism failed to load falls
#                     back to Parser::Ruby33, and on ordinary code that yields
#                     the same AST, so the backend is the only visible symptom.
#   backend_mismatch  files whose parser_backend differs (a subset of the above)
#
# A run that exits non-zero prints FAIL(<status>) in place of its time.
# Each timing is a single run. The executable is started once before the first
# input so its one-time unpack into $TEBAKO_HOME is not counted.
#
# Extra ruby_ast_gen flags can be passed through MEASURE_ARGS
# (for example MEASURE_ARGS="--parser-target 3.4"). MEASURE_KEEP=<dir> keeps the
# unmasked diff list and the first differing pair of each input there.
#
# Compare mode diffs two existing output trees, for runs made on different
# machines (the Windows executable against the macOS one, say). Each tree's
# input root is replaced by a placeholder before diffing, because file_path and
# __FILE__ literals embed the absolute input location. Needs perl.
#
#   build/sea-measure.sh --compare <treeA> <rootA> <treeB> <rootB>
#
#   build/sea-measure.sh --compare ~/winout/out-maybe C:/spike/corp/maybe \
#     /tmp/out-maybe /tmp/corpora/maybe
#
# prints: files  differing  differing_masked  backend_mismatch
set -eu

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sea-measure.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Masks the fields that differ between any two runs, in place, for every file of tree $1.
mask_tree() {
  find "$1" -type f | while read -r f; do
    expr='s/"ruby_version":"[^"]*"/"ruby_version":"_"/g'
    case "$f" in
      */ruby_ast_gen_manifest.jsonl) expr="$expr;"'s/"(generated_at|output|input)":"[^"]*"/"\1":"_"/g' ;;
    esac
    sed -E "$expr" "$f" >"$f.norm"
    mv "$f.norm" "$f"
  done
}

# Replaces every occurrence of the literal string $2 in the files of tree $1 by <ROOT>.
mask_root() {
  find "$1" -type f | while read -r f; do
    MEASURE_ROOT=$2 perl -pi -e 's/\Q$ENV{MEASURE_ROOT}\E/<ROOT>/g' "$f"
  done
}

count_lines() { wc -l | tr -d ' '; }

# Files of tree $1 whose parser_backend differs from the same file in tree $2.
backend_mismatches() {
  (cd "$1" && find . -type f) | while read -r f; do
    a=$(grep -o '"parser_backend":"[^"]*"' "$1/$f" 2>/dev/null | head -1 || true)
    b=$(grep -o '"parser_backend":"[^"]*"' "$2/$f" 2>/dev/null | head -1 || true)
    [ "$a" = "$b" ] || echo "$f"
  done | count_lines
}

if [ "${1:-}" = "--compare" ]; then
  [ $# -eq 5 ] || { echo "usage: $0 --compare <treeA> <rootA> <treeB> <rootB>" >&2; exit 2; }
  cp -R "$2" "$WORK/a"
  cp -R "$4" "$WORK/b"
  files=$(find "$WORK/a" -type f | count_lines)
  differing=$(diff -rq "$WORK/a" "$WORK/b" | count_lines)
  mask_root "$WORK/a" "$3"
  mask_root "$WORK/b" "$5"
  mask_tree "$WORK/a"
  mask_tree "$WORK/b"
  if [ -n "${MEASURE_KEEP:-}" ]; then
    mkdir -p "$MEASURE_KEEP"
    diff -rq "$WORK/a" "$WORK/b" >"$MEASURE_KEEP/compare-diff.txt" || true
  fi
  masked=$(diff -rq "$WORK/a" "$WORK/b" | count_lines)
  printf '%s\t%s\t%s\t%s\n' "$files" "$differing" "$masked" "$(backend_mismatches "$WORK/a" "$WORK/b")"
  exit 0
fi

[ $# -ge 3 ] || { echo "usage: $0 <executable> \"<gem command>\" <input-dir>..." >&2; exit 2; }
EXE=$1
GEM_CMD=$2
shift 2
ARGS=${MEASURE_ARGS:-}

# Sets secs and rss for one run of "$@"; secs is FAIL(<status>) when the run fails.
if [ "$(uname -s)" = Darwin ]; then
  timed() {
    status=0
    /usr/bin/time -l "$@" 2>"$WORK/time.txt" >/dev/null || status=$?
    secs=$(awk '/ real /{print $1}' "$WORK/time.txt")
    rss=$(awk '/maximum resident set size/{printf "%.0f", $1/1048576}' "$WORK/time.txt")
    [ "$status" = 0 ] || secs="FAIL($status)"
  }
else
  timed() {
    status=0
    /usr/bin/time -v "$@" 2>"$WORK/time.txt" >/dev/null || status=$?
    secs=$(awk -F': ' '/Elapsed \(wall clock\)/{n=split($2,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print s}' "$WORK/time.txt")
    rss=$(awk -F': ' '/Maximum resident set size/{printf "%.0f", $2/1024}' "$WORK/time.txt")
    [ "$status" = 0 ] || secs="FAIL($status)"
  }
fi

# One-time unpack, so the first input's timing is a warm run like the others.
"$EXE" --version >/dev/null 2>&1 || { echo "sea-measure: $EXE --version failed" >&2; exit 1; }

for input in "$@"; do
  name=$(basename "$input")
  rm -rf "$WORK/gem" "$WORK/exe"
  # shellcheck disable=SC2086
  timed $GEM_CMD -i "$input" -o "$WORK/gem" $ARGS
  gem_s=$secs; gem_rss=$rss
  # shellcheck disable=SC2086
  timed "$EXE" -i "$input" -o "$WORK/exe" $ARGS
  exe_s=$secs; exe_rss=$rss
  mkdir -p "$WORK/gem" "$WORK/exe"
  files=$(find "$WORK/gem" -type f | count_lines)
  differing=$(diff -rq "$WORK/gem" "$WORK/exe" | count_lines)
  backends=$(backend_mismatches "$WORK/gem" "$WORK/exe")
  if [ -n "${MEASURE_KEEP:-}" ] && [ "$differing" != 0 ]; then
    # Unmasked, so the kept files show what actually differed.
    mkdir -p "$MEASURE_KEEP/$name"
    diff -rq "$WORK/gem" "$WORK/exe" >"$MEASURE_KEEP/$name/diff.txt" || true
    first=$(sed -n '1s/^Files \(.*\) and \(.*\) differ$/\1|\2/p' "$MEASURE_KEEP/$name/diff.txt")
    if [ -n "$first" ]; then
      cp "${first%%|*}" "$MEASURE_KEEP/$name/first.gem" 2>/dev/null || true
      cp "${first##*|}" "$MEASURE_KEEP/$name/first.exe" 2>/dev/null || true
    fi
  fi
  mask_tree "$WORK/gem"
  mask_tree "$WORK/exe"
  masked=$(diff -rq "$WORK/gem" "$WORK/exe" | count_lines)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$gem_s" "$exe_s" "$gem_rss" "$exe_rss" \
    "$files" "$differing" "$masked" "$backends"
done
