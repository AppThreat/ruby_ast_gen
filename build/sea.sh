#!/bin/sh
# Build a self-contained single executable application (SEA) of ruby_ast_gen for
# the CURRENT platform using tebako <https://tebako.org>.
#
# The output is one native executable per platform: the CRuby runtime, the gem
# set (parser + prism with its native extension) and the application tree ride
# inside the file, so end users need no Ruby installed. The same script runs on
# the release CI matrix (Ubuntu, Alpine, macOS) and locally:
#
#   ./build/sea.sh                     # press with the pinned defaults
#   SEA_RUBY_VERSION=3.4.10 ./build/sea.sh
#   SEA_UPX=1 ./build/sea.sh           # additionally attempt a UPX-compressed copy
#
# Prerequisites on the build machine: curl, cmake and a C toolchain — clang on
# Linux (tebako's runtime SDK embeds its build farm's clang flags in RbConfig,
# and gcc rejects them; repoint cc at clang, as the release workflow does).
# No Ruby is needed: tebako press installs the gems inside the pinned runtime.
#
# Inputs (environment):
#   SEA_RUBY_VERSION  CRuby runtime pressed into the binary (default 4.0.7; must
#                     exist in `tebako info runtimes --remote` for the platform,
#                     with its .asc signature: 4.0.6 has none for macos-arm64)
#   TEBAKO_VERSION    pinned tebako release used for pressing (default v2.8.77).
#                     A tebako already on PATH is used only if it is this
#                     version; otherwise the pinned release is installed into
#                     ~/.local/bin, replacing whatever copy is there.
#   MACOSX_DEPLOYMENT_TARGET
#                     macOS only (default 14.0, the tebako runtime's own floor).
#                     prism's extension is compiled at press time, and without
#                     this it targets the build host's macOS version.
#   SEA_UPX           1 to UPX-compress the binary and verify it still runs
#                     (Linux only; falls back to the plain binary on any failure)
#   SEA_DIST          output directory (default: dist)
#
# Output: $SEA_DIST/ruby_ast_gen-<version>-<platform> and a matching
# .sha256 file, plus the smoke-test log on stdout.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SEA_RUBY_VERSION=${SEA_RUBY_VERSION:-4.0.7}
# The pinned tebako release used for pressing. The value must carry the v: the
# tag names the release download URLs below.
TEBAKO_VERSION=${TEBAKO_VERSION:-v2.8.77}
TEBAKO_VERSION="v${TEBAKO_VERSION#v}"
SEA_UPX=${SEA_UPX:-0}
SEA_DIST=${SEA_DIST:-$REPO_ROOT/dist}

BUILD_ROOT=''
TEBAKO_TMP=''
HOSTILE_TMP=''

cleanup() {
  [ -n "$BUILD_ROOT" ] && rm -rf "$BUILD_ROOT" || true
  [ -n "$TEBAKO_TMP" ] && rm -rf "$TEBAKO_TMP" || true
  [ -n "$HOSTILE_TMP" ] && rm -rf "$HOSTILE_TMP" || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Platform triple, in tebako's naming
# ---------------------------------------------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$arch" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) echo "sea.sh: unsupported architecture: $arch" >&2; exit 1 ;;
esac
case "$os" in
  Darwin) PLATFORM="macos-$arch" ;;
  Linux)
    if ldd --version 2>&1 | grep -qi musl; then
      PLATFORM="linux-musl-$arch"
    else
      PLATFORM="linux-gnu-$arch"
    fi
    ;;
  *) echo "sea.sh: unsupported OS: $os (Windows uses build/sea.ps1)" >&2; exit 1 ;;
esac

GEM_VERSION=$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$REPO_ROOT/lib/ruby_ast_gen/version.rb")
OUT="$SEA_DIST/ruby_ast_gen-$GEM_VERSION-$PLATFORM"

echo "sea.sh: ruby_ast_gen $GEM_VERSION for $PLATFORM (runtime $SEA_RUBY_VERSION)"

# ---------------------------------------------------------------------------
# 2. tebako itself, unless the pinned version is already on PATH: the four
#    release binaries, each verified against the release's SHA256SUMS before
#    anything is installed (the same posture as build/sea.ps1 — the unix legs
#    build 6 of the 7 shipped binaries, so an unverified curl|sh here is not
#    acceptable either). Any other tebako version is ignored: a press with a
#    different tebako is a different build, whatever TEBAKO_VERSION says.
# ---------------------------------------------------------------------------
vnum=${TEBAKO_VERSION#v}
tebako_is_pinned() {
  command -v tebako >/dev/null 2>&1 &&
    tebako --version 2>/dev/null | tr -s ' \t' '\n\n' | sed 's/^v//' | grep -qxF "$vnum"
}
# A pinned copy installed by an earlier run wins over another version elsewhere on PATH.
if [ -x "$HOME/.local/bin/tebako" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! tebako_is_pinned; then
  if command -v tebako >/dev/null 2>&1; then
    echo "sea.sh: ignoring $(command -v tebako) ($(tebako --version 2>/dev/null | head -1)); want $TEBAKO_VERSION"
  fi
  echo "sea.sh: installing tebako $TEBAKO_VERSION (sha256-verified)"
  TEBAKO_TMP=$(mktemp -d "${TMPDIR:-/tmp}/tebako-install.XXXXXX")
  base="https://github.com/tamatebako/tebako/releases/download/$TEBAKO_VERSION"
  curl -fsSL -o "$TEBAKO_TMP/SHA256SUMS" "$base/SHA256SUMS"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
  else
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
  fi

  for b in tebako tebako-pkg tfs tebako-bootstrap; do
    curl -fsSL -o "$TEBAKO_TMP/$b" "$base/$b-$vnum-$PLATFORM"
    want=$(awk -v f="$b-$vnum-$PLATFORM" '$2 == f {print $1}' "$TEBAKO_TMP/SHA256SUMS")
    [ -n "$want" ] || { echo "sea.sh: no SHA256SUMS entry for $b-$vnum-$PLATFORM" >&2; exit 1; }
    got=$(sha256_of "$TEBAKO_TMP/$b")
    [ "$got" = "$want" ] || {
      echo "sea.sh: sha256 mismatch for $b (want $want, got $got) — refusing to install" >&2
      exit 1
    }
  done
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$TEBAKO_TMP/tebako" "$TEBAKO_TMP/tebako-pkg" "$TEBAKO_TMP/tfs" \
    "$TEBAKO_TMP/tebako-bootstrap" "$HOME/.local/bin/"
  export PATH="$HOME/.local/bin:$PATH"
  tebako_is_pinned || {
    echo "sea.sh: tebako $TEBAKO_VERSION installed, but $(command -v tebako || echo 'no tebako') is what PATH resolves" >&2
    exit 1
  }
fi
echo "sea.sh: using $(command -v tebako) ($(tebako --version 2>/dev/null | head -1))"

# prism's native extension is compiled during the press. On macOS clang then
# targets the build host's OS unless told otherwise: pressed on a macos-26
# runner, prism.bundle carried minos 26.0 while the runtime itself says 14.0.
if [ "$os" = Darwin ]; then
  MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
  export MACOSX_DEPLOYMENT_TARGET
  echo "sea.sh: MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
fi

# ---------------------------------------------------------------------------
# 3. Build tree. tebako presses "a Gemfile root": the application is vendored
#    as a plain source tree with a Gemfile of exactly the runtime dependencies
#    (the gemspec-based layout of the repository is explicitly unsupported by
#    tebako's deploy step). press installs the gems itself, inside the pinned
#    runtime, so no Ruby is needed on the build machine and prism's native
#    extension is always compiled against the runtime that ships in the binary.
# ---------------------------------------------------------------------------
BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ruby-ast-gen-sea.XXXXXX")
mkdir -p "$BUILD_ROOT"
cp -R "$REPO_ROOT/lib" "$REPO_ROOT/exe" "$REPO_ROOT/sea" "$BUILD_ROOT/"
cat >"$BUILD_ROOT/Gemfile" <<'GEMFILE'
# frozen_string_literal: true

# Runtime-only view of the repository Gemfile for the pressed executable: the
# parser/prism constraints must stay in sync with the Gemfile in the repo root
# (spec/sea_bundle_spec.rb fails the suite when they drift).
source "https://rubygems.org"

gem "ostruct", "~> 0.6.3"
gem "parser", "~> 3.3.12.0"
gem "prism", "~> 1.9"
GEMFILE

# ---------------------------------------------------------------------------
# 4. Press
# ---------------------------------------------------------------------------
mkdir -p "$SEA_DIST"
rm -f "$OUT" "$OUT.sha256"
tebako press \
  -r "$BUILD_ROOT" \
  -e sea/entry.rb \
  -o "$OUT" \
  -R "$SEA_RUBY_VERSION" \
  -m self-contained

# ---------------------------------------------------------------------------
# 5. Smoke tests. The binary must be right twice: in a pristine environment
#    (the no-Ruby user) and in a hostile one carrying a foreign GEM_HOME/
#    GEM_PATH plus a RUBYLIB whose parser/source/buffer.rb and json.rb are
#    raising stubs — the regression guard for sea/entry.rb's environment
#    scrub. Without the scrub both stubs demonstrably shadow the packaged
#    files (gem activation against the host's gems; RUBYLIB entries sit ahead
#    of the default load path), so these checks are load-bearing, not theatre.
# ---------------------------------------------------------------------------
HOSTILE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sea-hostile.XXXXXX")
mkdir -p "$HOSTILE_TMP/parser/source"
echo 'raise "hostile RUBYLIB shadowed the packaged parser gem"' \
  >"$HOSTILE_TMP/parser/source/buffer.rb"
echo 'raise "hostile RUBYLIB shadowed the packaged stdlib"' >"$HOSTILE_TMP/json.rb"

# The prism floor the pressed Gemfile asks for ("~> 1.9" -> 1.9). Checking only
# that *a* prism backend loaded would pass with an older prism, such as the
# runtime's default gem.
PRISM_MIN=$(sed -n 's/^gem "prism", "~> \(.*\)"$/\1/p' "$BUILD_ROOT/Gemfile")
[ -n "$PRISM_MIN" ] || { echo "sea.sh: no prism constraint in the pressed Gemfile" >&2; exit 1; }

# True when dotted version $1 is at least $2 (a missing or non-numeric $1 is not).
version_at_least() {
  awk -v have="$1" -v want="$2" 'BEGIN {
    if (have !~ /^[0-9]/) exit 1
    split(have, h, "."); m = split(want, w, ".")
    for (i = 1; i <= m; i++) {
      if ((h[i] + 0) > (w[i] + 0)) exit 0
      if ((h[i] + 0) < (w[i] + 0)) exit 1
    }
    exit 0
  }'
}

smoke_test() {
  bin=$1
  env_desc=$2

  pristine() { env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$bin" "$@"; }
  hostile() {
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
      GEM_HOME=/tmp/sea-smoke-gem-home GEM_PATH=/tmp/sea-smoke-gem-path \
      RUBYLIB="$HOSTILE_TMP" "$bin" "$@"
  }

  version=$(pristine --version 2>/dev/null | tail -1)
  [ "$version" = "$GEM_VERSION" ] || {
    echo "sea.sh: $env_desc: --version returned '$version', expected '$GEM_VERSION'" >&2
    return 1
  }
  pristine --parser-info 2>/dev/null | grep -q "Parser backend: Prism" || {
    echo "sea.sh: $env_desc: --parser-info (pristine) did not select the prism backend" >&2
    return 1
  }
  hostile --parser-info 2>/dev/null | grep -q "Parser backend: Prism" || {
    echo "sea.sh: $env_desc: --parser-info (hostile GEM_*/RUBYLIB) did not select the prism backend" >&2
    return 1
  }
  hostile --parser-info 2>/dev/null | grep -q "Ruby version: $SEA_RUBY_VERSION" || {
    echo "sea.sh: $env_desc: runtime is not $SEA_RUBY_VERSION" >&2
    return 1
  }
  prism_version=$(pristine --parser-info 2>/dev/null | sed -n 's/^Prism gem: //p')
  version_at_least "$prism_version" "$PRISM_MIN" || {
    echo "sea.sh: $env_desc: prism is '$prism_version', the pressed Gemfile asks for ~> $PRISM_MIN" >&2
    return 1
  }
  out_dir=$(mktemp -d "${TMPDIR:-/tmp}/sea-smoke.XXXXXX")
  pristine -i "$REPO_ROOT/lib/ruby_ast_gen/version.rb" -o "$out_dir" >/dev/null 2>&1 || {
    echo "sea.sh: $env_desc: parse run failed" >&2
    rm -rf "$out_dir"; return 1
  }
  [ -f "$out_dir/version.rb.json" ] || {
    echo "sea.sh: $env_desc: no JSON emitted for the parsed fixture" >&2
    rm -rf "$out_dir"; return 1
  }
  rm -rf "$out_dir"
  echo "sea.sh: smoke test passed ($env_desc)"
}

smoke_test "$OUT" "uncompressed"

# ---------------------------------------------------------------------------
# 6. Optional UPX pass. tebako packages carry appended image slots after the
#    ELF container, so UPX runs with --overlay=copy and the compressed binary
#    must re-pass the full smoke test; on any failure the plain binary ships.
#    macOS is skipped: UPX's Mach-O arm64 path is experimental and did not
#    terminate on a 72 MB package during testing.
# ---------------------------------------------------------------------------
if [ "$SEA_UPX" = "1" ] && [ "$os" = Linux ]; then
  if command -v upx >/dev/null 2>&1; then
    cp "$OUT" "$OUT.upx"
    if upx --best --overlay=copy -q "$OUT.upx" >/dev/null 2>&1; then
      if smoke_test "$OUT.upx" "upx"; then
        mv "$OUT.upx" "$OUT"
        echo "sea.sh: UPX applied: $(du -h "$OUT" | cut -f1) final size"
      else
        echo "sea.sh: UPX-compressed binary failed verification; shipping uncompressed" >&2
        rm -f "$OUT.upx"
      fi
    else
      echo "sea.sh: UPX could not pack the package; shipping uncompressed" >&2
      rm -f "$OUT.upx"
    fi
  else
    echo "sea.sh: SEA_UPX=1 but upx is not installed; shipping uncompressed" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 7. Checksum
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT" >"$OUT.sha256"
else
  shasum -a 256 "$OUT" >"$OUT.sha256"
fi

echo "sea.sh: built $(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
